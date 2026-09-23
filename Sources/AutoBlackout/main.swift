import AppKit
import AutoBlackoutCore

// 緊急復旧モード: `AutoBlackout --restore`
// 画面が真っ暗でも SSH やターミナルから内蔵ディスプレイの有効化要求を送れるようにする。
if CommandLine.arguments.contains("--restore") {
    let logger = FileEventLogger()
    let system = LiveDisplaySystem()
    let store = UserDefaultsStateStore()
    let snapshot = system.snapshot()
    let candidates = [
        store.managedDisplayID,
        DisplayLogic.onlineBuiltIn(in: snapshot),
        store.lastKnownBuiltInID,
        DisplayLogic.anyBuiltIn(in: snapshot),
    ].compactMap { $0 }
    let unique = candidates.reduce(into: [CGDirectDisplayID]()) { if !$0.contains($1) { $0.append($1) } }

    guard PrivateDisplayAPI.isAvailable, !unique.isEmpty else {
        let message = "--restore: nothing to do (api=\(PrivateDisplayAPI.isAvailable) candidates=\(unique))"
        logger.log(message)
        print(message)
        exit(1)
    }
    for id in unique {
        let ok = system.setEnabled(true, for: id)
        let message = "--restore: enable panel=\(id) apiResult=\(ok)"
        logger.log(message)
        print(message)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Dockに表示せず、メニューバーのみに常駐する
app.run()
