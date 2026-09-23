# Security and safety policy

## What this app does

AutoBlackout calls private, undocumented macOS APIs (`SLSConfigureDisplayEnabled` /
`CGSConfigureDisplayEnabled`) to disable the built-in display. On some Mac models and macOS builds a
disabled panel can fail to come back until a reboot. To limit that risk, the OFF feature is only
enabled on host (Mac model + macOS build) combinations that have been verified. See
[docs/HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md).

The app makes no network connections, needs no special permissions, and runs no privileged helper.
It only invokes `/usr/bin/pmset displaysleepnow` as part of its restore procedure.

## If your display is stuck off

See "Emergency recovery" in the [README](README.md): run `AutoBlackout --restore`, or close the lid,
wait about 5 seconds, and reopen it.

## Reporting a vulnerability or a safety problem

Please use GitHub's private vulnerability reporting ("Security" tab -> "Report a vulnerability") for
anything security-sensitive. For a display that failed to restore, open a normal bug report and
include the output of `AutoBlackout --diagnose`.

## Supported versions

Only the latest release is supported.
