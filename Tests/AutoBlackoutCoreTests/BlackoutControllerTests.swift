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
    /// SLSGetDisplayList が使えるか。
    var allListAvailable = false
    /// true の間、有効化要求は成功を返すが実際には適用されない（バグ3の再現条件）。
    var ignoreEnableRequests = false
    /// true の間、無効化要求は成功を返すが実際には適用されない。
    var ignoreDisableRequests = false
    /// setEnabled が呼ばれた瞬間のフック。
    var onSetEnabled: ((Bool) -> Void)?
    var calls: [(enabled: Bool, id: CGDirectDisplayID)] = []

    func snapshot() -> DisplaySnapshot {
        var online: [DisplayInfo] = []
        if panelEnabled { online.append(DisplayInfo(id: Self.panel, isBuiltin: true)) }
        online += externals.sorted().map { DisplayInfo(id: $0, isBuiltin: false) }
        let all = allListAvailable
            ? [DisplayInfo(id: Self.panel, isBuiltin: true)] + externals.sorted().map { DisplayInfo(id: $0, isBuiltin: false) }
            : nil
        return DisplaySnapshot(online: online, all: all)
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        onSetEnabled?(enabled)
        calls.append((enabled, displayID))
        guard displayID == Self.panel else { return false }
        if enabled, ignoreEnableRequests { return true }
        if !enabled, ignoreDisableRequests { return true }
        panelEnabled = enabled
        return true
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
        scheduler.advance()
        scheduler.advance()
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
