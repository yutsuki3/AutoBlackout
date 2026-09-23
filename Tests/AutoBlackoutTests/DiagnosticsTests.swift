import AutoBlackoutCore
import XCTest
@testable import AutoBlackout

final class DiagnosticsTests: ScratchTestCase {
    func testRowsForNoDisplays() {
        XCTAssertEqual(Diagnostics.rows([]), ["- none"])
    }

    func testRowsListEveryFieldWithHexVendorAndModel() {
        let info = DisplayInfo(
            id: 3, isBuiltin: false, isOnline: true, isActive: true,
            isAsleep: false, isInMirrorSet: true, vendor: 0x10ac, model: 0xa1d0
        )
        XCTAssertEqual(
            Diagnostics.rows([info]),
            ["- id=3 builtin=false online=true active=true asleep=false mirror=true vendor=0x10ac model=0xa1d0"]
        )
    }

    func testRowsKeepOrderOneLinePerDisplay() {
        let rows = Diagnostics.rows([DisplayInfo(id: 1, isBuiltin: true), DisplayInfo(id: 2, isBuiltin: false)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].hasPrefix("- id=1 builtin=true"))
        XCTAssertTrue(rows[1].hasPrefix("- id=2 builtin=false"))
    }

    func testTailWithoutALogFile() {
        XCTAssertEqual(Diagnostics.tail(10, in: directory), ["(no log)"])
    }

    func testTailReturnsOnlyTheLastLines() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (1...10).map { "line \($0)" }.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(Diagnostics.tail(3, in: directory), ["line 8", "line 9", "line 10"])
    }

    func testTailReturnsEverythingWhenShorterThanRequested() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "a\nb\n".write(to: logURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(Diagnostics.tail(30, in: directory), ["a", "b"])
    }

    func testTailSkipsBlankLines() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "a\n\n\nb\n".write(to: logURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(Diagnostics.tail(5, in: directory), ["a", "b"])
    }

    func testTailReadsWhatFileEventLoggerWrote() {
        let logger = FileEventLogger(directory: directory)
        logger.log("one")
        logger.log("two")
        let tail = Diagnostics.tail(1, in: directory)
        XCTAssertEqual(tail.count, 1)
        XCTAssertTrue(tail[0].hasSuffix("two"))
    }

    func testAppVersionIsNeverEmpty() {
        XCTAssertFalse(AppVersion.string.isEmpty)
    }
}
