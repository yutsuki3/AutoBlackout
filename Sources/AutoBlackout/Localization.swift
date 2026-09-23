import Foundation

// swiftlint:disable identifier_name

/// Looks up a user-visible string. The English text is the key, so a missing translation (or a
/// binary run outside the .app bundle, which has no .lproj folders) falls back to English.
///
/// Keys must be string literals: `LocalizationTests` scans the sources for `L("…")` calls and checks
/// each one against `Resources/ja.lproj/Localizable.strings`.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
// swiftlint:enable identifier_name
