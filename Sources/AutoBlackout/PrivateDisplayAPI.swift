import CoreGraphics
import Foundation

/// 内蔵ディスプレイの有効/無効を切り替える非公開API (`SLSConfigureDisplayEnabled` /
/// `CGSConfigureDisplayEnabled`) を、実行時に `dlsym` で解決して呼び出すラッパー。
///
/// - SDKに含まれないシンボルなので、コンパイル時ではなく実行時に存在確認を行う。
/// - シンボルが見つからない場合は `isAvailable == false` となり、
///   呼び出し側はUIをグレーアウトするなどして安全側に倒す。
enum PrivateDisplayAPI {
    private typealias ConfigureEnabledFn = @convention(c) (
        CGDisplayConfigRef?, CGDirectDisplayID, Bool
    ) -> CGError

    private typealias GetDisplayListFn = @convention(c) (
        UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?
    ) -> CGError

    private static let configureEnabled: ConfigureEnabledFn? = resolveConfigureEnabled()
    private static let getDisplayList: GetDisplayListFn? = resolveGetDisplayList()

    /// このMac・このmacOSバージョンで切り替えAPIが利用可能かどうか。
    static var isAvailable: Bool { configureEnabled != nil }

    /// 無効化（OFF）を許可するか。
    ///
    /// MacBook Air M3 (Mac15,12) / macOS 26.7 (25G229) で、無効化後の有効化が
    /// `CGCompleteDisplayConfiguration` で kCGErrorIllegalArgument (1001) になり、再起動でしか戻らない事故が2回あった。
    ///
    /// 原因（ログと逆アセンブルで確認）:
    /// - エントリーモデルの M3 は内蔵パネルの接続を外部ディスプレイ用に転用できる設計で、
    ///   無効化するとパネルがハードウェア的に切断扱いになる（IOMFB "Display 1 hot plug 0"）。
    /// - その状態では WindowServer (`configuration_engine::config_via_client_api`) が有効化要求を
    ///   事前チェックで弾き、1001 を返す。確定オプション（`.permanently` 等）や同じトランザクションに
    ///   他の変更を含めても、このチェックの結果は変わらない。
    /// - ディスプレイのスリープ→復帰や蓋の開閉でパネルが再通電（"hot plug 1"）した後なら、有効化要求は通る。
    ///
    /// `BlackoutController` の復帰手順（再試行 → 再通電 → 蓋の開閉の案内）で戻ることを 2026-09-23 に実機で確認したので許可する:
    /// - 外部接続のままONに戻す: 再通電1回で、要求から16.5秒で復帰。
    /// - OFFのまま外部ディスプレイを抜く: 画面が1枚も無い状態から、再通電1回で、抜いてから約10秒で復帰。
    /// macOS の更新後は `AutoBlackout --verify-restore --confirm-reboot-risk [--after-unplug]` で再確認すること。
    static let isDisableAllowed = true

    /// 直近の失敗の内容（どの段階で何のエラーか）。成功時は nil。
    private(set) static var lastError: String?

    /// 指定したディスプレイの有効/無効を切り替える。
    /// - Parameter overrideDisableBlock: `--verify-restore` 専用。`isDisableAllowed` が false でも無効化を通す。
    /// - Returns: 成功したかどうか。失敗の詳細は `lastError`。
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

        // .forAppOnly の「プロセス終了で元に戻る」は、上記の実機確認で効かなかった。これには依存しない。
        let complete = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard complete == .success else {
            lastError = "CGCompleteDisplayConfiguration=\(complete.rawValue)"
            return false
        }
        return true
    }

    /// `SLSGetDisplayList`: 無効化中のディスプレイも含む一覧（読み取り専用）。取得できなければ nil。
    static func allDisplayIDs() -> [CGDirectDisplayID]? {
        guard let getDisplayList else { return nil }
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success else { return nil }
        // count取得とlist取得の間に接続が増えても溢れないよう余裕を持たせる。
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
        // 1. SkyLight.framework の SLSConfigureDisplayEnabled を優先
        if let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "SLSConfigureDisplayEnabled") {
            return unsafeBitCast(symbol, to: ConfigureEnabledFn.self)
        }

        // 2. フォールバック: CoreGraphics経由で再エクスポートされている CGSConfigureDisplayEnabled
        if let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") {
            return unsafeBitCast(symbol, to: ConfigureEnabledFn.self)
        }

        return nil
    }
}
