import Foundation
import MacCleanKit

public struct ShredderModule: ScanModule {
    public let id = "shredder"
    public var name: String { L10n.tr("文件粉碎", "Shredder", "Уничтожение файлов") }
    public let category = ModuleCategory.files
    public let includedInSmartScan = false

    public init() {}

    public func scan() async -> [ScanResult] {
        []
    }
}

// MARK: - Secure File Eraser

public actor SecureEraser {
    public enum EraseMode: Sendable {
        case standard   // Move to trash (recoverable)
        case permanent  // Remove immediately (TRIM handles SSD cleanup)
        case secure     // Overwrite then remove (best effort on SSD)
    }

    private enum EraseError: LocalizedError {
        case secureEraseDirectory(String)

        var errorDescription: String? {
            switch self {
            case .secureEraseDirectory(let path):
                L10n.tr(
                    "安全擦除不能用于文件夹：\(path)",
                    "Secure erase cannot be used on directories: \(path)",
                    "Безопасное стирание нельзя применять к папкам: \(path)")
            }
        }
    }

    public struct EraseResult: Sendable {
        public let erasedCount: Int
        public let totalSize: UInt64
        public let errors: [(String, String)]
    }

    private let safetyGuard = SafetyGuard()

    public init() {}

    public func erase(urls: [URL], mode: EraseMode) async -> EraseResult {
        // Preserve the batch-size safety cap, but let the per-item validation
        // below identify and skip individual unsafe paths.
        do {
            try safetyGuard.validateDeletion(paths: urls)
        } catch let error as SafetyGuard.SafetyError {
            if case .tooManyFiles = error {
                return EraseResult(
                    erasedCount: 0,
                    totalSize: 0,
                    errors: [("validation", error.localizedDescription)]
                )
            }
        } catch {
            // validateDeletion currently only throws SafetyError. If that
            // changes, per-item validation still keeps the batch fail-safe.
        }

        var erasedCount = 0
        var totalSize: UInt64 = 0
        var errors: [(String, String)] = []

        for url in urls {
            if Task.isCancelled { break }

            do {
                try safetyGuard.validatePath(url)
            } catch {
                errors.append((url.path(percentEncoded: false), error.localizedDescription))
                continue
            }

            let size = fileSize(url)

            do {
                switch mode {
                case .standard:
                    _ = try GuardedFileOperations.trash(url)

                case .permanent:
                    try GuardedFileOperations.remove(url)

                case .secure:
                    try GuardedFileOperations.secureErase(url)
                }

                erasedCount += 1
                totalSize += size
            } catch {
                errors.append((url.path(percentEncoded: false), error.localizedDescription))
            }
        }

        return EraseResult(erasedCount: erasedCount, totalSize: totalSize, errors: errors)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
