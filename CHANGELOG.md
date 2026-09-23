# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `AutoBlackoutTests`: unit tests for the executable target (log file writing and rotation, the
  cross-process state store, `--diagnose` formatting, host info, the main-queue scheduler). They
  use a temporary directory and a throwaway `UserDefaults` suite, and never touch a real display or
  the real log/state.

### Changed
- `FileEventLogger` and `UserDefaultsStateStore` accept an injectable directory / `UserDefaults`
  (defaults unchanged).

## [1.1.0] - 2026-09-23

### Added
- SwiftLint (`.swiftlint.yml`), enforced in CI with `--strict`.
- Re-verification notice: when a macOS update changes the build of a Mac model that was verified
  earlier (shipped or locally), the menu says so and links to the verification steps, the launch log
  records it, and `--diagnose` reports it. OFF stays disabled until re-verified, as before.

### Changed
- Host-verification decision logic moved into `AutoBlackoutCore` (`HostVerifier`) with an injectable
  host, allowlist and storage, and covered by unit tests. An unidentifiable host (failed
  `hw.model` / `kern.osversion` lookup) is now never treated as verified.

## [1.0.0] - 2026-09-23

First public release.

### Added
- Auto-OFF of the built-in display on external monitor connect, with a restore procedure and
  self-healing, a per-host verification gate, and `--restore` / `--verify-restore` modes.
- GitHub Actions CI (build, test, package) and a tag-triggered release workflow.
- `--diagnose` (read-only report for bug reports) and `--version` command-line flags.
- Issue templates (bug report, host verification report) and a pull request template.
- `SECURITY.md`.

### Changed
- License wording unified to MIT (removed the "personal use only" notes).
