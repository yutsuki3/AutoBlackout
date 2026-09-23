import Foundation

/// A specific Mac model + macOS build combination.
public struct HostKey: Hashable, CustomStringConvertible {
    public let model: String
    public let osBuild: String

    public init(model: String, osBuild: String) {
        self.model = model
        self.osBuild = osBuild
    }

    public var description: String { "\(model)/\(osBuild)" }

    /// `hw.model` / `kern.osversion` come back as "unknown" when the sysctl fails; such a host can
    /// never be identified, so it must never be treated as verified.
    public var isIdentifiable: Bool { model != "unknown" && osBuild != "unknown" }
}

/// Decides whether the current (Mac model, macOS build) is known to restore the built-in display
/// after disabling it. Everything it depends on (the host, the shipped allowlist, the storage) is
/// injected so it can be tested without touching the real machine.
public final class HostVerifier {
    public enum Source: Equatable {
        case shippedAllowlist
        case localVerification
        case unverified
    }

    static let verifiedHostDefaultsKey = "verifiedRestoreHost"

    private let current: HostKey
    private let shippedAllowlist: Set<HostKey>
    private let defaults: UserDefaults

    public init(current: HostKey, shippedAllowlist: Set<HostKey>, defaults: UserDefaults) {
        self.current = current
        self.shippedAllowlist = shippedAllowlist
        self.defaults = defaults
    }

    public var source: Source {
        guard current.isIdentifiable else { return .unverified }
        if shippedAllowlist.contains(current) { return .shippedAllowlist }
        if defaults.string(forKey: Self.verifiedHostDefaultsKey) == current.description {
            return .localVerification
        }
        return .unverified
    }

    public var isVerified: Bool { source != .unverified }

    /// Remembers that this exact machine + macOS build restored correctly. Ignored on a host that
    /// can't be identified. Replaces any earlier local verification (a macOS update changes the
    /// build, so the previous one no longer applies).
    public func markVerified() {
        guard current.isIdentifiable else { return }
        defaults.set(current.description, forKey: Self.verifiedHostDefaultsKey)
    }
}
