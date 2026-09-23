# Why the disable feature is gated per host, and how the restore procedure works

This documents the incident that led to `PrivateDisplayAPI.isDisableAllowed` being gated per
(Mac model, macOS build) instead of a flat `true`, the restore procedure `BlackoutController` runs
to recover from it, and how to verify your own Mac. See the README for a quick summary and the
one-line command to run.

## The incident

On a MacBook Air M3 (Mac15,12) / macOS 26.7 (25G229), after turning the built-in display off, the
request to turn it back on (`SLSConfigureDisplayEnabled(config, 1, true)` ->
`CGCompleteDisplayConfiguration`) failed with `1001` (kCGErrorIllegalArgument), and only a reboot
brought it back. This happened twice before the restore procedure below existed.

## Root cause

Determined from WindowServer's logs and a SkyLight disassembly:

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

## The restore procedure

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
  A full system sleep/wake is subtler: every real display drops out of the online list (leaving only
  a headless fallback) and the external comes back a moment after the wake notifications, which used
  to look like a new connection and auto-turned the built-in display off after every wake. The
  controller now records which external displays were connected when going to sleep and treats those
  same displays returning within 60 seconds of waking as resuming, not connecting (confirmed from a
  real `power:` log).
  Likewise, a built-in panel that this app did *not* disable can be missing from the online list
  around a wake after the external was unplugged during sleep (the Mac may go straight back to
  sleep). While sleeping, and for 8 seconds after a wake, that alone doesn't start a restore: doing
  so power-cycled the displays and woke a Mac that was trying to sleep, with a ~13s "restoring"
  overlay. A panel the app did disable, and the manual force-restore, are never delayed.
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

## Real-hardware verification (2026-09-23, Mac15,12 / macOS 26.7)

| Scenario | Command | Result |
|---|---|---|
| Restore to ON with the external still connected | `--verify-restore --confirm-reboot-risk` | 1001 four times -> one power cycle -> restored 16.5s after the request |
| Restore after unplugging the external while OFF | `--verify-restore --confirm-reboot-risk --after-unplug` | detected zero screens -> 1001 three times -> one power cycle -> restored about 10s after the unplug (measured before the 3-second grace period was added) |

## Why OFF is gated per host

The procedure above was only ever confirmed on the one machine above. Shipping `isDisableAllowed`
as a flat `true` would apply that same, unverified-elsewhere procedure to every Mac model and macOS
build the app runs on, risking the same "stuck black screen until reboot" accident for someone
whose hardware behaves differently.

Instead, `PrivateDisplayAPI.isDisableAllowed` (see `HostVerification` in
[PrivateDisplayAPI.swift](../Sources/AutoBlackout/PrivateDisplayAPI.swift)) is `true` only when the
current `(hw.model, kern.osversion build)` pair is either:

- in `HostVerification.shippedAllowlist`, a short list of combinations the project has confirmed
  on real hardware (currently just `Mac15,12` / `25G229`), or
- recorded locally (in `UserDefaults`) as verified on this exact machine, which happens
  automatically the first time `--verify-restore` succeeds on it.

On every other combination, the OFF feature stays disabled — the menu item is grayed out and the
disable API is never called — until the machine it's running on is verified. A macOS update changes
the build string, so a listed model needs re-verifying after every update too.

## Verifying the restore procedure on your Mac

```bash
.build/release/AutoBlackout --verify-restore --confirm-reboot-risk
```

This disables the built-in display once and checks whether the restore procedure above brings it
back. **If it doesn't come back, a reboot is required** — only run this with an external display and
power connected, the lid open, and you watching. On success, this exact Mac model + macOS build is
remembered as verified, and the OFF feature becomes available.

After a macOS update, the menu shows "macOS was updated — re-verify to enable OFF…" (and
`--diagnose` reports it) until you do. Re-run this after every macOS update, on any machine, verified or not — a build change means the
WindowServer behavior underneath hasn't been re-checked on it, so the app requires it to be
re-verified again.

Add `--after-unplug` to instead verify the restore that happens when the external display is
unplugged while OFF, rather than requesting a restore yourself:

```bash
.build/release/AutoBlackout --verify-restore --confirm-reboot-risk --after-unplug
```

## If something goes wrong

- Don't force-quit the app (`kill -9`, or Force Quit from Activity Monitor) while the built-in
  display is off — that kills the process that would otherwise send the restore request. If you did
  force-quit it, relaunch the app or run `--restore` (it detects a still-disabled panel at launch and
  restores it):

  ```bash
  .build/release/AutoBlackout --restore
  # or, if installed to /Applications:
  /Applications/AutoBlackout.app/Contents/MacOS/AutoBlackout --restore
  ```

- If the screen stays black and doesn't come back, close the lid and reopen it after a few seconds
  (the app, or `--restore`, will pick up from there if either is running).
- Sleep/wake: every sleep and wake notification is logged as a `power:` line with the panel state
  (`grep 'power:' ~/Library/Logs/AutoBlackout/recovery.log`). If the built-in display comes back on
  after waking, attach those lines to an issue.
- Logs: `~/Library/Logs/AutoBlackout/recovery.log` (also written to the os_log subsystem
  `io.github.yutsuki3.AutoBlackout`).
