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

## MacBook Air M3 で内蔵ディスプレイを戻す仕組み（2026-09-23 実機確認済み）

### 事象

MacBook Air M3 (Mac15,12) / macOS 26.7 (25G229) で、内蔵ディスプレイをOFFにした後、ONに戻す要求
（`SLSConfigureDisplayEnabled(config, 1, true)` → `CGCompleteDisplayConfiguration`）が `1001` (kCGErrorIllegalArgument) で失敗し、
再起動でしか戻らない事故が2回あった。

### 原因（WindowServer のログと SkyLight の逆アセンブルから判断）

1. エントリーモデルの M3 は、蓋を閉じたときに外部ディスプレイを2台使えるよう、内蔵パネルの接続を転用する設計になっている。
   このため無効化すると、パネルがハードウェア的に切断扱いになる（IOMFB が `Display 1 hot plug 0` を出す）。
2. この状態では、WindowServer の `configuration_engine::config_via_client_api` が有効化要求を事前チェックで弾き、1001 を返す
   （`client api - Enable display` のログが出る前に拒否される）。
   確定オプション（`.permanently` 等）を変えても、同じトランザクションに他の変更を含めても、このチェックの結果は変わらない。
3. ディスプレイのスリープ→復帰や蓋の開閉でパネルが再通電する（`Display 1 hot plug 1`）と、有効化要求が通るようになる。
   2回の事故では、どちらも再通電の後に有効化要求を送るプロセスが動いていなかった。
4. 参考: [BetterDisplay #5658](https://github.com/waydabber/BetterDisplay/issues/5658)（同型機で同じ回避策の報告）、
   [#4723](https://github.com/waydabber/BetterDisplay/issues/4723)（BetterDisplay はこの機種での内蔵OFFを既定で無効にしている）。

### 復帰の手順

有効化要求が通らない間、`BlackoutController` は次の順で復帰を試みる:

1. 有効化要求を約1秒ごとに送り、実測で確認できるまで続ける。
2. 3回続けて失敗したら、ディスプレイを再通電させる（`pmset displaysleepnow` → 3秒後にユーザー操作を宣言して復帰）。
   その後6秒は有効化要求を送らない（スリープ中に送ると WindowServer の再構成待ちで最大10秒ブロックし、1014 で失敗するため）。最大2回まで。
3. それでも戻らなければ、メニューに「蓋を閉じて数秒後に開いてください」と表示する。有効化要求の再試行は続ける。

ほかに次の対策を入れている:

- スリープ復帰の通知を受けたら、すぐに評価し直す。
- 画面全体がスリープしている間は、スリープ中の外部ディスプレイも「接続あり」とみなして内蔵を戻さない。
  自動OFFは外部ディスプレイが新しく接続されたときだけ行い、スリープからの復帰は新しい接続とみなさない。
- 内蔵がOFFのときにメニューから終了すると、復帰を確認してから終了する。60秒たっても戻らなければ終了を取りやめる。
- `--restore` と `--verify-restore` も NSApplication で回す。素の `RunLoop` だと、自分で構成変更を確定させた後に
  画面の変更通知が処理されず、外部ディスプレイを抜いても一覧に残り続けた（仮想ディスプレイで再現・確認）。

### 実機検証（2026-09-23, Mac15,12 / macOS 26.7）

| シナリオ | コマンド | 結果 |
|---|---|---|
| 外部接続のままONに戻す | `--verify-restore --confirm-reboot-risk` | 1001 が4回 → 再通電1回 → 要求から16.5秒で復帰 |
| OFFのまま外部を抜く | `--verify-restore --confirm-reboot-risk --after-unplug` | 画面なしを検知 → 1001 が3回 → 再通電1回 → 抜いてから約10秒で復帰 |

macOS を更新したら、外部ディスプレイと電源をつなぎ、蓋を開けた状態で、上の2つを再確認すること。

### 注意

- 内蔵がOFFのときにアプリを強制終了（`kill -9` やアクティビティモニタの強制終了）しないこと。強制終了すると、戻す要求を送るプロセスがいなくなる。
  強制終了してしまったら、アプリを起動し直すか `--restore` を実行する（起動時に、OFFのままのパネルを検知して戻す）。
- 画面が真っ暗のまま戻らないときは、蓋を閉じて数秒後に開く（アプリか `--restore` が動いていれば、その後の要求で戻る）。

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

戻らないと表示されたら、コマンドを実行したまま蓋を閉じ、5秒ほど待ってから開く。

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
