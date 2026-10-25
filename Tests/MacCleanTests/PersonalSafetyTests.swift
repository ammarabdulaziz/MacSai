import XCTest
import Foundation
@testable import MacClean
@testable import MacCleanKit

final class PersonalSafetyTests: XCTestCase {
    func testHeuristicMalwareIsNeverPreselected() {
        XCTAssertFalse(ScanCategory.malware.autoSelect)
    }

    func testLegitimateScriptingToolsAloneAreNotMalware() {
        for arguments in [
            ["/usr/bin/osascript", "-e", "display notification \"hello\""],
            ["/usr/bin/python3", "-c", "print('hello')"],
            ["/usr/bin/curl", "https://example.com/status"],
            ["/usr/bin/base64", "data.txt"],
            ["/tmp/legitimate-build-helper"]
        ] {
            XCTAssertFalse(MalwareSignatures.launchAgentLooksSuspicious(plist: ["ProgramArguments": arguments]))
        }
    }
}
