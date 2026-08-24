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

> 企画時の設計書は [作りたいもの.md](作りたいもの.md)。ただし当時は File Provider 経由で保存する想定だったのが実装では WebDAV 直叩きに変わっているなど、現状とは乖離がある。**実装の現状はこの README が正**。

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

iOS と watchOS でコードは共有していない。`MemoCategory` / `MemoBuilder` / `WebDAVService` は両方に同名・別実装で存在するので、**片方を直したらもう片方も確認すること**。

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

### 送信失敗時のリトライ（watch のみ）

watch は送信に失敗したメモを `PendingMemoStore`（UserDefaults に JSON で永続化）へ積む。積むのは本文・カテゴリ・**メモした時刻**・**その時のジオタグ**のセット。

再送のタイミングは 4 つ:

- アプリ起動時
- フォアグラウンド復帰時
- 別のメモの送信に成功した直後
- iPhone から WebDAV 設定が届いた時

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
- **iPhone 側にはオフラインキューが無い。** 送信に失敗するとエラー表示のみで、メモは失われる。リトライ機構は watch だけに入っている。
- **watch の音声入力を日本語に固定できない。** watchOS には入力言語やディクテーション直行を指定する公開 API が存在しない（`Speech.framework` も watchOS SDK に無いため、iPhone 側の `SFSpeechRecognizer(locale:)` 方式は移植できない）。watch 本体のキーボード言語設定から英語を外して対処する。
- 同一秒に 2 件保存すると同名になり上書きされる。UI 上ほぼ起こらないため許容している。

---

## 拡張候補（未着手）

- 音声ファイル自体の添付（AVAudioRecorder → 同フォルダに m4a）
- iPhone 側へのオフラインキュー導入
- パスワードの Keychain 移行
