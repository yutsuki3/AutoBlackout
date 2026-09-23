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

## 動作要件

- macOS 13 (Ventura) 以降
- Apple Silicon（内蔵ディスプレイの完全切断はApple Siliconのみ対応）

## ビルド

```bash
swift build -c release
.build/release/AutoBlackout
```

## 設計方針

- `PrivateDisplayAPI.swift` — 非公開API呼び出しをここに隔離。他のファイルは非公開APIの存在を知らない。
- `DisplayMonitor.swift` — 公開APIのみで構成。ディスプレイの接続検知を担当。
- `BlackoutController.swift` — 上記2つを仲介するドメインロジック。「外部ゼロならOFFにしない/OFFを維持しない」という安全ルールをここに集約。
- `AppDelegate.swift` / `main.swift` — UI層（AppKitのNSStatusItem）。

参考にした実装: [alin23/Lunar](https://github.com/alin23/Lunar)（BlackOut機能の設計思想）、
[0xruth1ezz/screen-toggle](https://github.com/0xruth1ezz/screen-toggle)（非公開APIの呼び出し方・安全装置の作り方）。
