# QuickMemo

Apple Watch と iPhone から音声メモを取って、Nextcloud に Obsidian 互換の Markdown として直接保存するアプリ。

思いついたことを腕から数タップで放り込んで、あとは Obsidian 側でタグと日付で拾う、という使い方を想定してる。

---

## ⚠️ これは個人用のアプリです

**作者が自分の環境で自分のためだけに使っているアプリを、そのまま公開しているものです。** 一般配布や他人の環境での利用を想定していません。

前提としている環境が特殊です:

- **自分で管理している Nextcloud サーバーが必要。** WebDAV エンドポイント（`/remote.php/dav/files/<user>/`）を直接叩いており、他のストレージサービスには対応していません
- **保存先が Obsidian の vault である前提。** frontmatter とインラインタグの二重書きは Dataview プラグインを想定した形式です
- **UI もエラーメッセージも日本語のみ。** ローカライズしていません
- カテゴリが「日記」「写真メモ」の 2 つに決め打ちされています。作者の使い方に合わせたものです
- iOS 26.2 / watchOS 26.2 という新しめの OS を要求します。古い端末は切り捨てています
- App Store には出していません。使うには Xcode で自分でビルドして実機に入れる必要があります

サポートや機能要望に応える予定はありません。**参考にするのは自由ですが、そのまま動かそうとすると自分の環境に合わせた改修がほぼ確実に必要になります。** 特にセキュリティ面は割り切った実装になっているので、[既知の制限](#既知の制限)に必ず目を通してください。

---

## 構成

Xcode プロジェクトは `QuickMemo/QuickMemo.xcodeproj`。ターゲットは 3 つ。

| ターゲット | 中身 |
|---|---|
| `QuickMemo` | iPhone アプリ。音声認識・設定画面・AppIntents |
| `QuickMemo Watch App Watch App` | watch アプリ。単体で WebDAV に送信する |
| `QuickMemoWidgetExtension` | 文字盤コンプリケーション（タップで起動） |

**watch と iPhone はそれぞれ独立して Nextcloud に書き込む。** WatchConnectivity は WebDAV の接続設定を iPhone → watch に配るためだけに使っていて、メモ本体は経由しない。watch が iPhone から離れていても単体で送れる。

```
[Watch App] ──── WebDAV (PUT) ────┐
                                  ├──> Nextcloud
[iPhone App] ─── WebDAV (PUT) ────┘
     │
     └─ WatchConnectivity ──> [Watch App]   ※接続設定の配布のみ
```

### ソース配置

```
QuickMemo/
├── QuickMemo/                          # iOS target
│   ├── Features/
│   │   ├── Recording/                  # SFSpeechRecognizer (ja-JP 固定)
│   │   ├── Settings/                   # WebDAV 接続設定
│   │   └── AppIntents/                 # Siri / ショートカット
│   ├── Services/
│   │   ├── WebDAVService.swift
│   │   ├── PendingMemoStore.swift      # 送信失敗メモの永続キュー
│   │   ├── MemoBuilder.swift
│   │   ├── LocationManager.swift
│   │   └── WatchSessionManager.swift   # 設定を watch へ送信
│   └── Models/MemoCategory.swift
├── QuickMemo Watch App Watch App/      # watchOS target
│   ├── ContentView.swift
│   ├── WebDAVService.swift             # WatchMemoBuilder も同居
│   ├── PendingMemoStore.swift          # 送信失敗メモの永続キュー
│   ├── WatchLocationManager.swift
│   └── WatchSessionManager.swift       # 設定を受信
└── QuickMemoWidget/                    # コンプリケーション
```

iOS と watchOS でコードは共有していない。`MemoCategory` / `MemoBuilder` / `WebDAVService` / `PendingMemoStore` は両方に同名・別実装で存在するので、**片方を直したらもう片方も確認すること**。

---

## 設計思想

**このアプリの仕様はここに書いていく。** 以前は別ファイルの企画書があったが、実装と乖離して二重管理になったので README に集約した。

### 思いついた瞬間に確定させ、あとは何があっても曲げない

このアプリの中心にあるのはこれ。メモの**内容・時刻・位置**は、保存ボタンを押した瞬間にすべて確定させる。そこから先の通信がどう転んでも、記録される値は変わらない。

そのために `createdAt` を**唯一の基準**にしている。frontmatter の `created:`、ファイル名、保存先の日付ディレクトリ、この3つはすべて同じ `createdAt` から導く。送信時刻は**どこにも使わない**。

副産物として再送が冪等になる。同じメモを何度送っても同じパスに同じ内容が書かれるだけなので、「PUT は通ったがレスポンスを取りこぼした」ケースでも安全に再送できる。

### 端末どうしを依存させない

watch と iPhone は**それぞれが独立して Nextcloud に PUT する**。WatchConnectivity で運ぶのは接続設定だけで、メモは通さない。

当初の設計では watch → iPhone → Nextcloud と中継する想定だった。やめた理由は、**iPhone が圏外・電源オフ・バッテリー切れのときに watch が何もできなくなる**から。腕だけで完結してほしいアプリで、母艦の状態に依存するのは受け入れられない。

同じ理由で保存先も File Provider（security-scoped bookmark）から WebDAV 直叩きに変えた。File Provider は iOS のファイルアプリを前提にした仕組みで、watch から使えない。

### 失敗しても黙って捨てない

送信に失敗したメモは永続キューに積んで後で再送する。ここで大事なのは**メモした瞬間の時刻と位置をセットで保存する**こと。翌日に再送されても、記録は前日の正しい位置と時刻になる。

キューは壊れにくさを優先していて、先頭から順に送り、最初の失敗で中断して残りを次回に回す。並列に送ったり失敗したものを飛ばしたりはしない。順序が保たれるほうが、あとから見たときに納得できる。

失敗時は入力欄をクリアする。残しておくとユーザーが手で再送してしまい、キューの分と合わせて重複するため。

### 拒否されたら黙る

ただし**認証で弾かれたときは再送しない。** サーバに一度拒否されたパスワードで送り続けると、Nextcloud のブルートフォース保護が IP ごと止めにかかる（HTTP 429）。2026年11月に実際にこれを踏んだ。アプリパスワードが無効になっていたのに、起動のたびに自動で再送して、さらに1回の送信でディレクトリ作成とアップロードの計5回ぶん失敗ログインを積んでいた。家のルータの IP ごと止められ、画面には「後で送信します」としか出ないので気づけなかった。

そこで次のようにしている:

- **401（認証エラー）を受けたら、設定が保存し直されるまで自動では送らない。** 新しいメモはネットワークに出さずキューに積み、画面に「設定でアプリパスワードを確認して」と出し続ける
- **429 を受けたら 30 分は自動では送らない**
- どちらの場合も、最初の 401/429 を受けた時点でそのリクエストを打ち切る（残りのディレクトリ作成とアップロードは投げない）
- 「未送信 N件」ボタンを押したときだけは、止まっていても1回は試す

### 測位でユーザーを待たせない

保存ボタンを押してから GPS を取り始めると、コールドスタートで数十秒待たされることがある。それでは「思いついたら即メモ」が成立しない。

なので watch は**アプリが前面にある間ずっと測位し続け**、保存時は収束済みの最新 fix を即座に使う。待ちが発生するのは起動直後だけで、それも数秒で打ち切る。精度と速度を両立させるにはこれしかなかった。

watchOS は腕を下ろすとすぐアプリを止めるので、「前面にある間だけ」という条件が電池消費の歯止めとして働いている。

### Obsidian の作法に寄せる

- **フォルダで分類せずタグで分類する。** カテゴリごとにフォルダを切ると、あとから分類を変えたくなったときにファイルを動かす羽目になる
- **タグは frontmatter とインラインの両方に書く。** frontmatter は Dataview が読み、インラインは本文検索で引っかかる。どちらか一方だと片方の導線が死ぬ
- **日付ディレクトリ（YYYY/MM/DD）で分ける。** 1フォルダにファイルが溜まり続けるのを防ぐ。Obsidian の日付ベースの動線とも噛み合う

### コードは共有しない

iOS と watchOS で `MemoCategory` / `MemoBuilder` / `WebDAVService` / `PendingMemoStore` が重複している。共通フレームワークに切り出していない。

個人用の小さなアプリで、共有のための構造を作るコストのほうが重いと判断した。**重複を許容する代わりに、片方を直したらもう片方も確認するのがルール**。

### 割り切っているところ

WebDAV のパスワードを UserDefaults に平文で持っている。Keychain ではない。Nextcloud の**アプリパスワード**（いつでも失効させられる使い捨ての資格情報）を使う前提で、盗まれたら失効させればいい、という判断。見落としではなく意図的な割り切り。

---

## 動作要件

- iOS 26.2 以上 / watchOS 26.2 以上
- Nextcloud（WebDAV エンドポイント `/remote.php/dav/files/<user>/`）
- ビルドには Xcode 26.4 と **watchOS シミュレータランタイム**が必要

---

## 保存形式

### パス

```
<savePath>/<YYYY>/<MM>/<DD>/yyyyMMdd_HHmmss.md
例: /QuickMemo/2026/08/24/20260824_153042.md
```

日付ディレクトリは送信時に MKCOL で自動作成される。カテゴリではフォルダを分けない（タグで管理する方針）。

### 中身

```markdown
---
tags: [diary]
created: 2026-08-24T15:30:42+09:00
source: apple-watch
location: [35.681236, 139.767125]
---

#diary ここに音声入力テキスト
```

- `source` は `apple-watch` / `iphone`
- `location` は取得できたときだけ付く
- タグは frontmatter とインラインの両方に書く（Dataview 対応 + 本文検索対応）

### カテゴリ

| rawValue | 表示 | 絵文字 |
|---|---|---|
| `diary` | 日記 | 📔 |
| `photo-memo` | 写真メモ | 📷 |

---

## 主要な設計

### 送信失敗時のリトライ

iPhone と watch のどちらも、送信に失敗したメモを `PendingMemoStore`（UserDefaults に JSON で永続化）へ積む。積むのは本文・カテゴリ・**メモした時刻**・**その時のジオタグ**のセット。

再送のタイミング:

- アプリ起動時
- フォアグラウンド復帰時
- 別のメモの送信に成功した直後
- （watch のみ）iPhone から WebDAV 設定が届いた時

未送信が残っている間は画面に「未送信 N 件」ボタンが出て手動でも流せる。

**時刻とジオタグは必ずメモした瞬間のもの**が使われる。ファイル名も `createdAt` から決まるので、再送しても同じパスに書かれる＝リトライが冪等になっている（PUT が通ったのにレスポンスを取りこぼした場合、再送は同じ内容で上書きするだけで済む）。

キューは先頭から順に送り、最初の失敗で中断して残りを次回に持ち越す。上限 200 件で古いものから捨てる。

### 位置情報

watch はアプリがフォアグラウンドにある間ずっと GPS を捕捉し続ける（`startUpdatingLocation` / `kCLLocationAccuracyBest`）。送信時に取得を開始すると cold start で数十秒待たされるのに対し、常時捕捉なら fix が収束済みなので**待ち時間ゼロで精度が高い**。`scenePhase` が `.active` を外れたら停止する。

保存時は追跡中の最新 fix を即座に使う。待ちが発生するのは「起動直後でまだ 1 個も fix が来ていない」場合だけで、その場合も最大 3 秒で打ち切る。

---

## ビルド

Xcode で開くのが基本。CLI からは:

```sh
cd QuickMemo

# watch アプリ
xcodebuild -project QuickMemo.xcodeproj \
  -scheme "QuickMemo Watch App Watch App" \
  -destination 'generic/platform=watchOS Simulator' build

# iPhone アプリ（watch アプリを埋め込むので watchOS ランタイムが要る）
xcodebuild -project QuickMemo.xcodeproj \
  -scheme QuickMemo \
  -destination 'generic/platform=iOS Simulator' build
```

### watchOS シミュレータランタイムが無いと落ちる

SDK が入っていてもランタイムが無いと、アセットカタログのコンパイルで両スキームとも失敗する:

```
Assets.xcassets: error: No available simulator runtimes for platform watchsimulator.
```

コードとは無関係。以下で入れる:

```sh
xcodebuild -downloadPlatform watchOS
```

GUI なら Xcode → Settings…（⌘,）→ **Components**（Xcode 15 までは "Platforms"）。

---

## 実機インストール

署名は自動署名で設定済み。

**1. watch 側でデベロッパモードを有効化**（watchOS 9 以降で必須）

watch の 設定 → プライバシーとセキュリティ → デベロッパモード → オン → 再起動

**2. iPhone アプリを先に入れて設定する**

WebDAV の接続情報は iPhone の設定画面で入力し、WatchConnectivity で watch に配られる。**watch だけ入れても「iPhoneで設定してください」が出て何も送れない。**

scheme `QuickMemo` を iPhone 実機で Run → 設定画面でサーバー URL・ユーザー名・アプリパスワード・保存先パスを入力。

**3. watch アプリを入れる**

scheme を `QuickMemo Watch App Watch App`、destination を実機の Apple Watch にして Run。

**iPhone と watch の両方をロック解除した状態で Run すること。** どちらかがロックされていると Developer Disk Image をマウントできずに失敗する:

```
kAMDMobileImageMounterDeviceLocked: The device is locked.
```

watch へのインストールはペアリング元の iPhone を経由するため、**先に iPhone 側の DDI がマウントされている必要がある**。このエラーが出たら、まずどちらのデバイスで失敗しているかを確認する:

```sh
xcrun devicectl list devices
```

`connected (no DDI)` になっているデバイスが原因。エラーログの `DeviceIdentifier` と突き合わせれば確実に特定できる（`DDIPath` が `iOS_DDI` なら iPhone 側、`watchOS_DDI` なら watch 側）。

watch は腕から外すと即ロックするので、着けたまま作業するのが楽。DDI のマウントは一度成功すればデバイスを再起動するまで維持される。

初回インストールは数分かかることがある。iPhone の近くに置いておく。Devices and Simulators に watch が出てこないときはペアリング / 同一 Wi-Fi を確認。

---

## 既知の制限

- **WebDAV のパスワードが UserDefaults に平文で入っている。** Keychain ではない。さらに WatchConnectivity の userInfo でそのまま watch に送っている。Nextcloud のアプリパスワード（＝失効させられる使い捨て）を使う前提の割り切り。
- **watch の音声入力を日本語に固定できない。** watchOS には入力言語やディクテーション直行を指定する公開 API が存在しない（`Speech.framework` も watchOS SDK に無いため、iPhone 側の `SFSpeechRecognizer(locale:)` 方式は移植できない）。watch 本体のキーボード言語設定から英語を外して対処する。
- 同一秒に 2 件保存すると同名になり上書きされる。UI 上ほぼ起こらないため許容している。

---

## 拡張候補（未着手）

- 音声ファイル自体の添付（AVAudioRecorder → 同フォルダに m4a）
- パスワードの Keychain 移行
