import XCTest
import Foundation
import Darwin
@testable import MacCleanKit

final class FileConsolidatorTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "FileConsolidator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ name: String, _ bytes: Data) throws -> URL {
        let u = dir.appending(path: name); try bytes.write(to: u); return u
    }

    func testEligibleIdenticalFilesHaveNoIneligibilityReason() throws {
        let m = try write("m", Data("same".utf8))
        let c = try write("c", Data("same".utf8))
        XCTAssertNil(FileConsolidator.ineligibilityReason(master: m, copy: c, safetyGuard: SafetyGuard()))
    }

    func testSymlinkCopyIsNotRegularFile() throws {
        let m = try write("m", Data("same".utf8))
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: m)
        XCTAssertEqual(
            FileConsolidator.ineligibilityReason(master: m, copy: link, safetyGuard: SafetyGuard()),
            .notRegularFile)
    }

    func testDirectoryCopyIsNotRegularFile() throws {
        let m = try write("m", Data("same".utf8))
        let sub = dir.appending(path: "subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(
            FileConsolidator.ineligibilityReason(master: m, copy: sub, safetyGuard: SafetyGuard()),
            .notRegularFile)
    }

    func testConsolidateKeepsBothFilesReclaimsAndPreservesCopyMetadata() throws {
        let payload = Data(repeating: 0xAB, count: 64 * 1024)
        let master = try write("master.bin", payload)
        let copy = try write("copy.bin", payload)
        // Give the copy its own perms + mtime so we can prove they survive.
        let mtime = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644)), .modificationDate: mtime],
            ofItemAtPath: copy.path(percentEncoded: false))

        let outcome = FileConsolidator.consolidate(master: master, copy: copy)

        guard case .reclaimed(let bytes) = outcome else {
            return XCTFail("expected reclaimed, got \(outcome)")
        }
        XCTAssertGreaterThan(bytes, 0)
        // Both paths still exist and are byte-identical.
        XCTAssertEqual(try Data(contentsOf: master), payload)
        XCTAssertEqual(try Data(contentsOf: copy), payload)
        // Copy kept its own metadata, not the master's.
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.path(percentEncoded: false))
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o644)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                       mtime.timeIntervalSince1970, accuracy: 1)
        // No leftover temp files in the directory.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        XCTAssertEqual(names.filter { $0.contains("consolidate-") }, [])
    }

    func testConsolidateSkipsWhenContentChanged() throws {
        let master = try write("m", Data("original".utf8))
        let copy = try write("c", Data("DIFFERENT".utf8))
        XCTAssertEqual(FileConsolidator.consolidate(master: master, copy: copy), .skipped(.contentChanged))
        // Untouched.
        XCTAssertEqual(try Data(contentsOf: copy), Data("DIFFERENT".utf8))
    }

    func testConsolidatePreservesDestinationQuarantineAndResourceFork() throws {
        let payload = Data(repeating: 0x35, count: 32 * 1024)
        let master = try write("metadata-master", payload)
        let copy = try write("metadata-copy", payload)
        func set(_ url: URL, _ name: String, _ bytes: Data) throws {
            let result = bytes.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        func get(_ url: URL, _ name: String) throws -> Data {
            let size = getxattr(url.path, name, nil, 0, 0, 0)
            guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
            guard read == size else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return data
        }
        let quarantine = Data("0081;00000000;MacSaiTest;".utf8)
        let resource = Data("destination-only resource fork".utf8)
        let tag = Data("destination tag".utf8)
        try set(copy, "com.apple.quarantine", quarantine)
        try set(copy, "com.apple.ResourceFork", resource)
        try set(copy, "org.macsai.test", tag)
        try set(master, "org.macsai.master-only", Data("must not leak".utf8))

        guard case .reclaimed = FileConsolidator.consolidate(master: master, copy: copy) else {
            return XCTFail("metadata-preserving consolidation failed")
        }
        XCTAssertEqual(try get(copy, "com.apple.quarantine"), quarantine)
        XCTAssertEqual(try get(copy, "com.apple.ResourceFork"), resource)
        XCTAssertEqual(try get(copy, "org.macsai.test"), tag)
        XCTAssertEqual(getxattr(copy.path, "org.macsai.master-only", nil, 0, 0, 0), -1)
        XCTAssertEqual(try Data(contentsOf: copy), payload)
        XCTAssertEqual(try Data(contentsOf: master), payload)
    }

    func testConsolidateIsIdempotentAndKeepsIntegrity() throws {
        let payload = Data(repeating: 0x5A, count: 32 * 1024)
        let master = try write("m", payload)
        let copy = try write("c", payload)
        _ = FileConsolidator.consolidate(master: master, copy: copy)
        let second = FileConsolidator.consolidate(master: master, copy: copy)
        // Second run must not corrupt anything (byte count may be optimistic).
        if case .failed(let msg) = second { XCTFail("second run failed: \(msg)") }
        XCTAssertEqual(try Data(contentsOf: copy), payload)
        XCTAssertEqual(try Data(contentsOf: master), payload)
    }

    /// Proves it actually CLONED (shared extents) rather than copied: a plain
    /// copy-over would net ~0 free space; a clone frees the copy's blocks.
    func testConsolidateActuallyReclaimsDiskSpace() throws {
        let size = 20 * 1024 * 1024
        let payload = Data(repeating: 0xC3, count: size)
        let master = try write("big-master.bin", payload)
        let copy = try write("big-copy.bin", payload)

        func freeBytes() -> UInt64 {
            var s = statfs()
            let r = dir.path(percentEncoded: false).withCString { statfs($0, &s) }
            return r == 0 ? UInt64(s.f_bavail) * UInt64(s.f_bsize) : 0
        }
        let before = freeBytes()
        guard case .reclaimed = FileConsolidator.consolidate(master: master, copy: copy) else {
            return XCTFail("expected reclaimed")
        }
        let after = freeBytes()
        // Freed at least 70% of the copy (tolerance for FS noise). A non-clone
        // copy-over would be ~0 or negative.
        XCTAssertGreaterThan(Int64(after) - Int64(before), Int64(Double(size) * 0.7),
                             "expected clone to free most of the copy's blocks")
    }

    func testBatchAggregatesReclaimedAndSkipped() throws {
        let payload = Data(repeating: 0x11, count: 8 * 1024)
        let master = try write("gm", payload)
        let good = try write("good", payload)
        let changed = try write("changed", Data("nope".utf8))
        let group = GroupConsolidation(master: master, copies: [good, changed])

        let summary = FileConsolidator.consolidate(groups: [group])

        XCTAssertEqual(summary.consolidatedCount, 1)
        XCTAssertGreaterThan(summary.reclaimedBytes, 0)
        XCTAssertEqual(summary.skipped, [SkippedItem(url: changed, reason: .contentChanged)])
        XCTAssertEqual(summary.failed, [])
    }

    func testEstimateSumsEligibleCopiesAndWritesNothing() throws {
        let payload = Data(repeating: 0x22, count: 16 * 1024)
        let master = try write("em", payload)
        let a = try write("ea", payload)
        let b = try write("eb", payload)
        let changed = try write("ec", Data("x".utf8))
        let before = try Data(contentsOf: a)

        let est = FileConsolidator.estimateReclaimable(
            groups: [GroupConsolidation(master: master, copies: [a, b, changed])])

        // a and b are eligible; `changed` is a different size but still passes the
        // step-1 checks (estimate does not hash), so all three regular files count.
        // The estimate is a cheap preview.
        XCTAssertGreaterThan(est, 0)
        // Nothing was written.
        XCTAssertEqual(try Data(contentsOf: a), before)
        XCTAssertEqual(try Data(contentsOf: master), payload)
    }
}
