import Foundation
import Darwin

public enum ConsolidationOutcome: Equatable, Sendable {
    case reclaimed(bytes: UInt64)
    case skipped(SkipReason)
    case failed(String)
}

public enum SkipReason: Equatable, Sendable {
    case contentChanged
    case notSameVolume
    case cloningUnsupported
    case notRegularFile
    case notWritable
    case protectedPath
}

public struct SkippedItem: Equatable, Sendable {
    public let url: URL
    public let reason: SkipReason
    public init(url: URL, reason: SkipReason) { self.url = url; self.reason = reason }
}

public struct FailedItem: Equatable, Sendable {
    public let url: URL
    public let message: String
    public init(url: URL, message: String) { self.url = url; self.message = message }
}

public struct ConsolidationSummary: Equatable, Sendable {
    public var reclaimedBytes: UInt64
    public var consolidatedCount: Int
    public var skipped: [SkippedItem]
    public var failed: [FailedItem]
    public init(reclaimedBytes: UInt64 = 0, consolidatedCount: Int = 0,
                skipped: [SkippedItem] = [], failed: [FailedItem] = []) {
        self.reclaimedBytes = reclaimedBytes
        self.consolidatedCount = consolidatedCount
        self.skipped = skipped
        self.failed = failed
    }
}

public struct GroupConsolidation: Sendable {
    public let master: URL
    public let copies: [URL]
    public init(master: URL, copies: [URL]) { self.master = master; self.copies = copies }
}

/// Replaces redundant duplicate copies with APFS clones of a master so every
/// path keeps working while identical files stop costing N times their size.
/// Pure and filesystem-only; no UI or global state.
public enum FileConsolidator {

    // MARK: Eligibility (step 1 of the swap; also powers the dry-run estimate)

    /// nil means the pair passes every precondition for a clone-swap.
    public static func ineligibilityReason(master: URL, copy: URL,
                                           safetyGuard: SafetyGuard) -> SkipReason? {
        guard isRegularFile(master), isRegularFile(copy) else { return .notRegularFile }
        guard sameVolume(master, copy) else { return .notSameVolume }
        guard supportsCloning(copy) else { return .cloningUnsupported }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: copy.path(percentEncoded: false)),
              fm.isWritableFile(atPath: copy.deletingLastPathComponent().path(percentEncoded: false))
        else { return .notWritable }
        do { try safetyGuard.validatePath(copy) } catch { return .protectedPath }
        return nil
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]) else { return false }
        return (v.isRegularFile ?? false) && !(v.isSymbolicLink ?? false) && !(v.isPackage ?? false)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let va, let vb else { return false }
        return (va as AnyObject).isEqual(vb)
    }

    static func supportsCloning(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning ?? false
    }

    // MARK: Single-pair clone-swap

    /// Replace `copy` with an APFS clone of `master`, in place and atomically.
    /// Any failed precondition or error leaves the original `copy` untouched.
    public static func consolidate(master: URL, copy: URL,
                                   safetyGuard: SafetyGuard = SafetyGuard()) -> ConsolidationOutcome {
        if let reason = ineligibilityReason(master: master, copy: copy, safetyGuard: safetyGuard) {
            return .skipped(reason)
        }
        // Pin both source objects before hashing or cloning. The destination
        // is detached into a private same-volume directory, so a path swap
        // cannot redirect either metadata copying or the final replacement.
        do {
            let sourceParent = try PinnedDirectory(master.deletingLastPathComponent())
            try safetyGuard.validatePath(master)
            let masterFD = openat(sourceParent.descriptor, master.lastPathComponent,
                                  O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard masterFD >= 0 else { throw fileSystemError() }
            defer { close(masterFD) }
            let sourceIdentity = try FileIdentity(descriptor: masterFD)
            guard sourceIdentity.isRegular else { return .skipped(.notRegularFile) }
            let captured = try CapturedFile(copy)
            do {
                let copyFD = try captured.openOriginal(O_RDONLY)
                defer { close(copyFD) }
                let copyIdentity = try FileIdentity(descriptor: copyFD)
                guard copyIdentity.isRegular else { throw GuardedFileError.changed }
                guard let masterHash = FileHashing.sha256(descriptor: masterFD),
                      let copyHash = FileHashing.sha256(descriptor: copyFD),
                      masterHash == copyHash else {
                    try captured.restore()
                    return .skipped(.contentChanged)
                }
                let name = "replacement"
                guard fclonefileat(masterFD, captured.stagingDescriptor, name, UInt32(CLONE_NOOWNERCOPY)) == 0
                else { throw fileSystemError() }
                defer { _ = unlinkat(captured.stagingDescriptor, name, 0) }
                let cloneFD = openat(captured.stagingDescriptor, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard cloneFD >= 0 else { throw fileSystemError() }
                defer { close(cloneFD) }
                // clonefile copies the master's xattrs. Remove them before
                // applying the destination's exact metadata, including its
                // resource fork, quarantine, Finder tags, ACL, and timestamps.
                let count = flistxattr(cloneFD, nil, 0, 0)
                guard count >= 0 else { throw fileSystemError() }
                if count > 0 {
                    var names = [CChar](repeating: 0, count: count)
                    let read = names.withUnsafeMutableBufferPointer {
                        flistxattr(cloneFD, $0.baseAddress, $0.count, 0)
                    }
                    guard read >= 0 else { throw fileSystemError() }
                    var offset = 0
                    while offset < read {
                        let attribute = names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + offset) }
                        guard fremovexattr(cloneFD, attribute, 0) == 0 else { throw fileSystemError() }
                        offset += attribute.utf8.count + 1
                    }
                }
                guard fcopyfile(copyFD, cloneFD, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0
                else { throw fileSystemError() }
                guard FileHashing.sha256(descriptor: cloneFD) == masterHash,
                      sourceIdentity.sameRevision(as: try FileIdentity(descriptor: masterFD)),
                      copyIdentity.sameRevision(as: try FileIdentity(descriptor: copyFD)) else {
                    try captured.restore()
                    return .skipped(.contentChanged)
                }
                let reclaimed = UInt64(max(0, copyIdentity.value.st_blocks)) * 512
                try captured.replace(with: name)
                return .reclaimed(bytes: reclaimed)
            } catch {
                try captured.restore()
                throw error
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Batch + estimate

    /// Consolidate every selected copy in each group (master = the kept copy),
    /// aggregating results. Honours cancellation between items.
    public static func consolidate(groups: [GroupConsolidation],
                                   safetyGuard: SafetyGuard = SafetyGuard()) -> ConsolidationSummary {
        var summary = ConsolidationSummary()
        for group in groups {
            for copy in group.copies {
                if Task.isCancelled { return summary }
                switch consolidate(master: group.master, copy: copy, safetyGuard: safetyGuard) {
                case .reclaimed(let bytes):
                    summary.reclaimedBytes += bytes
                    summary.consolidatedCount += 1
                case .skipped(let reason):
                    summary.skipped.append(SkippedItem(url: copy, reason: reason))
                case .failed(let message):
                    summary.failed.append(FailedItem(url: copy, message: message))
                }
            }
        }
        return summary
    }

    /// Cheap dry-run: sum the allocated size of copies that pass the step-1
    /// eligibility checks. Writes nothing; used for the confirmation preview.
    public static func estimateReclaimable(groups: [GroupConsolidation],
                                           safetyGuard: SafetyGuard = SafetyGuard()) -> UInt64 {
        var total: UInt64 = 0
        for group in groups {
            for copy in group.copies
            where ineligibilityReason(master: group.master, copy: copy, safetyGuard: safetyGuard) == nil {
                total += UInt64((try? copy.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
