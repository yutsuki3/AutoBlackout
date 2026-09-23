# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- README now opens with a plain "Status" section: verified on one Mac only, can leave the built-in
  display black, likely to break with macOS updates, unsigned, built with an AI assistant and not
  independently reviewed, unaffiliated, no warranty.

### Changed
- Credits rewritten to state plainly how Lunar and screen-toggle relate to this project (functionality
  informed by them, no code intentionally copied, not affiliated), and `THIRD_PARTY_NOTICES.md` added
  with their MIT license notices. The `.app` bundle now includes `LICENSE` and
  `THIRD_PARTY_NOTICES.md`.

## [1.2.4] - 2026-09-24

### Fixed
- Auto-OFF didn't fire when the external display was unplugged during sleep and plugged back in a
  few seconds after waking: the 60-second "same display returning after sleep" allowance (added in
  1.2.2) treated it as the monitor resuming. A monitor resuming by itself comes back about a second
  after the wake notifications, so the allowance is now 5 seconds.

## [1.2.3] - 2026-09-24

### Fixed
- Unplugging the external display while the Mac was asleep, then waking it, showed the "restoring
  the built-in display" overlay for ~13 seconds. The built-in panel is briefly missing from the
  display list around such a wake (the Mac may even go straight back to sleep), and the app started
  its restore procedure for a panel it had never disabled, power-cycling the displays and waking a Mac
  that was trying to sleep. A panel this app didn't disable is now given time to settle while the Mac
  is sleeping or within 8 seconds after a wake; if it's still missing after that, the restore runs as
  before. A panel the app did disable, and the manual force-restore, are never delayed.

## [1.2.2] - 2026-09-24

### Fixed
- With "Auto-OFF on external monitor connect" on, waking from sleep turned the built-in display off
  again. A system sleep/wake drops the external display out of the online list and brings it back,
  and that reappearance was treated as a new connection. The controller now remembers which external
  displays were connected going to sleep and treats the same display returning within 60 seconds of
  waking as resuming, not connecting. A different display, or the same one replugged after the window
  (or after an unplug/replug once it has resumed), still auto-OFFs.

## [1.2.1] - 2026-09-24

### Added
- `power:` log lines for every sleep / wake / screen sleep / screen wake notification, with the panel
  and display state at that moment (log-only, no behavior change). `evaluate` only logs when the
  state changed, so an unchanged sleep/wake used to leave no trace.

## [1.2.0] - 2026-09-24

### Added
- Japanese localization of the menu, alerts and restore overlay (`Resources/ja.lproj`, bundled into
  the `.app`); a test keeps the source strings and the translations in sync.
- Intel Macs are detected: the OFF feature stays disabled there and `--verify-restore` refuses to
  run. `--diagnose` and the launch log report the architecture.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and Dependabot updates for GitHub Actions.
- `AutoBlackoutTests`: unit tests for the executable target (log file writing and rotation, the
  cross-process state store, `--diagnose` formatting, host info, the main-queue scheduler). They
  use a temporary directory and a throwaway `UserDefaults` suite, and never touch a real display or
  the real log/state.

### Changed
- The `.app` no longer logs a Foundation warning about using its own bundle ID as a
  `UserDefaults` suite name (same saved state as before).
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
