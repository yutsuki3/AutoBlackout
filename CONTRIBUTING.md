# Contributing

Thanks for helping. AutoBlackout drives a private macOS API that can leave someone's built-in
display black until a reboot, so a few extra rules apply on top of the usual ones.

## Setup

```bash
git clone https://github.com/yutsuki3/AutoBlackout.git
cd AutoBlackout
swift build
swift test
brew install swiftlint && swiftlint lint --strict
```

CI runs the same three commands (plus packaging the `.app`) on every pull request.

## Ground rules

- **Tests never touch real hardware.** New logic goes in `AutoBlackoutCore` behind the
  `DisplaySystem` / `DisplayStateStore` / `Scheduler` protocols so it can be tested with the fakes
  in `Tests/AutoBlackoutCoreTests`. Tests in `AutoBlackoutTests` must use a temp directory and a
  throwaway `UserDefaults` suite, and must never call `PrivateDisplayAPI.setEnabled`.
- **Fail safe.** When in doubt, restore the built-in display rather than leave it off, and keep the
  OFF feature disabled on hosts that haven't been verified.
- **User-visible strings** go through `L("English text")` and need an entry in
  `Resources/ja.lproj/Localizable.strings` (a test fails if one is missing or stale). Log lines stay
  in English.
- Keep `swiftlint lint --strict` clean. Prefer fixing the code to disabling a rule.
- Update `CHANGELOG.md` under `[Unreleased]` for anything a user would notice.

## Changes that touch the restore path

If you change `PrivateDisplayAPI.swift`, or the restore logic in `BlackoutController.swift`, verify
it on real hardware before opening the PR, following
[docs/HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md) (`--verify-restore`, and `--after-unplug`).
Only do that with an external display and power connected, the lid open, and someone watching. State
the Mac model and macOS build you tested on in the PR.

## Adding a Mac to the verified list

1. Run `AutoBlackout --verify-restore --confirm-reboot-risk` (and ideally `--after-unplug`) on it.
2. Open a "Host verification report" issue with the output of `AutoBlackout --diagnose`.
3. A maintainer adds the model + macOS build to `HostVerification.shippedAllowlist`. Include the
   report link in that PR.

## Reporting bugs

Use the bug report template and paste the output of `AutoBlackout --diagnose`. For a stuck display,
see "Emergency recovery" in the [README](README.md) first.

## Releases (maintainers)

Move the `[Unreleased]` entries under a new version in `CHANGELOG.md`, merge, then push a
`vX.Y.Z` tag. `.github/workflows/release.yml` builds and publishes the zip and its SHA256.
