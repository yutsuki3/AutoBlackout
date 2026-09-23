import XCTest
@testable import AutoBlackout

final class LocalizationTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every `L("…")` key found in the sources, decoded the way the Swift compiler decodes the literal.
    private func sourceKeys() throws -> Set<String> {
        let sources = repoRoot.appendingPathComponent("Sources/AutoBlackout")
        var keys = Set<String>()
        let regex = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"\)"#)
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(match.range(at: 1), in: text)!])
                keys.insert(raw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\'", with: "'"))
            }
        }
        return keys
    }

    private func japanese() throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Resources/ja.lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
    }

    func testSourcesUseLocalizedStrings() throws {
        XCTAssertFalse(try sourceKeys().isEmpty)
    }

    func testEveryKeyInTheSourcesHasAJapaneseTranslation() throws {
        let translated = try japanese()
        for key in try sourceKeys() {
            XCTAssertNotNil(translated[key], "missing ja translation: \(key)")
        }
    }

    func testJapaneseFileHasNoStaleKeys() throws {
        let used = try sourceKeys()
        for key in try japanese().keys {
            XCTAssertTrue(used.contains(key), "unused ja key: \(key)")
        }
    }

    func testTranslationsAreNonEmptyAndKeepNewlines() throws {
        for (key, value) in try japanese() {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, key)
            XCTAssertEqual(key.contains("\n"), value.contains("\n"), "newline mismatch: \(key)")
        }
    }

    func testLookupFallsBackToEnglishOutsideTheAppBundle() {
        XCTAssertEqual(L("Quit"), "Quit")
    }
}
