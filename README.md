# AutoBlackout

A macOS menu bar app that automatically turns off the built-in display when an external display is
connected.

For personal use. It resolves the private APIs (`SLSConfigureDisplayEnabled` /
`CGSConfigureDisplayEnabled`) at runtime with `dlsym`, so it can't be distributed through the Mac
App Store, and a macOS update could break it at any time.

## Features

- Automatically turns the built-in display off when an external monitor connects, and back on when
  every external monitor is disconnected.
- Manual toggle, and a "force restore" action, from the menu bar.
- Self-heals on launch and on a background poll, so a missed callback or a crashed previous process
  can't leave the built-in display stuck off.
- Optional login item, via `SMAppService`.

Not yet implemented:

- Re-applying state on sleep/wake beyond the existing safeguards.
- Refining what counts as "an external display is present" (excluding mirrored displays more
  precisely, etc.).
- Falling back across more private symbol names for macOS version differences.

## Requirements

- macOS 13 (Ventura) or later.
- Apple Silicon only. The private API used to fully disconnect the built-in display doesn't behave
  the same way on Intel Macs.
- The auto/manual **OFF** feature only works on a Mac model + macOS build combination that's been
  verified to restore the display correctly afterward. The app ships with one verified combination;
  on any other machine, OFF stays disabled until you verify it yourself with one command. See
  [docs/HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md) for why this exists and how to verify your
  Mac. Nothing risky happens on an unverified machine — the feature is simply unavailable.

## Installation

### Packaging (recommended)

```bash
scripts/build-app.sh
cp -R .build/release/AutoBlackout.app /Applications/
```

This ad-hoc signs `.build/release/AutoBlackout.app`, which you can then launch like a normal app
from Finder or Spotlight. If Gatekeeper warns "can't verify the developer" on first launch,
right-click it in Finder and choose "Open" to allow it (it's ad-hoc signed, not signed with an
Apple Developer certificate).

To regenerate the app icon, run `swift scripts/make-icon.swift`, which rewrites
`Resources/AppIcon.icns`.

### Development build

```bash
swift build -c release
.build/release/AutoBlackout
```

Running the raw binary directly registers a *separate* "allow in menu bar" entry in System Settings
from the `.app` bundle. Rebuilding and directly running the same binary repeatedly stacks up entries
there, so prefer the packaged `.app` outside of quick development checks.

## Usage

From the menu bar:

- **Turn built-in display OFF / back ON** — manual toggle. Refuses to turn OFF with no external
  display connected, and is disabled entirely on an unverified host (see Requirements above).
- **Force-restore built-in display** — always sends a restore request, regardless of the displayed status.
- **Auto-OFF on external monitor connect** — toggles the automatic behavior.
- **Launch at login** — registers/unregisters a login item (also visible under System Settings >
  General > Login Items).
- **Show Logs** — opens `~/Library/Logs/AutoBlackout/`.

## Emergency recovery

If the built-in display gets stuck off (e.g. reachable only over SSH):

```bash
.build/release/AutoBlackout --restore
# or, if installed to /Applications:
/Applications/AutoBlackout.app/Contents/MacOS/AutoBlackout --restore
```

If it reports that it couldn't restore, keep the command running, close the lid, wait about 5
seconds, then open it. See [docs/HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md) for more detail on
what to do if the display doesn't come back.

## Testing

```bash
swift test
```

Tests never touch a real display.

## Project layout

- `AutoBlackoutCore/` — the logic layer, unit-tested, that never touches real hardware.
  - `BlackoutController.swift` — the state machine. Every path (reconfiguration callbacks, the
    1-second poll, self-healing at launch, restoring on quit) goes through here.
  - `DisplayLogic.swift` / `DisplayTypes.swift` — pure decisions made from a snapshot, and the
    protocol abstraction over real hardware.
- `AutoBlackout/` — the real-hardware surface.
  - `PrivateDisplayAPI.swift` — isolates the private API calls, and the per-host restore-verification
    allowlist (see [docs/HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md)).
  - `LiveSystem.swift` — the production implementation of the protocols (CG, UserDefaults, log file).
  - `DisplayMonitor.swift` — registers the reconfiguration callback only.
  - `AppDelegate.swift` / `main.swift` — the UI layer and the `--restore` / `--verify-restore`
    command-line modes.
- `Resources/` — `Info.plist` and `AppIcon.icns` (the `.app` bundle's assets).
- `scripts/` — `build-app.sh` (assembles and ad-hoc signs the `.app` bundle) and `make-icon.swift`
  (generates the icon).
- `docs/` — background that's useful but too detailed for this README.

## Contributing

Issues and PRs are welcome. If a change touches `PrivateDisplayAPI.swift` or
`BlackoutController.swift`'s restore logic, please run `swift test` and, if you can do so safely
(see [docs/HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md)), verify the change on real hardware
before opening a PR — a bug here can strand someone's display until they reboot.

## Credits

Referenced while building this: [alin23/Lunar](https://github.com/alin23/Lunar) (the design of its
BlackOut feature) and [0xruth1ezz/screen-toggle](https://github.com/0xruth1ezz/screen-toggle) (how to
call the private API and build in safety checks).

## License

MIT — see [LICENSE](LICENSE).
