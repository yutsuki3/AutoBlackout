/// A reason `--verify-restore` (or the in-app "Verify this Mac" menu item) refuses to start.
public enum RestoreVerificationProblem: Equatable, CaseIterable {
    case intelNotSupported
    case apiUnavailable
    case builtInPanelNotOnline
    case noUsableExternalDisplay
    case lidNotOpen
    case unconfirmedPreviousRestore

    /// Stable English text for logs (matches the wording `--verify-restore` has always logged).
    public var logDescription: String {
        switch self {
        case .intelNotSupported: return "Intel Macs are not supported"
        case .apiUnavailable: return "private API unavailable"
        case .builtInPanelNotOnline: return "built-in panel is not online"
        case .noUsableExternalDisplay: return "no usable external display"
        case .lidNotOpen: return "lid is not open (or unknown)"
        case .unconfirmedPreviousRestore: return "a previous restore is unconfirmed (managedDisplayID is set)"
        }
    }
}

/// Whether it's safe to start the restore-verification procedure right now (disabling the built-in
/// display once to test whether it comes back on its own). Pure: every real-world fact is a
/// parameter, so both `--verify-restore` (a fresh process) and the in-app "Verify this Mac" menu
/// item (reusing the running app's own controller) can share one answer without either touching
/// hardware from this layer.
public enum RestoreVerificationPreflight {
    public static func problems(
        isAppleSilicon: Bool,
        isAPIAvailable: Bool,
        snapshot: DisplaySnapshot,
        isLidClosed: Bool?,
        hasUnconfirmedManagedDisplay: Bool
    ) -> [RestoreVerificationProblem] {
        var problems: [RestoreVerificationProblem] = []
        if !isAppleSilicon { problems.append(.intelNotSupported) }
        if !isAPIAvailable { problems.append(.apiUnavailable) }
        if DisplayLogic.onlineBuiltIn(in: snapshot) == nil { problems.append(.builtInPanelNotOnline) }
        if DisplayLogic.usableExternals(in: snapshot).isEmpty { problems.append(.noUsableExternalDisplay) }
        if isLidClosed != false { problems.append(.lidNotOpen) }
        if hasUnconfirmedManagedDisplay { problems.append(.unconfirmedPreviousRestore) }
        return problems
    }
}
