import AutoBlackoutCore
import XCTest
@testable import AutoBlackout

final class HostInfoTests: XCTestCase {
    func testModelAndBuildAreResolvedOnThisMachine() {
        XCTAssertFalse(HostInfo.model.isEmpty)
        XCTAssertNotEqual(HostInfo.model, "unknown")
        XCTAssertFalse(HostInfo.osBuild.isEmpty)
        XCTAssertNotEqual(HostInfo.osBuild, "unknown")
    }

    func testSummaryContainsModelAndBuild() {
        XCTAssertTrue(HostInfo.summary.contains("model=\(HostInfo.model)"))
        XCTAssertTrue(HostInfo.summary.contains("build=\(HostInfo.osBuild)"))
    }

    func testCurrentHostKeyMatchesHostInfoAndIsIdentifiable() {
        XCTAssertEqual(HostVerification.current, HostKey(model: HostInfo.model, osBuild: HostInfo.osBuild))
        XCTAssertTrue(HostVerification.current.isIdentifiable)
    }

    func testShippedAllowlistContainsTheHardwareVerifiedHost() {
        // Guards against the one hardware-verified entry being dropped by accident.
        XCTAssertTrue(HostVerification.shippedAllowlist.contains(HostKey(model: "Mac15,12", osBuild: "25G229")))
    }

    func testEveryShippedAllowlistEntryIsIdentifiable() {
        for host in HostVerification.shippedAllowlist {
            XCTAssertTrue(host.isIdentifiable, "\(host)")
        }
    }

    func testVerificationDescriptionAgreesWithTheGate() {
        let verified = PrivateDisplayAPI.isDisableAllowed
        XCTAssertEqual(HostVerification.sourceDescription.hasPrefix("verified"), verified)
        // Never both "verified" and a re-verification notice.
        if verified { XCTAssertNil(HostVerification.reverificationNotice) }
    }
}

final class MainQueueSchedulerTests: XCTestCase {
    func testRunsWorkOnTheMainQueueAfterTheDelay() {
        let ran = expectation(description: "scheduled work ran")
        let start = Date()
        MainQueueScheduler().schedule(after: 0.1) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09)
            ran.fulfill()
        }
        wait(for: [ran], timeout: 2)
    }
}
