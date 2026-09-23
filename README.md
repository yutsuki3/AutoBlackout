# AutoBlackout

外部ディスプレイを接続したら内蔵ディスプレイを自動でOFFにする、macOSメニューバーアプリ。

個人利用目的。非公開API (`SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled`) を
実行時に `dlsym` で解決して使用しているため、Mac App Storeには配布不可。
macOSアップデートで動かなくなる可能性がある。

## 現在のスコープ

- [x] メニューバーからの手動トグル
- [x] 外部モニター接続時の自動OFF / 全外し時の自動復帰
- [ ] スリープ/ウェイク時の状態再適用
- [ ] 「外部ディスプレイあり」の判定条件の精緻化（ミラーリング中・スリープ中の除外など）
- [ ] 複数の非公開シンボル名（macOSバージョン差）へのフォールバック強化

## 既知の問題（2026-09-23 実機確認・未解決）

**macOS 26.7 (25G229) では、内蔵ディスプレイをOFFにすると再起動まで戻せない。**
そのため現在は `PrivateDisplayAPI.isDisableAllowed = false` でOFF操作を遮断している（ONに戻す処理と監視は有効）。

- `SLSConfigureDisplayEnabled(config, 1, false)` → `CGCompleteDisplayConfiguration(.forAppOnly)` は成功し、内蔵が消える。
- `SLSConfigureDisplayEnabled(config, 1, true)` は `0` を返すが、続く `CGCompleteDisplayConfiguration` が
  `1001` (kCGErrorFailure) で失敗。`.forSession` でも同じ。
- OFFにしたプロセスの終了、蓋の開閉、スリープ/ウェイク、ログアウトでも戻らない。再起動でのみ復旧。
- `SLSGetDisplayList` はOFF中も内蔵のID (`1`) を返す。`CGGetOnlineDisplayList` からは消える。

調査の候補: 有効化時の確定オプション（`.permanently` 等）、同一トランザクションで他の構成変更を伴わせる、
別の非公開シンボル（Lunar/BetterDisplayの復帰手順）、`screen-toggle` が動作するmacOSバージョンとの差分。
**実機でOFFにする検証は、ONに戻せる経路を先に確立してから行うこと。**

## 動作要件

- macOS 13 (Ventura) 以降
- Apple Silicon（内蔵ディスプレイの完全切断はApple Siliconのみ対応）

## ビルド

```bash
swift build -c release
.build/release/AutoBlackout
```

## テスト（実ディスプレイには触れない）

```bash
swift test
```

## 緊急復旧

内蔵ディスプレイが戻らなくなった場合（SSH等から）:

```bash
.build/release/AutoBlackout --restore
```

ログ: `~/Library/Logs/AutoBlackout/recovery.log`（os_log サブシステム `io.github.yutsuki3.AutoBlackout` にも出力）

## 設計方針

- `AutoBlackoutCore/` — 実機に触れないロジック層（ユニットテスト対象）。
  - `BlackoutController.swift` — 状態機械。「外部ゼロなのに内蔵が無効」を検知したら、復帰を実測で確認できるまで再試行する。
    接続変更コールバック・1秒ポーリング・起動時自己修復・終了時復元のすべてがここを通る。
  - `DisplayLogic.swift` / `DisplayTypes.swift` — スナップショットからの判定と、実機操作のプロトコル。
- `AutoBlackout/` — 実機との接点。
  - `PrivateDisplayAPI.swift` — 非公開API呼び出しをここに隔離。
  - `LiveSystem.swift` — プロトコルの本番実装（CG・UserDefaults・ログファイル）。
  - `DisplayMonitor.swift` — 構成変更コールバックの登録のみ。
  - `AppDelegate.swift` / `main.swift` — UI層と `--restore` 緊急復旧モード。

参考にした実装: [alin23/Lunar](https://github.com/alin23/Lunar)（BlackOut機能の設計思想）、
[0xruth1ezz/screen-toggle](https://github.com/0xruth1ezz/screen-toggle)（非公開APIの呼び出し方・安全装置の作り方）。
