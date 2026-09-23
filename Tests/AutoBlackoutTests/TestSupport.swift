import XCTest

/// Per-test scratch space so no test ever touches the real log directory or the app's real
/// `UserDefaults` suite.
class ScratchTestCase: XCTestCase {
    private(set) var directory: URL!
    private(set) var suiteName = ""
    private(set) var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoBlackoutTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "AutoBlackoutTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    var logURL: URL { directory.appendingPathComponent("recovery.log") }

    func readLog() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }
}
