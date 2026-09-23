import CoreGraphics
import Foundation

/// ある瞬間の1台のディスプレイの状態。CGの各種 `CGDisplayIs*` の結果を値として保持する。
public struct DisplayInfo: Equatable {
    public var id: CGDirectDisplayID
    public var isBuiltin: Bool
    public var isOnline: Bool
    public var isActive: Bool
    public var isAsleep: Bool
    public var isInMirrorSet: Bool
    public var vendor: UInt32
    public var model: UInt32

    public init(
        id: CGDirectDisplayID,
        isBuiltin: Bool,
        isOnline: Bool = true,
        isActive: Bool = true,
        isAsleep: Bool = false,
        isInMirrorSet: Bool = false,
        vendor: UInt32 = 0,
        model: UInt32 = 0
    ) {
        self.id = id
        self.isBuiltin = isBuiltin
        self.isOnline = isOnline
        self.isActive = isActive
        self.isAsleep = isAsleep
        self.isInMirrorSet = isInMirrorSet
        self.vendor = vendor
        self.model = model
    }

    /// 全ディスプレイが消えた時にWindowServerが作る仮想ディスプレイ (vendor 'unkn' / model 'virt')。
    /// 実際には何も映らないので「使える外部ディスプレイ」とみなしてはいけない。
    public var isHeadlessFallback: Bool {
        vendor == 0x756e_6b6e && model == 0x7669_7274
    }
}

/// ある瞬間のディスプレイ構成。
public struct DisplaySnapshot: Equatable {
    /// `CGGetOnlineDisplayList` の結果。無効化した内蔵ディスプレイはここから消えることがある。
    public var online: [DisplayInfo]
    /// `SLSGetDisplayList`（非公開、無効化中のディスプレイも含む）の結果。取得できなければ nil。
    /// 一覧に居ないIDの `CGDisplayIs*` は -1（=真）を返すことがあるので、あくまで補助情報。
    public var all: [DisplayInfo]?

    public init(online: [DisplayInfo], all: [DisplayInfo]? = nil) {
        self.online = online
        self.all = all
    }
}

/// 実際のディスプレイ操作の抽象。本番は CG + 非公開API、テストはモック。
public protocol DisplaySystem: AnyObject {
    /// 有効/無効を切り替える非公開APIが解決できているか。
    var isToggleAvailable: Bool { get }
    /// 無効化（OFF）してよいか。確実に元に戻せる保証が無い環境では false。
    var isDisableSupported: Bool { get }
    /// 直近の setEnabled の失敗内容（ログ用）。
    var lastErrorDescription: String? { get }
    func snapshot() -> DisplaySnapshot
    /// - Returns: APIが成功を返したか。**成功が返っても実際に適用されたとは限らない**。
    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool
}

/// プロセスを跨いで残す必要がある状態。アプリが落ちて再起動しても復帰できるようにするため。
public protocol DisplayStateStore: AnyObject {
    /// 最後にオンライン一覧で確認できた内蔵ディスプレイのID。
    var lastKnownBuiltInID: CGDirectDisplayID? { get set }
    /// このアプリが無効化し、まだ復帰を確認できていない内蔵ディスプレイのID。
    var managedDisplayID: CGDirectDisplayID? { get set }
}

/// 遅延実行の抽象。テストでは時間を進める操作を明示的に行う。
public protocol Scheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void)
}

public protocol EventLogger: AnyObject {
    func log(_ message: String)
}
