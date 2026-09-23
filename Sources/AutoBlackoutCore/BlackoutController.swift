import CoreGraphics
import Foundation

/// 内蔵ディスプレイのON/OFFを決める状態機械。
///
/// 最優先ルール: **使える外部ディスプレイが無いのに内蔵ディスプレイが無効、という状態を放置しない。**
///
/// - 状態はメモリ上のフラグではなく、毎回 `DisplaySystem.snapshot()` の実測値から判断する
///   （前回の事故では「OFFのつもり」のフラグとIDを失ったまま復帰できなくなった）。
/// - 内蔵ディスプレイのIDは無効化するとオンライン一覧から消えるため、
///   `managedDisplay`（自分が無効化したID）と `store.lastKnownBuiltInID`（永続化キャッシュ）で保持する。
/// - APIが成功を返しても実際に適用されないことがあるので、`verifyDelay` 後に実測で検証する。
///   復帰が確認できるまで `evaluate` のたびに再試行し続ける。
/// - `evaluate` は接続変更コールバック・1秒ポーリング・起動時のすべてから呼ばれる、唯一の是正ループ。
public final class BlackoutController {
    public enum PanelStatus: Equatable {
        case apiUnavailable
        case notFound
        case on
        case off
        case restoring
    }

    public var isAutoModeEnabled = true

    /// 状態が変化した可能性があるたびにUI側へ通知する。
    public var onStateChange: (() -> Void)?

    public private(set) var managedDisplay: CGDirectDisplayID? {
        didSet { store.managedDisplayID = managedDisplay }
    }

    public private(set) var restorePending = false
    public private(set) var isChanging = false

    private let system: DisplaySystem
    private let store: DisplayStateStore
    private let scheduler: Scheduler
    private let logger: EventLogger
    private let verifyDelay: TimeInterval

    /// 無効化した時点で使えていた外部ディスプレイ。これが全部消えたら、
    /// 後から現れた別のディスプレイ（仮想ディスプレイ等）があっても復帰させる。
    private var externalsAtDisable: Set<CGDirectDisplayID>?
    /// 自動OFFは「外部ゼロ → 外部あり」の変化時だけ行う（手動でONに戻した直後に即OFFにしないため）。
    private var previousHadExternal: Bool?
    private var restoreAttempts = 0
    private var lastLoggedState: String?
    private var loggedPanelUnknown = false

    public init(
        system: DisplaySystem,
        store: DisplayStateStore,
        scheduler: Scheduler,
        logger: EventLogger,
        verifyDelay: TimeInterval = 1.0
    ) {
        self.system = system
        self.store = store
        self.scheduler = scheduler
        self.logger = logger
        self.verifyDelay = verifyDelay
        self.managedDisplay = store.managedDisplayID
    }

    public var isAPIAvailable: Bool { system.isToggleAvailable }
    public var isDisableSupported: Bool { system.isDisableSupported }

    // MARK: - 状態の参照

    /// 内蔵パネルのID。無効化中でも見失わないよう、次の優先順で解決する:
    /// 1. 自分が無効化したID  2. オンライン一覧の内蔵  3. 永続化キャッシュ  4. SLSGetDisplayList の内蔵
    public func builtInPanelID(in snapshot: DisplaySnapshot? = nil) -> CGDirectDisplayID? {
        let snapshot = snapshot ?? system.snapshot()
        if let managedDisplay { return managedDisplay }
        if let online = DisplayLogic.onlineBuiltIn(in: snapshot) {
            if store.lastKnownBuiltInID != online { store.lastKnownBuiltInID = online }
            return online
        }
        return store.lastKnownBuiltInID ?? DisplayLogic.anyBuiltIn(in: snapshot)
    }

    public var panelStatus: PanelStatus {
        guard isAPIAvailable else { return .apiUnavailable }
        let snapshot = system.snapshot()
        guard let panel = builtInPanelID(in: snapshot) else { return .notFound }
        if restorePending { return .restoring }
        return DisplayLogic.isPanelEnabled(panel, in: snapshot) ? .on : .off
    }

    public var isBuiltInDisplayOff: Bool {
        let status = panelStatus
        return status == .off || status == .restoring
    }

    public var hasUsableExternalDisplay: Bool {
        !DisplayLogic.usableExternals(in: system.snapshot()).isEmpty
    }

    // MARK: - 入口

    /// 起動時の自己修復。前回のプロセスが内蔵を無効化したまま落ちていても、ここで検知して復帰させる。
    public func launch() {
        let snapshot = system.snapshot()
        let panel = builtInPanelID(in: snapshot)
        logger.log("launch: api=\(isAPIAvailable) persistedManaged=\(describe(managedDisplay)) " + describe(snapshot))

        if managedDisplay == nil, let panel,
           !snapshot.online.contains(where: { $0.id == panel }) {
            // 一覧から消えている = 何者かに無効化されている。終了時に確実に戻すため自分の管理下に置く。
            logger.log("launch: panel \(panel) is missing from online list; adopting it as managed")
            managedDisplay = panel
        }
        previousHadExternal = !DisplayLogic.usableExternals(in: snapshot).isEmpty
        evaluate(reason: "launch")
    }

    /// 現状を実測し、必要なら復帰（または自動OFF）を行う。何度呼んでも安全。
    public func evaluate(reason: String) {
        let snapshot = system.snapshot()
        let panel = builtInPanelID(in: snapshot)
        let usable = DisplayLogic.usableExternals(in: snapshot)
        let hasExternal = externalsAtDisable.map { !usable.isDisjoint(with: $0) } ?? !usable.isEmpty
        let justConnected = previousHadExternal == false && !usable.isEmpty
        previousHadExternal = !usable.isEmpty

        logStateIfChanged(reason: reason, snapshot: snapshot, panel: panel)

        guard !isChanging else { return }
        guard isAPIAvailable, let panel else {
            if !loggedPanelUnknown {
                // パネルが見つからない間は何もできない。痕跡だけは必ず残す。
                logger.log("cannot act (\(reason)): api=\(isAPIAvailable) panel=nil")
                loggedPanelUnknown = true
            }
            onStateChange?()
            return
        }
        loggedPanelUnknown = false

        let enabled = DisplayLogic.isPanelEnabled(panel, in: snapshot)

        if managedDisplay != nil, !hasExternal, !restorePending {
            logger.log("recovery required (\(reason)): no usable external display remains; usable=\(sorted(usable)) atDisable=\(sorted(externalsAtDisable))")
            restorePending = true
        }

        if restorePending || (!enabled && !hasExternal) {
            attemptRestore(panel, reason: reason)
            return
        }

        if enabled, managedDisplay != nil {
            // 他要因で内蔵が既に有効になっている。管理状態を解除する。
            logger.log("panel \(panel) observed enabled while managed; clearing managed state")
            clearManagedState()
        }

        if isAutoModeEnabled, justConnected, enabled {
            logger.log("auto: external display connected \(sorted(usable))")
            disable(panel, usable: usable, trigger: "auto")
            return
        }

        onStateChange?()
    }

    public func toggleManually() {
        if isBuiltInDisplayOff {
            requestRestore(trigger: "manual")
        } else {
            requestDisable(trigger: "manual")
        }
    }

    /// 手動の「OFFにする」。外部ディスプレイが無い場合は拒否する。
    public func requestDisable(trigger: String) {
        let snapshot = system.snapshot()
        guard !isChanging, !restorePending, isAPIAvailable, let panel = builtInPanelID(in: snapshot) else {
            logger.log("\(trigger) off refused: changing=\(isChanging) pending=\(restorePending) api=\(isAPIAvailable)")
            return
        }
        guard DisplayLogic.isPanelEnabled(panel, in: snapshot) else { return }
        disable(panel, usable: DisplayLogic.usableExternals(in: snapshot), trigger: trigger)
    }

    /// 手動の「ONに戻す」。一覧上は既にONに見えても、必ず有効化要求を送る。
    public func requestRestore(trigger: String) {
        logger.log("\(trigger) restore requested")
        restorePending = true
        evaluate(reason: trigger)
    }

    /// 終了直前に同期的に呼ぶ。自分が無効化したパネルが残っていれば戻す。
    /// SIGKILL等ではここは呼ばれないので、次回起動時の `launch()` と永続化された managedDisplay が保険になる。
    public func prepareForTermination() {
        let snapshot = system.snapshot()
        logger.log("terminate: managed=\(describe(managedDisplay)) " + describe(snapshot))
        guard let panel = managedDisplay ?? builtInPanelID(in: snapshot),
              managedDisplay != nil || !DisplayLogic.isPanelEnabled(panel, in: snapshot)
        else { return }
        let ok = system.setEnabled(true, for: panel)
        logger.log("terminate: restore panel=\(panel) apiResult=\(ok)\(errorSuffix(ok))")
        // 検証はできないので managedDisplay（永続化）は残す。次回起動時に有効と確認できれば解除される。
    }

    // MARK: - 実際の切り替え

    private func disable(_ panel: CGDirectDisplayID, usable: Set<CGDirectDisplayID>, trigger: String) {
        guard system.isDisableSupported else {
            logger.log("\(trigger) off refused: disabling is not supported (cannot guarantee restore)")
            onStateChange?()
            return
        }
        guard !usable.isEmpty else {
            logger.log("\(trigger) off refused: no usable external display")
            onStateChange?()
            return
        }
        // API呼び出し前に永続化しておく。直後にクラッシュしても次回起動時に復帰できる。
        externalsAtDisable = usable
        managedDisplay = panel
        isChanging = true
        let ok = system.setEnabled(false, for: panel)
        logger.log("\(trigger) off: panel=\(panel) apiResult=\(ok)\(errorSuffix(ok)) externals=\(sorted(usable))")
        onStateChange?()

        scheduler.schedule(after: verifyDelay) { [weak self] in
            self?.verifyDisable(panel, trigger: trigger)
        }
    }

    private func verifyDisable(_ panel: CGDirectDisplayID, trigger: String) {
        isChanging = false
        let snapshot = system.snapshot()
        if DisplayLogic.isPanelEnabled(panel, in: snapshot) {
            logger.log("\(trigger) off not applied: panel \(panel) is still enabled")
            clearManagedState()
        } else {
            logger.log("\(trigger) off verified: panel \(panel) is disabled")
        }
        // 検証中に外部が外れていた場合などは、ここで即座に是正される。
        evaluate(reason: "verify-off")
    }

    private func attemptRestore(_ panel: CGDirectDisplayID, reason: String) {
        restorePending = true
        isChanging = true
        restoreAttempts += 1
        let ok = system.setEnabled(true, for: panel)
        if restoreAttempts <= 5 || restoreAttempts % 30 == 0 {
            logger.log("restore attempt #\(restoreAttempts) (\(reason)): panel=\(panel) apiResult=\(ok)\(errorSuffix(ok))")
        }
        onStateChange?()

        scheduler.schedule(after: verifyDelay) { [weak self] in
            self?.verifyRestore(panel)
        }
    }

    private func verifyRestore(_ panel: CGDirectDisplayID) {
        isChanging = false
        let snapshot = system.snapshot()
        if DisplayLogic.isPanelEnabled(panel, in: snapshot) {
            logger.log("restore confirmed: panel \(panel) after \(restoreAttempts) attempt(s)")
            clearManagedState()
            onStateChange?()
        } else {
            // 成功を返しても適用されないことがある。確認できるまで再試行を続ける。
            if restoreAttempts <= 5 || restoreAttempts % 30 == 0 {
                logger.log("restore unconfirmed: panel \(panel); retrying")
            }
            evaluate(reason: "verify-restore")
        }
    }

    private func clearManagedState() {
        managedDisplay = nil
        externalsAtDisable = nil
        restorePending = false
        restoreAttempts = 0
    }

    // MARK: - ログ

    private func logStateIfChanged(reason: String, snapshot: DisplaySnapshot, panel: CGDirectDisplayID?) {
        let state = "panel=\(describe(panel)) managed=\(describe(managedDisplay)) pending=\(restorePending) "
            + "changing=\(isChanging) auto=\(isAutoModeEnabled) " + describe(snapshot)
        guard state != lastLoggedState else { return }
        lastLoggedState = state
        logger.log("state (\(reason)): " + state)
    }

    private func errorSuffix(_ ok: Bool) -> String {
        ok ? "" : " error=\(system.lastErrorDescription ?? "unknown")"
    }

    private func describe(_ id: CGDirectDisplayID?) -> String {
        id.map { String($0) } ?? "nil"
    }

    private func describe(_ snapshot: DisplaySnapshot) -> String {
        func row(_ d: DisplayInfo) -> String {
            "\(d.id)[b=\(d.isBuiltin ? 1 : 0) on=\(d.isOnline ? 1 : 0) act=\(d.isActive ? 1 : 0) "
                + "slp=\(d.isAsleep ? 1 : 0) mir=\(d.isInMirrorSet ? 1 : 0)"
                + (d.isHeadlessFallback ? " fallback" : "") + "]"
        }
        let all = snapshot.all.map { $0.map(\.id).map(String.init).joined(separator: ",") } ?? "n/a"
        return "online={\(snapshot.online.map(row).joined(separator: " "))} all={\(all)}"
    }

    private func sorted(_ ids: Set<CGDirectDisplayID>?) -> [CGDirectDisplayID] {
        (ids ?? []).sorted()
    }
}
