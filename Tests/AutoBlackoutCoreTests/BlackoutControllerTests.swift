import AutoBlackoutCore
import CoreGraphics
import XCTest

// MARK: - Fakes

/// 実機の振る舞いを模したディスプレイ。無効化したパネルはオンライン一覧から消える（バグ1の再現条件）。
final class FakeDisplaySystem: DisplaySystem {
    static let panel: CGDirectDisplayID = 1
    static let external: CGDirectDisplayID = 5

    var isToggleAvailable = true
    var isDisableSupported = true
    var lastErrorDescription: String?
    var panelEnabled = true
    var externals: Set<CGDirectDisplayID> = []
    /// 接続されたままスリープしている外部ディスプレイ（`externals` の部分集合）。
    var asleepExternals: Set<CGDirectDisplayID> = []
    /// SLSGetDisplayList が使えるか。
    var allListAvailable = false
    /// true の間、有効化要求は成功を返すが実際には適用されない（バグ3の再現条件）。
    var ignoreEnableRequests = false
    /// true の間、無効化要求は成功を返すが実際には適用されない。
    var ignoreDisableRequests = false
    /// true の間、有効化要求は 1001 で拒否される（M3 で無効化後にパネルが切断扱いになった状態）。
    /// `powerCycleDisplays()` か蓋の開閉（テストでは直接 false にする）で解除される。
    var panelUnpowered = false
    /// false なら、ディスプレイの再通電ではパネルが再通電しない（蓋の開閉が必要なケース）。
    var powerCycleRepowersPanel = true
    /// true なら、再通電の後も外部ディスプレイはしばらくスリープしたまま（内蔵より遅れて起きる）。
    var powerCycleLeavesExternalsAsleep = false
    var powerCycleCount = 0
    /// setEnabled が呼ばれた瞬間のフック。
    var onSetEnabled: ((Bool) -> Void)?
    var calls: [(enabled: Bool, id: CGDirectDisplayID)] = []

    func snapshot() -> DisplaySnapshot {
        var online: [DisplayInfo] = []
        if panelEnabled { online.append(DisplayInfo(id: Self.panel, isBuiltin: true)) }
        online += externals.sorted().map { id in
            let asleep = asleepExternals.contains(id)
            return DisplayInfo(id: id, isBuiltin: false, isActive: !asleep, isAsleep: asleep)
        }
        let all = allListAvailable
            ? [DisplayInfo(id: Self.panel, isBuiltin: true)] + externals.sorted().map { DisplayInfo(id: $0, isBuiltin: false) }
            : nil
        return DisplaySnapshot(online: online, all: all)
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        onSetEnabled?(enabled)
        calls.append((enabled, displayID))
        guard displayID == Self.panel else { return false }
        if enabled, panelUnpowered {
            lastErrorDescription = "CGCompleteDisplayConfiguration=1001"
            return false
        }
        if enabled, ignoreEnableRequests { return true }
        if !enabled, ignoreDisableRequests { return true }
        panelEnabled = enabled
        return true
    }

    func powerCycleDisplays() {
        powerCycleCount += 1
        if powerCycleRepowersPanel { panelUnpowered = false }
        if powerCycleLeavesExternalsAsleep { asleepExternals = externals }
    }
}

final class MemoryStore: DisplayStateStore {
    var lastKnownBuiltInID: CGDirectDisplayID?
    var managedDisplayID: CGDirectDisplayID?
}

final class ManualScheduler: Scheduler {
    private var pending: [() -> Void] = []
    var pendingCount: Int { pending.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        pending.append(work)
    }

    /// 予約済みの処理を1段だけ実行する（=1秒進める）。
    func advance() {
        let work = pending
        pending.removeAll()
        work.forEach { $0() }
    }
}

final class RecordingLogger: EventLogger {
    var lines: [String] = []
    func log(_ message: String) { lines.append(message) }
}

// MARK: - Tests

final class BlackoutControllerTests: XCTestCase {
    private var system: FakeDisplaySystem!
    private var store: MemoryStore!
    private var scheduler: ManualScheduler!
    private var logger: RecordingLogger!

    override func setUp() {
        system = FakeDisplaySystem()
        store = MemoryStore()
        scheduler = ManualScheduler()
        logger = RecordingLogger()
    }

    private func makeController() -> BlackoutController {
        BlackoutController(system: system, store: store, scheduler: scheduler, logger: logger)
    }

    private func connectExternalAndAutoDisable(_ c: BlackoutController) {
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
    }

    // バグ1: 無効化してオンライン一覧から消えても、IDを見失わずに復帰できる。
    func testUnplugAfterAutoDisableRestoresPanel() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = []
        c.evaluate(reason: "callback")
        XCTAssertEqual(system.calls.last?.enabled, true)
        XCTAssertEqual(system.calls.last?.id, FakeDisplaySystem.panel)
        scheduler.advance()

        XCTAssertTrue(system.panelEnabled)
        XCTAssertNil(c.managedDisplay)
        XCTAssertNil(store.managedDisplayID)
        XCTAssertFalse(c.restorePending)
    }

    func testPanelIDIsCachedWhileDisabled() {
        let c = makeController()
        c.launch()
        XCTAssertEqual(store.lastKnownBuiltInID, FakeDisplaySystem.panel)
        connectExternalAndAutoDisable(c)
        XCTAssertNil(DisplayLogic.onlineBuiltIn(in: system.snapshot()))
        XCTAssertEqual(c.builtInPanelID(), FakeDisplaySystem.panel)
    }

    // バグ2: 終了時に明示的に復元する。
    func testTerminationRestoresManagedPanel() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        c.prepareForTermination()
        XCTAssertTrue(system.panelEnabled)
    }

    func testTerminationDoesNothingWhenPanelIsOn() {
        let c = makeController()
        c.launch()
        c.prepareForTermination()
        XCTAssertTrue(system.calls.isEmpty)
    }

    // バグ3: APIが成功を返しても適用されない場合、確認できるまで再試行する。
    func testRestoreIsRetriedUntilVerified() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.ignoreEnableRequests = true
        system.externals = []
        c.evaluate(reason: "callback")
        scheduler.advance() // 検証 → 未適用 → 再試行
        scheduler.advance()
        let enableCalls = system.calls.filter(\.enabled).count
        XCTAssertGreaterThanOrEqual(enableCalls, 3)
        XCTAssertTrue(c.restorePending)
        XCTAssertEqual(c.panelStatus, .restoring)

        system.ignoreEnableRequests = false
        scheduler.advance() // 3回目の失敗 → 再通電（待ち時間に入る）
        scheduler.advance() // 待ち時間の後に有効化要求
        scheduler.advance() // 検証
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)
        XCTAssertNil(c.managedDisplay)
    }

    func testDisableThatDidNotApplyClearsManagedState() {
        system.ignoreDisableRequests = true
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertNil(c.managedDisplay)
        XCTAssertEqual(c.panelStatus, .on)
    }

    // 要望1: 前回プロセスが無効化したまま落ちた → 新プロセス起動時に復元する。
    func testLaunchSelfHealsFromPersistedState() {
        system.panelEnabled = false
        store.managedDisplayID = FakeDisplaySystem.panel

        let c = makeController()
        c.launch()
        XCTAssertEqual(system.calls.last?.enabled, true)
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
        XCTAssertNil(store.managedDisplayID)
    }

    func testLaunchSelfHealsUsingOnlyCachedID() {
        system.panelEnabled = false
        store.lastKnownBuiltInID = FakeDisplaySystem.panel

        let c = makeController()
        c.launch()
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testLaunchSelfHealsUsingAllDisplayListWhenNoCache() {
        system.panelEnabled = false
        system.allListAvailable = true

        let c = makeController()
        c.launch()
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testLaunchAdoptsDisabledPanelWhileExternalConnected() {
        system.panelEnabled = false
        system.externals = [FakeDisplaySystem.external]
        store.lastKnownBuiltInID = FakeDisplaySystem.panel

        let c = makeController()
        c.launch()
        XCTAssertFalse(system.panelEnabled, "外部がある間はOFFを維持してよい")
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)

        system.externals = []
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    // 要望2: コールバックが来なくてもポーリングで是正される。
    func testPollingRestoresWithoutCallback() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = [] // コールバックは来ない
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testUnplugDuringDisableVerificationRestores() {
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        XCTAssertFalse(system.panelEnabled)

        system.externals = [] // 検証待ちの間に外れる
        c.evaluate(reason: "callback") // isChanging 中なので何もしない
        scheduler.advance() // 検証 → 外部なし → 復元要求
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testReplacementDisplayDoesNotKeepPanelOff() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = [99] // 元のモニターが消え、別のIDが現れた
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    // 安全ルール: 外部ディスプレイが無い状態では手動でもOFFにしない。
    func testManualDisableRefusedWithoutExternal() {
        let c = makeController()
        c.launch()
        c.toggleManually()
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertTrue(system.panelEnabled)
    }

    func testManualRestoreIsNotUndoneByAutoMode() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        c.toggleManually() // ONに戻す
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)

        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertTrue(system.panelEnabled, "外部が繋がったままでも、手動ONは自動OFFで上書きされない")
    }

    func testAutoModeOffDoesNotDisable() {
        let c = makeController()
        c.isAutoModeEnabled = false
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testLaunchWithExternalDoesNotAutoDisable() {
        system.externals = [FakeDisplaySystem.external]
        let c = makeController()
        c.launch()
        XCTAssertTrue(system.calls.isEmpty)
    }

    // 実機で「OFFにすると再起動まで戻せない」と判明した環境では、自動でも手動でもOFFにしない。
    func testDisableIsNeverCalledWhenUnsupported() {
        system.isDisableSupported = false
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        c.toggleManually()
        scheduler.advance()
        XCTAssertFalse(system.calls.contains { !$0.enabled })
        XCTAssertTrue(system.panelEnabled)
        XCTAssertNil(c.managedDisplay)
    }

    // M3: 有効化要求が 1001 で拒否され続けたら、ディスプレイを再通電させてから再試行する。
    func testRejectedRestorePowerCyclesDisplaysThenSucceeds() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.panelUnpowered = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<(BlackoutController.failuresBeforeFirstPowerCycle - 1) { scheduler.advance() }
        XCTAssertEqual(system.powerCycleCount, 0, "直ちには画面を点滅させない")
        XCTAssertFalse(system.panelEnabled)

        scheduler.advance() // 3回目の失敗 → 再通電
        XCTAssertEqual(system.powerCycleCount, 1)
        let callsAtPowerCycle = system.calls.count
        XCTAssertTrue(c.isChanging, "再通電が落ち着くまで有効化要求を送らない")
        scheduler.advance() // 待ち時間の後に有効化要求
        XCTAssertEqual(system.calls.count, callsAtPowerCycle + 1)
        XCTAssertTrue(system.panelEnabled)
        scheduler.advance() // 検証
        XCTAssertFalse(c.restorePending)
        XCTAssertFalse(c.needsLidCycle)
        XCTAssertNil(store.managedDisplayID)
    }

    func testPowerCyclesAreCappedThenLidCycleRestores() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.panelUnpowered = true
        system.powerCycleRepowersPanel = false
        system.externals = []
        c.evaluate(reason: "callback")
        for _ in 0..<200 { scheduler.advance() }
        XCTAssertEqual(system.powerCycleCount, BlackoutController.maxPowerCycles, "点滅は上限回数まで")
        XCTAssertTrue(c.needsLidCycle)
        XCTAssertTrue(c.restorePending, "諦めずに再試行を続ける")
        XCTAssertEqual(c.panelStatus, .restoring)

        system.panelUnpowered = false // 蓋を閉じて開いた
        scheduler.advance() // 次の有効化要求が通る
        scheduler.advance() // 検証
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.needsLidCycle)
        XCTAssertFalse(c.restorePending)
    }

    func testNoPowerCycleWhenRestoreSucceedsImmediately() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.externals = []
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
        XCTAssertEqual(system.powerCycleCount, 0)
    }

    func testPowerCycleCounterResetsForNextRestore() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)
        system.panelUnpowered = true
        system.powerCycleRepowersPanel = false
        c.requestRestore(trigger: "manual")
        for _ in 0..<200 { scheduler.advance() }
        system.panelUnpowered = false
        scheduler.advance()
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)

        // 2回目のOFF→復帰でも、再び再通電が使える。
        system.externals = []
        c.evaluate(reason: "poll")
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled)
        system.panelUnpowered = true
        system.powerCycleRepowersPanel = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<6 { scheduler.advance() }
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)
        XCTAssertEqual(system.powerCycleCount, BlackoutController.maxPowerCycles + 1)
    }

    // アイドルで画面全体がスリープしても内蔵を戻さず、起きたときにも再OFFしない（再通電で画面を起こさないため）。
    func testIdleDisplaySleepKeepsPanelOffWithoutRedisable() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)
        let callsBefore = system.calls.count

        c.displaysAsleep = true
        system.asleepExternals = [FakeDisplaySystem.external]
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertEqual(system.calls.count, callsBefore, "アイドルスリープでは内蔵を戻さない")
        XCTAssertEqual(system.powerCycleCount, 0)

        system.asleepExternals = []
        c.displaysAsleep = false
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertEqual(system.calls.count, callsBefore, "復帰を新しい接続とみなして再OFFしない")
        XCTAssertFalse(system.panelEnabled)
        XCTAssertEqual(c.managedDisplay, FakeDisplaySystem.panel)
    }

    // 画面は起きているのに外部だけがスリープした（モニターの電源ボタン等）→ 内蔵を戻す。
    func testExternalAsleepWhileScreensAwakeRestores() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.asleepExternals = [FakeDisplaySystem.external]
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    func testMissedScreenWakeNotificationIsCorrectedByAwakeExternal() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)
        c.displaysAsleep = true
        c.evaluate(reason: "poll")
        XCTAssertFalse(c.displaysAsleep, "起きている外部が見えたらスリープ扱いを解く")

        system.asleepExternals = [FakeDisplaySystem.external]
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertTrue(system.panelEnabled)
    }

    // 再通電で内蔵が先に戻り、外部が遅れて起きても、戻った直後に自動OFFしない。
    func testNoAutoDisableWhenExternalWakesAfterPowerCycleRestore() {
        let c = makeController()
        c.launch()
        connectExternalAndAutoDisable(c)

        system.panelUnpowered = true
        system.powerCycleLeavesExternalsAsleep = true
        c.requestRestore(trigger: "manual")
        for _ in 0..<BlackoutController.failuresBeforeFirstPowerCycle { scheduler.advance() }
        XCTAssertEqual(system.powerCycleCount, 1)
        scheduler.advance() // 待ち時間の後に有効化要求
        scheduler.advance() // 検証
        XCTAssertTrue(system.panelEnabled)
        XCTAssertFalse(c.restorePending)

        system.asleepExternals = [] // 外部が遅れて起きる
        for _ in 0..<5 { c.evaluate(reason: "poll"); scheduler.advance() }
        XCTAssertTrue(system.panelEnabled, "戻った直後に自動OFFしない")
        XCTAssertEqual(system.calls.filter { !$0.enabled }.count, 1, "OFFは最初の1回だけ")
    }

    func testExternalConnectedWhileAsleepAutoDisablesOnceAwake() {
        let c = makeController()
        c.launch()
        c.displaysAsleep = true
        system.externals = [FakeDisplaySystem.external]
        system.asleepExternals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        scheduler.advance()
        XCTAssertTrue(system.calls.isEmpty, "スリープ中はOFFにしない")

        system.asleepExternals = []
        c.displaysAsleep = false
        c.evaluate(reason: "poll")
        scheduler.advance()
        XCTAssertFalse(system.panelEnabled, "起きたら接続時の自動OFFを実行する")
    }

    func testEnablingAutoModeLaterDoesNotActOnEarlierConnection() {
        let c = makeController()
        c.isAutoModeEnabled = false
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")

        c.isAutoModeEnabled = true
        c.evaluate(reason: "poll")
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testHeadlessFallbackIsNotUsableExternal() {
        let snapshot = DisplaySnapshot(online: [
            DisplayInfo(id: 7, isBuiltin: false, vendor: 0x756e_6b6e, model: 0x7669_7274),
        ])
        XCTAssertTrue(DisplayLogic.usableExternals(in: snapshot).isEmpty)
    }

    func testManagedStateIsPersistedBeforeAPICall() {
        var managedAtCall: CGDirectDisplayID?
        system.onSetEnabled = { [store] enabled in
            if !enabled { managedAtCall = store?.managedDisplayID }
        }
        let c = makeController()
        c.launch()
        system.externals = [FakeDisplaySystem.external]
        c.evaluate(reason: "callback")
        XCTAssertEqual(managedAtCall, FakeDisplaySystem.panel)
    }
}
