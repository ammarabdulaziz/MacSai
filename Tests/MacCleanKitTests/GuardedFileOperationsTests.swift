import XCTest
import Foundation
import Darwin
@testable import MacCleanKit

final class GuardedFileOperationsTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacSai-Guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func file(_ name: String, _ contents: String = "keep these bytes") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testSecureEraseRefusesHardLinkAndPreservesBothNames() throws {
        let original = try file("original")
        let alias = directory.appendingPathComponent("selected-alias")
        try FileManager.default.linkItem(at: original, to: alias)
        XCTAssertThrowsError(try GuardedFileOperations.secureErase(alias)) {
            XCTAssertEqual($0 as? GuardedFileError, .hardLinked)
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep these bytes")
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "keep these bytes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["original", "selected-alias"])
    }

    func testSecureEraseNormalFileAndLeavesNoStagingDirectory() throws {
        let selected = try file("selected")
        try GuardedFileOperations.secureErase(selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testSwappedSymlinkIsRestoredAndTargetIsNeverTouched() throws {
        let target = try file("target", "important target")
        let selected = try file("selected", "original selection")
        let saved = directory.appendingPathComponent("saved-selection")
        XCTAssertThrowsError(try CapturedFile(selected, beforeCapture: {
            try FileManager.default.moveItem(at: selected, to: saved)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: target)
        }))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "important target")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "original selection")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: selected.path), target.path)
    }

    func testSwappedRegularFileIsNotRemoved() throws {
        let selected = try file("selected", "selected contents")
        let saved = directory.appendingPathComponent("saved")
        XCTAssertThrowsError(try CapturedFile(selected, beforeCapture: {
            try FileManager.default.moveItem(at: selected, to: saved)
            try Data("replacement contents".utf8).write(to: selected)
        }))
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "replacement contents")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "selected contents")
    }

    func testStaleScanIdentityRefusesReplacementAtSamePath() throws {
        let selected = try file("selected")
        var info = stat()
        XCTAssertEqual(lstat(selected.path, &info), 0)
        let old = directory.appendingPathComponent("old")
        try FileManager.default.moveItem(at: selected, to: old)
        try Data("new file".utf8).write(to: selected)
        XCTAssertThrowsError(try GuardedFileOperations.remove(selected, inode: UInt64(info.st_ino), device: info.st_dev))
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "new file")
    }

    func testParentReplacementDoesNotRedirectPinnedOperation() throws {
        let selected = try file("selected")
        let captured = try CapturedFile(selected)
        let oldDirectory = directory.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: oldDirectory) }
        try FileManager.default.moveItem(at: directory, to: oldDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appendingPathComponent("selected")
        try Data("unrelated replacement tree".utf8).write(to: unrelated)
        try captured.remove()
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated replacement tree")
    }

    func testRecursiveDeletionUnlinksNestedSymlinkWithoutFollowingIt() throws {
        let target = try file("outside-target")
        let folder = directory.appendingPathComponent("selected-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: target)
        try GuardedFileOperations.remove(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep these bytes")
    }

    func testRestoreNeverOverwritesRecreatedOriginal() throws {
        let selected = try file("selected", "captured contents")
        let captured = try CapturedFile(selected)
        try Data("new contents".utf8).write(to: selected)
        XCTAssertThrowsError(try captured.restore())
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "new contents")
        XCTAssertEqual(try String(contentsOf: captured.stagingURL.appendingPathComponent("original"), encoding: .utf8),
                       "captured contents")
    }
}
