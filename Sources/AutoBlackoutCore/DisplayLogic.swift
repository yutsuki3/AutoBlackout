import CoreGraphics

/// Pure functions that make decisions from a snapshot. No side effects.
public enum DisplayLogic {
    /// The built-in display on the online list (i.e. confirmed to actually exist).
    public static func onlineBuiltIn(in snapshot: DisplaySnapshot) -> CGDirectDisplayID? {
        snapshot.online.first { $0.isBuiltin && !$0.isHeadlessFallback }?.id
    }

    /// The built-in display found in the full list, including disabled displays (less reliable).
    public static func anyBuiltIn(in snapshot: DisplaySnapshot) -> CGDirectDisplayID? {
        snapshot.all?.first { $0.isBuiltin && !$0.isHeadlessFallback }?.id
    }

    /// Connected external displays, including ones that are asleep. Used to decide whether one was
    /// "newly connected".
    public static func presentExternals(in snapshot: DisplaySnapshot) -> Set<CGDirectDisplayID> {
        Set(snapshot.online.filter { !$0.isBuiltin && !$0.isHeadlessFallback && $0.isOnline }.map(\.id))
    }

    /// External displays that can actually show something right now.
    public static func usableExternals(in snapshot: DisplaySnapshot) -> Set<CGDirectDisplayID> {
        Set(snapshot.online.filter {
            !$0.isBuiltin && !$0.isHeadlessFallback && $0.isOnline && !$0.isAsleep
                && ($0.isActive || $0.isInMirrorSet)
        }.map(\.id))
    }

    /// Whether the built-in panel is enabled (not disabled). A disabled panel disappears from the
    /// online list, so presence there is what's checked. A panel that's merely display-asleep still
    /// counts as enabled (otherwise every display sleep would be mistaken for "it got turned off").
    public static func isPanelEnabled(_ id: CGDirectDisplayID, in snapshot: DisplaySnapshot) -> Bool {
        guard let info = snapshot.online.first(where: { $0.id == id }) else { return false }
        return !info.isHeadlessFallback && info.isOnline
    }
}
