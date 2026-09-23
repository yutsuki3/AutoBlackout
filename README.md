# AutoBlackout

A macOS menu bar app that automatically turns off the built-in display when an external display is
connected.

For personal use. It resolves the private APIs (`SLSConfigureDisplayEnabled` /
`CGSConfigureDisplayEnabled`) at runtime with `dlsym`, so it can't be distributed through the Mac
App Store. A macOS update could break it at any time.

## Current scope

- [x] Manual toggle from the menu bar
- [x] Auto-OFF when an external monitor connects / auto-restore when every external monitor is unplugged
- [ ] Re-apply state on sleep/wake
- [ ] Refine what counts as "an external display is present" (excluding mirrored displays, sleeping displays, etc.)
- [ ] Fall back across more private symbol names (macOS version differences)

## Environment support

- macOS 13 (Ventura) or later
- Apple Silicon only. The private API used to fully disconnect the built-in display doesn't behave
  the same way on Intel Macs.
- **The OFF (disable) feature only works on Mac model + macOS build combinations that have been
  verified to restore correctly**, either shipped in the app's allowlist or verified locally by
  running `AutoBlackout --verify-restore`. See the next section for why, and "Verifying the restore
  procedure on your Mac" for how to verify your own machine. On an unverified host the menu item
  reads "OFF is disabled (restore not verified on this Mac)" and the app never calls the disable API
  at all, so there's no functional risk on a machine you haven't verified — just a feature that
  isn't available yet.

## Why OFF is gated per host, and how restoring the panel works on the MacBook Air M3

### The incident

On a MacBook Air M3 (Mac15,12) / macOS 26.7 (25G229), after turning the built-in display off, the
request to turn it back on (`SLSConfigureDisplayEnabled(config, 1, true)` ->
`CGCompleteDisplayConfiguration`) failed with `1001` (kCGErrorIllegalArgument), and only a reboot
brought it back. This happened twice.

### Root cause (from WindowServer's logs and a SkyLight disassembly)

1. Entry-level M3 models repurpose the built-in panel's connection so the machine can drive two
   external displays with the lid closed. As a side effect, disabling the panel makes it look
   hardware-disconnected (IOMFB logs `Display 1 hot plug 0`).
2. In that state, WindowServer's `configuration_engine::config_via_client_api` rejects the enable
   request in a precheck and returns 1001 (before the `client api - Enable display` log line even
   appears). Changing the commit options (e.g. `.permanently`) or bundling other changes into the
   same transaction doesn't change the outcome of that check.
3. Once the panel is re-powered (`Display 1 hot plug 1`) — by a display sleep/wake cycle or by
   closing and reopening the lid — the enable request succeeds. In both incidents, no process was
   running to send the enable request once the panel was re-powered.
4. See also: [BetterDisplay #5658](https://github.com/waydabber/BetterDisplay/issues/5658) (the same
   workaround reported on the same model), and
   [#4723](https://github.com/waydabber/BetterDisplay/issues/4723) (BetterDisplay disables built-in
   OFF by default on this model).

### The restore procedure

While the enable request keeps failing, `BlackoutController` tries, in order:

1. Send an enable request about once a second, and keep going until the restore is confirmed against
   reality.
2. After 3 consecutive failures, power-cycle the displays (`pmset displaysleepnow` -> declare user
   activity after 3 seconds to wake them). No enable requests are sent for 6 seconds afterward
   (sending one while asleep blocks for up to 10 seconds waiting on WindowServer to reconfigure, and
   then fails with 1014). Up to 2 power cycles.
3. If it still hasn't come back, the menu shows "close the lid, wait a few seconds, then open it".
   Enable requests keep being retried regardless.

Other measures baked in:

- Re-evaluates immediately on a sleep-wake notification.
- Waits 3 seconds after an external display disappears from the list before restoring the built-in
  display. USB-C monitors briefly disconnect and reconnect on wake (about 0.7s on real hardware);
  restoring during that window would cause "the built-in display flashes on and immediately turns
  off again". No wait if there's no external display at launch.
- An external display that's asleep still counts as "connected"; the built-in display is only
  restored once it disappears from the list (e.g. the cable is unplugged). Waiting on the sleep
  notification itself was tried and abandoned — the external's sleep sometimes becomes visible
  before the notification arrives, causing a premature restore. Auto-OFF only fires when a new
  external display connects; waking from sleep doesn't count as a new connection.
- The built-in panel is treated as "ON" while it's merely display-asleep (it's still in the online
  list), so idle sleep with no external display doesn't trigger a restore attempt.
- If an enable request was accepted but never applied (WindowServer logs `Failed to plug display 1`)
  and the panel came back through the power-cycle restore path instead, it power-cycles once more
  while ON. That restore path leaves WindowServer's internal panel connection state out of sync — the
  next disable only drops it from the configuration without actually cutting power (the screen stays
  lit). Confirmed on real hardware to happen after opening and closing the lid while the panel was off.
- Quitting from the menu while the built-in display is off waits for the restore to be confirmed
  first. If it doesn't come back within 60 seconds, the quit is cancelled.
- `--restore` and `--verify-restore` also run on `NSApplication` rather than a bare `RunLoop`. A bare
  run loop doesn't process screen-change notifications after this process commits its own
  configuration change, so an unplugged external display stayed in the online list (reproduced and
  confirmed with a virtual display).

### Real-hardware verification (2026-09-23, Mac15,12 / macOS 26.7)

| Scenario | Command | Result |
|---|---|---|
| Restore to ON with the external still connected | `--verify-restore --confirm-reboot-risk` | 1001 four times -> one power cycle -> restored 16.5s after the request |
| Restore after unplugging the external while OFF | `--verify-restore --confirm-reboot-risk --after-unplug` | detected zero screens -> 1001 three times -> one power cycle -> restored about 10s after the unplug (measured before the 3-second grace period was added) |

### Verifying the restore procedure on your Mac

The disable feature (`OFF`) is only enabled on Mac model + macOS build combinations that have been
confirmed, on real hardware, to actually restore correctly — see the section above for why. The app
ships with just one verified entry (the author's own MacBook Air M3 on macOS 26.7). On every other
machine, OFF stays disabled (the menu item is grayed out) until you verify it yourself:

```bash
.build/release/AutoBlackout --verify-restore --confirm-reboot-risk
```

This disables the built-in display once and checks whether the app's own restore procedure (above)
brings it back. **If it doesn't come back, a reboot is required** — only run this with an external
display and power connected, the lid open, and you watching. On success, this exact Mac model +
macOS build is remembered (in `UserDefaults`) as verified, and the OFF feature becomes available.

Also re-run this after every macOS update, on any machine, verified or not — a build change means
the WindowServer behavior underneath hasn't been re-checked, so the app requires it to be
re-verified again (see the allowlist's `osBuild` matching in
[PrivateDisplayAPI.swift](Sources/AutoBlackout/PrivateDisplayAPI.swift)).

Add `--after-unplug` to instead verify the restore that happens when the external display is
unplugged while OFF, rather than requesting a restore yourself.

### Notes

- Don't force-quit the app (`kill -9`, or Force Quit from Activity Monitor) while the built-in
  display is off — that kills the process that would otherwise send the restore request. If you did
  force-quit it, relaunch the app or run `--restore` (it detects a still-disabled panel at launch and
  restores it).
- If the screen stays black and doesn't come back, close the lid and reopen it after a few seconds
  (the app, or `--restore`, will pick up from there if either is running).

## Building

For development testing (use "Packaging" below for day-to-day use):

```bash
swift build -c release
.build/release/AutoBlackout
```

Running the raw binary directly registers a *separate* "allow in menu bar" entry in System Settings
from the `.app` bundle. Rebuilding and directly running the same binary repeatedly stacks up entries
there, so avoid this outside of quick development checks.

## Packaging (as a .app)

```bash
scripts/build-app.sh
```

Produces `.build/release/AutoBlackout.app` (ad-hoc signed). Copy it to `/Applications` to launch it
like a normal app from Finder or Spotlight.

```bash
cp -R .build/release/AutoBlackout.app /Applications/
```

If Gatekeeper warns "can't verify the developer" on first launch, right-click it in Finder and choose
"Open" to allow it (it's ad-hoc signed, not signed with an Apple Developer certificate — intended for
personal use only).

From the menu bar you can:

- **Launch at login** — registers/unregisters a login item via `SMAppService` (also visible under
  System Settings > General > Login Items). Worth enabling if you use an external monitor regularly.
- **About AutoBlackout** — the standard About panel with version info.

To regenerate the icon, run `swift scripts/make-icon.swift`, which rewrites
`Resources/AppIcon.icns` (`scripts/build-app.sh` reuses the existing `.icns`, so this only needs to
be re-run if you change the icon).

## Tests (never touch a real display)

```bash
swift test
```

## Emergency recovery

If the built-in display gets stuck off (e.g. from SSH):

```bash
.build/release/AutoBlackout --restore
# if installed to /Applications:
/Applications/AutoBlackout.app/Contents/MacOS/AutoBlackout --restore
```

If it reports that it couldn't restore, keep the command running, close the lid, wait about 5
seconds, then open it.

Logs: `~/Library/Logs/AutoBlackout/recovery.log` (also written to the os_log subsystem
`io.github.yutsuki3.AutoBlackout`).

## Design

- `AutoBlackoutCore/` — the logic layer, unit-tested, that never touches real hardware.
  - `BlackoutController.swift` — the state machine. Detects "zero external displays but the built-in
    one is disabled" and retries the restore until it's confirmed against reality. Every path —
    reconfiguration callbacks, the 1-second poll, self-healing at launch, and restoring on quit —
    goes through here.
  - `DisplayLogic.swift` / `DisplayTypes.swift` — pure decisions made from a snapshot, and the
    protocol abstraction over real hardware.
- `AutoBlackout/` — the real-hardware surface.
  - `PrivateDisplayAPI.swift` — isolates the private API calls, and the per-host restore-verification
    allowlist.
  - `LiveSystem.swift` — the production implementation of the protocols (CG, UserDefaults, log file).
  - `DisplayMonitor.swift` — registers the reconfiguration callback only.
  - `AppDelegate.swift` / `main.swift` — the UI layer and the `--restore` emergency-recovery mode.
- `Resources/` — `Info.plist` and `AppIcon.icns` (the `.app` bundle's assets).
- `scripts/` — `build-app.sh` (assembles and ad-hoc signs the `.app` bundle) and `make-icon.swift`
  (generates the icon).

Referenced while building this: [alin23/Lunar](https://github.com/alin23/Lunar) (the design of its
BlackOut feature) and [0xruth1ezz/screen-toggle](https://github.com/0xruth1ezz/screen-toggle) (how to
call the private API and build in safety checks).

## License

MIT — see [LICENSE](LICENSE).
