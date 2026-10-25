import Foundation
import CryptoKit
import Darwin

/// Streaming SHA256 of a file's contents as a lowercase hex string.
/// Lives in MacCleanKit so both DuplicatesModule and FileConsolidator can hash
/// without depending on the app module. Returns nil if the file cannot be opened.
public enum FileHashing {
    /// Read a pinned descriptor with pread, preserving the caller's offset.
    /// Fail on I/O errors instead of treating a short failed read as EOF.
    static func sha256(descriptor: Int32) -> String? {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, $0.count, offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += off_t(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
