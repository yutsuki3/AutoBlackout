import AutoBlackoutCore
import XCTest

final class RestoreVerificationPreflightTests: XCTestCase {
    private let builtIn = DisplayInfo(id: 1, isBuiltin: true)
    private let usableExternal = DisplayInfo(id: 2, isBuiltin: false)

    private func problems(
        isAppleSilicon: Bool = true,
        isAPIAvailable: Bool = true,
        online: [DisplayInfo]? = nil,
        isLidClosed: Bool? = false,
        hasUnconfirmedManagedDisplay: Bool = false
    ) -> [RestoreVerificationProblem] {
        RestoreVerificationPreflight.problems(
            isAppleSilicon: isAppleSilicon,
            isAPIAvailable: isAPIAvailable,
            snapshot: DisplaySnapshot(online: online ?? [builtIn, usableExternal]),
            isLidClosed: isLidClosed,
            hasUnconfirmedManagedDisplay: hasUnconfirmedManagedDisplay
        )
    }

    func testEverythingReadyIsNoProblems() {
        XCTAssertEqual(problems(), [])
    }

    func testIntelMacIsBlocked() {
        XCTAssertEqual(problems(isAppleSilicon: false), [.intelNotSupported])
    }

    func testUnavailableAPIIsBlocked() {
        XCTAssertEqual(problems(isAPIAvailable: false), [.apiUnavailable])
    }

    func testMissingBuiltInPanelIsBlocked() {
        XCTAssertEqual(problems(online: [usableExternal]), [.builtInPanelNotOnline])
    }

    func testNoUsableExternalIsBlocked() {
        XCTAssertEqual(problems(online: [builtIn]), [.noUsableExternalDisplay])
    }

    func testAsleepExternalIsNotUsable() {
        let asleep = DisplayInfo(id: 2, isBuiltin: false, isAsleep: true)
        XCTAssertEqual(problems(online: [builtIn, asleep]), [.noUsableExternalDisplay])
    }

    func testClosedLidIsBlocked() {
        XCTAssertEqual(problems(isLidClosed: true), [.lidNotOpen])
    }

    func testUnknownLidStateIsBlocked() {
        // A lid state that can't be determined (`nil`) fails safe, same as a known-closed lid.
        XCTAssertEqual(problems(isLidClosed: nil), [.lidNotOpen])
    }

    func testUnconfirmedManagedDisplayIsBlocked() {
        XCTAssertEqual(problems(hasUnconfirmedManagedDisplay: true), [.unconfirmedPreviousRestore])
    }

    func testMultipleProblemsAreAllReported() {
        XCTAssertEqual(
            problems(isAppleSilicon: false, isAPIAvailable: false, online: []),
            [.intelNotSupported, .apiUnavailable, .builtInPanelNotOnline, .noUsableExternalDisplay]
        )
    }

    func testEveryProblemHasALogDescription() {
        for problem in RestoreVerificationProblem.allCases {
            XCTAssertFalse(problem.logDescription.isEmpty)
        }
    }
}
