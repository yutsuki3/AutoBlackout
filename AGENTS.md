# AGENTS.md

Instructions for AI coding agents (and humans) working on this repository. Read this file in full
before changing anything. Rules marked **MUST** / **NEVER** are hard constraints; if a task seems
to require breaking one, stop and ask the maintainer instead.

## What this project is

AutoBlackout is a macOS menu bar app (Swift, SwiftPM, AppKit, macOS 13+, Apple Silicon) that turns
the built-in display **off** when an external display connects and back **on** when it disconnects.
It does this through undocumented private APIs (`SLSConfigureDisplayEnabled` /
`CGSConfigureDisplayEnabled`, resolved with `dlsym`).

**A bug here can leave a user's only screen black until they reboot.** That is the failure every
rule below exists to prevent. Background: [docs/HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md).

## Priorities (in this order, always)

1. **User safety** — the built-in display must always come back. Never trade this for anything.
2. **UX** — no surprises: the user can see what's about to happen and stop it.
3. **Performance** — battery and CPU, only where 1 and 2 are untouched.

When two goals conflict, the higher one wins. When unsure whether a change affects safety, assume
it does.

## Safety invariants

These describe how the code works today. A change MUST keep every one of them true.

1. **Never leave the built-in display disabled without a usable external display.** This is the
   top rule of `BlackoutController`.
2. **Decide from reality, not memory.** Every decision is made from a fresh
   `DisplaySystem.snapshot()`. Never add an in-memory "it's OFF" flag that a decision trusts.
3. **Persist before disabling.** `managedDisplay` (persisted via `DisplayStateStore`) is written
   *before* the disable call, so a crash right after can still restore on next launch.
4. **Verify every switch.** The API can report success without applying. Both OFF and ON are
   re-checked against a new snapshot after `verifyDelay`; restores retry until confirmed.
5. **OFF is gated per host.** `PrivateDisplayAPI.isDisableAllowed` is true only on Apple Silicon
   and a verified (Mac model, macOS build). Never widen this gate, never default it to true, never
   bypass it outside the explicit verification flows (`--verify-restore`, in-app "Verify this Mac").
6. **New features may delay OFF, never a restore.** Countdowns, confirmations and similar may only
   delay turning the panel **OFF**. The only restore delays are the existing, documented ones:
   `externalLossGrace` (3s, so a USB-C monitor's brief reconnect on wake doesn't flash the panel)
   and the sleep/wake settle window, which applies only to a panel this app did *not* disable. The
   manual force-restore, `--restore`, quit and launch self-heal (with no external display) start
   immediately. Don't add new restore delays or lengthen these.
7. **Self-heal on every path.** `launch()` adopts a panel missing from the online list; the 1s poll
   corrects missed callbacks; quitting waits (up to 60s) for a confirmed restore and cancels the
   quit otherwise; `--restore` works from SSH. Don't remove or weaken any of these.
8. **Single correction loop.** Every path goes through `BlackoutController.evaluate`. Don't add a
   second place that decides to switch the display.
9. **Temporary overrides never overwrite user choices.** Verification, quitting and unverified
   hosts force auto mode off for a while; that must not be saved as the user's preference.
10. **Only `LiveDisplaySystem.setEnabled` touches a real display.** Keep it that way.

## Change risk levels

Classify every change before starting and state the level in the PR.

| Level | Touches | Requirements |
|---|---|---|
| **High** | `Sources/AutoBlackout/PrivateDisplayAPI.swift`; restore logic in `BlackoutController.swift` (`attemptRestore`, `verifyRestore`, power cycling, repair, `prepareForTermination`, `launch`, the external-loss path); `HostVerification.shippedAllowlist`; `LiveDisplaySystem.powerCycleDisplays` | Everything below **plus** verification on real hardware by a human (`--verify-restore`, `--after-unplug`, see CONTRIBUTING.md) with the Mac model / macOS build stated in the PR. An agent can't do this: say so in the PR and leave the checklist box unchecked. Adding a host needs a linked verification-report issue. |
| **Medium** | Other `BlackoutController` logic (auto-OFF, sleep/wake), `DisplayLogic`, the menu/UI state that enables actions, verification flows, anything persisted | Unit tests for every new branch, using the fakes. Call out in the PR which invariants were considered. |
| **Low** | Docs, strings, logging, UI text/layout that can't change what gets switched | Normal checks. |

If a change mixes levels, treat the whole PR as the highest one. Keep High-risk changes in their
own small PR.

## Architecture rules

- `Sources/AutoBlackoutCore/` — pure logic, unit-tested, **no real hardware**. New decision logic
  goes here, behind the `DisplaySystem` / `DisplayStateStore` / `Scheduler` / `EventLogger`
  protocols, with time injected via `now`.
- `Sources/AutoBlackout/` — the real-hardware surface and AppKit UI. Keep it thin: wiring, menus,
  HUDs, command-line modes.
- New tunables (delays, limits) are named `static let` constants on `BlackoutController` with a doc
  comment saying why that value; make them injectable in `init` when tests need a different value,
  with a default that keeps existing behavior.
- Explain *why* in comments for any non-obvious timing or ordering, citing the real-hardware
  observation if there was one. The existing code does this consistently; match it.

## Testing rules

- **NEVER** call `PrivateDisplayAPI.setEnabled`, `LiveDisplaySystem`, `pmset`, or anything that
  touches a real display from tests.
- Core tests use `FakeDisplaySystem`, `MemoryStore`, `ManualScheduler` (time advances only via
  `advance()`; also move the injected `clock`), `RecordingLogger`.
- App tests subclass `ScratchTestCase`: temp directory and throwaway `UserDefaults` suite only. Never
  the real log directory or the app's real defaults domain.
- Every behavior change gets a test for the new path **and** for the safety-relevant edge cases:
  unplug mid-operation, sleep/wake mid-operation, auto mode toggled mid-operation, manual action
  mid-operation, quitting.
- **NEVER** skip, disable, delete or weaken a test to get green.

## Required checks before every push

```bash
swift build
swift test
swiftlint lint --strict
```

CI (`.github/workflows/ci.yml`, macOS) runs these plus `scripts/build-app.sh`. If your environment
has no Swift toolchain (e.g. Linux), say so in the PR and wait for CI before calling the work done.

Lint gotchas seen in this repo:
- `line_length` warns above 130 characters, and `--strict` turns warnings into errors.
- `superfluous_disable_command`: a `// swiftlint:disable:next line_length` on a line that fits is
  itself an error. Add a disable only when the line really exceeds the limit.
- `function_body_length` (100) and `cyclomatic_complexity` (25): `evaluate` is close to both. Put
  new branches in a private helper instead of growing it.

## User-facing text

- Every user-visible string goes through `L("English text")` with a string-literal key, and needs
  an entry in `Resources/ja.lproj/Localizable.strings`. `LocalizationTests` fails on a missing or
  unused key and on mismatched newlines.
- Japanese style: match the existing entries (e.g. `内蔵ディスプレイ: オン`, ASCII colon + space).
- Log lines stay in English, single line, and include enough state to debug from a user's log.
- Warnings about risk must be plain and honest; never downplay the reboot risk.

## Documentation and PRs

- Update `CHANGELOG.md` under `[Unreleased]` for anything a user would notice, and README's Usage
  section when menu behavior changes.
- Follow `.github/pull_request_template.md`. Fill in "Tested on" truthfully: "not run on hardware"
  is an acceptable answer; claiming a test you didn't do is not.
- One concern per PR. Don't mix refactors with behavior changes on the restore path.

## Things an agent must not do on its own

- Add a host to `shippedAllowlist`, or change how host verification is decided.
- Change the restore procedure's timings, retry counts or power-cycle limits.
- Run the app, `--verify-restore`, `--power-cycle-displays` or anything that disables a real
  display. Only a human with an external display connected, lid open and watching may do this.
- Change signing, entitlements, release workflow or the bundle identifier.
- Release, tag or bump versions unless asked.

Ask the maintainer instead, with the trade-off spelled out.

## Quick map

- `Sources/AutoBlackoutCore/BlackoutController.swift` — the state machine (entry points:
  `launch`, `evaluate`, `handlePowerEvent`, `toggleManually`, `requestRestore`,
  `prepareForTermination`).
- `Sources/AutoBlackoutCore/DisplayLogic.swift` / `DisplayTypes.swift` — pure snapshot decisions
  and protocols.
- `Sources/AutoBlackoutCore/HostVerifier.swift` — verified-host decision.
- `Sources/AutoBlackout/PrivateDisplayAPI.swift` — the private API and the host allowlist.
- `Sources/AutoBlackout/LiveSystem.swift` — real implementations (CG, UserDefaults, log file,
  power cycle).
- `Sources/AutoBlackout/AppDelegate.swift` — menu, alerts, wiring.
- `Sources/AutoBlackout/main.swift` — `--restore`, `--verify-restore`, `--diagnose`, `--version`.
- `docs/HOST_VERIFICATION.md` — the incident, the restore procedure, verifying a Mac.
