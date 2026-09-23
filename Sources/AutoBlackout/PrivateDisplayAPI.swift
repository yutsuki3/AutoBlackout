import AutoBlackoutCore
import CoreGraphics
import Foundation

/// A wrapper that resolves the private APIs used to enable/disable the built-in display
/// (`SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled`) at runtime via `dlsym`.
///
/// - These symbols are not part of the SDK, so their existence is checked at runtime rather
///   than at compile time.
/// - If the symbol can't be found, `isAvailable` is `false` and callers should fail safe
///   (e.g. gray out the UI).
enum PrivateDisplayAPI {
    private typealias ConfigureEnabledFn = @convention(c) (
        CGDisplayConfigRef?, CGDirectDisplayID, Bool
    ) -> CGError

    private typealias GetDisplayListFn = @convention(c) (
        UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?
    ) -> CGError

    private static let configureEnabled: ConfigureEnabledFn? = resolveConfigureEnabled()
    private static let getDisplayList: GetDisplayListFn? = resolveGetDisplayList()

    /// Whether the enable/disable API is available on this Mac and macOS version.
    static var isAvailable: Bool { configureEnabled != nil }

    /// Whether disabling (turning OFF) the built-in display is allowed.
    ///
    /// On a MacBook Air M3 (Mac15,12) / macOS 26.7 (25G229), re-enabling the built-in panel after
    /// disabling it failed with `CGCompleteDisplayConfiguration` returning kCGErrorIllegalArgument
    /// (1001), and only a reboot brought it back — twice.
    ///
    /// Root cause (determined from WindowServer logs and a SkyLight disassembly):
    /// - Entry-level M3 models repurpose the built-in panel's connection so the machine can drive
    ///   two external displays with the lid closed. As a side effect, disabling the panel makes it
    ///   look hardware-disconnected (IOMFB logs "Display 1 hot plug 0").
    /// - While in that state, WindowServer's `configuration_engine::config_via_client_api` rejects
    ///   the enable request in a precheck and returns 1001 (before the "client api - Enable display"
    ///   log line even appears). Changing the commit options (e.g. `.permanently`) or bundling other
    ///   changes into the same transaction doesn't change the outcome of that check.
    /// - Once the panel is re-powered ("hot plug 1") — by a display sleep/wake cycle or by closing
    ///   and reopening the lid — the enable request succeeds.
    ///
    /// `BlackoutController`'s restore procedure (retry -> power-cycle -> prompt to cycle the lid)
    /// was confirmed on real hardware to bring the display back on 2026-09-23:
    /// - Restoring with an external display still connected: one power cycle, restored 16.5s after
    ///   the request.
    /// - Restoring after unplugging the external display: starting from zero displays, one power
    ///   cycle, restored about 10s after the unplug.
    ///
    /// That verification was only ever run on the one machine above. To avoid the same "stuck black
    /// screen until reboot" accident on a Mac model or macOS build nobody has actually tested, this
    /// is gated per host: it's `true` only for combinations that either ship in `HostVerification`'s
    /// allowlist, or that this exact machine has locally confirmed by running
    /// `AutoBlackout --verify-restore --confirm-reboot-risk [--after-unplug]` successfully (see
    /// `HostVerification.markCurrentHostVerified()`). On any other Mac/macOS combination, the
    /// disable feature stays off — `LiveDisplaySystem.isDisableSupported` grays out the menu — until
    /// the user opts in by running that verification themselves.
    static var isDisableAllowed: Bool { HostVerification.isCurrentHostVerified }

    /// Details of the most recent failure (which stage, what error). `nil` on success.
    private(set) static var lastError: String?

    /// Enables or disables the given display.
    /// - Parameter overrideDisableBlock: for `--verify-restore` only. Lets a disable request
    ///   through even when `isDisableAllowed` is false, so the restore path can be tested on an
    ///   unverified host in the first place.
    /// - Returns: whether the API call reported success. `lastError` has the failure detail.
    @discardableResult
    static func setEnabled(
        _ enabled: Bool,
        for displayID: CGDirectDisplayID,
        overrideDisableBlock: Bool = false
    ) -> Bool {
        lastError = nil
        guard enabled || isDisableAllowed || overrideDisableBlock else {
            lastError = "disable is blocked (isDisableAllowed=false)"
            return false
        }
        guard let configureEnabled else {
            lastError = "private API unavailable"
            return false
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            lastError = "CGBeginDisplayConfiguration=\(begin.rawValue)"
            return false
        }

        let result = configureEnabled(config, displayID, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            lastError = "ConfigureDisplayEnabled=\(result.rawValue)"
            return false
        }

        // Real-hardware testing showed `.forAppOnly`'s "reverts when the process exits" guarantee
        // doesn't hold here, so nothing relies on it.
        let complete = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard complete == .success else {
            lastError = "CGCompleteDisplayConfiguration=\(complete.rawValue)"
            return false
        }
        return true
    }

    /// `SLSGetDisplayList`: a read-only list that also includes disabled displays. `nil` if it
    /// couldn't be resolved.
    static func allDisplayIDs() -> [CGDirectDisplayID]? {
        guard let getDisplayList else { return nil }
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success else { return nil }
        // Leave headroom between the count and list calls in case a display connects in between.
        let capacity = max(count + 8, 32)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard getDisplayList(capacity, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(min(count, capacity))))
    }

    private static func resolveGetDisplayList() -> GetDisplayListFn? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "SLSGetDisplayList") else { return nil }
        return unsafeBitCast(symbol, to: GetDisplayListFn.self)
    }

    private static func resolveConfigureEnabled() -> ConfigureEnabledFn? {
        // 1. Prefer SkyLight.framework's SLSConfigureDisplayEnabled.
        if let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "SLSConfigureDisplayEnabled") {
            return unsafeBitCast(symbol, to: ConfigureEnabledFn.self)
        }

        // 2. Fallback: CGSConfigureDisplayEnabled, re-exported via CoreGraphics.
        if let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") {
            return unsafeBitCast(symbol, to: ConfigureEnabledFn.self)
        }

        return nil
    }
}

/// Tracks which exact (Mac model, macOS build) combinations are known to be able to restore the
/// built-in display after disabling it, so `PrivateDisplayAPI.isDisableAllowed` can fail safe on
/// everything else. See `PrivateDisplayAPI.isDisableAllowed` for why this exists. The decision logic
/// lives in `HostVerifier` (AutoBlackoutCore) so it can be unit-tested.
enum HostVerification {
    /// Combinations confirmed on real hardware by the project and shipped with the app. A macOS
    /// update changes the build string, so this needs re-confirming (`--verify-restore`) after
    /// every update even on a listed model.
    static let shippedAllowlist: Set<HostKey> = [
        HostKey(model: "Mac15,12", osBuild: "25G229"),
    ]

    static var current: HostKey { HostKey(model: HostInfo.model, osBuild: HostInfo.osBuild) }

    private static var verifier: HostVerifier {
        HostVerifier(
            current: current,
            shippedAllowlist: shippedAllowlist,
            defaults: UserDefaults(suiteName: "io.github.yutsuki3.AutoBlackout") ?? .standard
        )
    }

    static var isCurrentHostVerified: Bool { verifier.isVerified }

    /// Where the current host's verification comes from, for `--diagnose`.
    static var sourceDescription: String {
        switch verifier.source {
        case .shippedAllowlist: return "verified (shipped allowlist)"
        case .localVerification: return "verified (locally, via --verify-restore)"
        case .unverified: return "NOT verified (OFF feature disabled)"
        }
    }

    /// Called after `AutoBlackout --verify-restore --confirm-reboot-risk` completes successfully:
    /// remembers that this exact machine + macOS build has been confirmed to restore correctly, so
    /// the disable feature can be used on it going forward.
    static func markCurrentHostVerified() {
        verifier.markVerified()
    }
}
