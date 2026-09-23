import CoreGraphics

/// スナップショットから判定を行う純粋関数群。副作用なし。
public enum DisplayLogic {
    /// オンライン一覧に居る（=実在が確かな）内蔵ディスプレイ。
    public static func onlineBuiltIn(in snapshot: DisplaySnapshot) -> CGDirectDisplayID? {
        snapshot.online.first { $0.isBuiltin && !$0.isHeadlessFallback }?.id
    }

    /// 無効化中のディスプレイも含む一覧から見つけた内蔵ディスプレイ（信頼度は低め）。
    public static func anyBuiltIn(in snapshot: DisplaySnapshot) -> CGDirectDisplayID? {
        snapshot.all?.first { $0.isBuiltin && !$0.isHeadlessFallback }?.id
    }

    /// 実際に映像を出せる外部ディスプレイ。
    public static func usableExternals(in snapshot: DisplaySnapshot) -> Set<CGDirectDisplayID> {
        Set(snapshot.online.filter {
            !$0.isBuiltin && !$0.isHeadlessFallback && $0.isOnline && !$0.isAsleep
                && ($0.isActive || $0.isInMirrorSet)
        }.map(\.id))
    }

    /// 内蔵パネルが「確実に」有効か。オンライン一覧に居ないIDはフラグが信用できないので無効扱い。
    public static func isPanelEnabled(_ id: CGDirectDisplayID, in snapshot: DisplaySnapshot) -> Bool {
        guard let info = snapshot.online.first(where: { $0.id == id }) else { return false }
        return !info.isHeadlessFallback && info.isOnline && !info.isAsleep
            && (info.isActive || info.isInMirrorSet)
    }
}
