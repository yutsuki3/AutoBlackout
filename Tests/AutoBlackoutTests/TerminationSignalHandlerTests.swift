import XCTest
@testable import AutoBlackout

final class TerminationSignalHandlerTests: XCTestCase {
    func testRunsActionOnTheMainQueueWhenTheSignalArrives() {
        // SIGUSR1 stands in for SIGTERM so the test process isn't affected if the handler is broken.
        let received = expectation(description: "action runs")
        let handler = TerminationSignalHandler(signals: [SIGUSR1]) {
            XCTAssertTrue(Thread.isMainThread)
            received.fulfill()
        }
        kill(getpid(), SIGUSR1)
        wait(for: [received], timeout: 5)
        withExtendedLifetime(handler) {}
    }

    func testDefaultSignalsCoverTermHupAndInt() {
        XCTAssertEqual(Set(TerminationSignalHandler.defaultSignals), [SIGTERM, SIGHUP, SIGINT])
    }
}
