import XCTest
@testable import AutoBlackout

final class FileEventLoggerTests: ScratchTestCase {
    func testCreatesDirectoryAndWritesTimestampedPidLine() {
        let logger = FileEventLogger(directory: directory)
        logger.log("hello")
        let lines = readLog().split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("pid=\(getpid())"), String(lines[0]))
        XCTAssertTrue(lines[0].hasSuffix("hello"), String(lines[0]))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(lines[0].prefix(while: { $0 != " " }))))
    }

    func testAppendsInOrder() {
        let logger = FileEventLogger(directory: directory)
        logger.log("first")
        logger.log("second")
        logger.log("third")
        let lines = readLog().split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("first"))
        XCTAssertTrue(lines[1].hasSuffix("second"))
        XCTAssertTrue(lines[2].hasSuffix("third"))
    }

    func testNewlinesInAMessageStayOnOneLine() {
        FileEventLogger(directory: directory).log("a\nb\nc")
        let lines = readLog().split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("a b c"))
    }

    func testSecondLoggerInstanceAppendsToTheSameFile() {
        FileEventLogger(directory: directory).log("from first")
        FileEventLogger(directory: directory).log("from second")
        XCTAssertEqual(readLog().split(separator: "\n").count, 2)
    }

    func testRotatesWhenTheLogReachesTheSizeLimit() throws {
        let logger = FileEventLogger(directory: directory)
        logger.log("seed") // creates the directory and file
        try Data(repeating: UInt8(ascii: "x"), count: FileEventLogger.maxLogBytes)
            .write(to: logURL)

        logger.log("after rotation")

        let previous = logURL.appendingPathExtension("previous")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(try Data(contentsOf: previous).count, FileEventLogger.maxLogBytes)
        let current = readLog().split(separator: "\n")
        XCTAssertEqual(current.count, 1)
        XCTAssertTrue(current[0].hasSuffix("after rotation"))
    }

    func testDoesNotRotateBelowTheSizeLimit() throws {
        let logger = FileEventLogger(directory: directory)
        logger.log("seed")
        try Data(repeating: UInt8(ascii: "x"), count: FileEventLogger.maxLogBytes - 1).write(to: logURL)

        logger.log("still same file")

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("previous").path))
    }

    func testRotationReplacesAnOlderPreviousLog() throws {
        let logger = FileEventLogger(directory: directory)
        logger.log("seed")
        let previous = logURL.appendingPathExtension("previous")
        try Data("old previous".utf8).write(to: previous)
        try Data(repeating: UInt8(ascii: "y"), count: FileEventLogger.maxLogBytes).write(to: logURL)

        logger.log("rotate")

        XCTAssertEqual(try Data(contentsOf: previous).count, FileEventLogger.maxLogBytes)
    }

    func testUnwritableDirectoryDoesNotCrashAndWritesNothing() throws {
        // A regular file where the directory should be: createDirectory fails, logging is a no-op.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoBlackoutTests-blocker-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blocker) }

        FileEventLogger(directory: blocker).log("goes nowhere")

        var isDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue, "the blocking file must be left untouched")
        XCTAssertEqual(try Data(contentsOf: blocker).count, 0, "nothing may be written into it")
    }
}
