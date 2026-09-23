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

    private static let configureEnabled: ConfigureEnabledFn? = resolveConfigureEnabled()

    /// このMac・このmacOSバージョンで切り替えAPIが利用可能かどうか。
    static var isAvailable: Bool { configureEnabled != nil }

    /// 指定したディスプレイの有効/無効を切り替える。
    /// - Returns: 成功したかどうか。失敗時は呼び出し元でエラー表示すること。
    @discardableResult
    static func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        guard let configureEnabled else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return false
        }

        let result = configureEnabled(config, displayID, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        // .forAppOnly: このプロセスが終了すればmacOSが元の構成に自動で戻す安全弁。
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
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
