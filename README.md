# PocketSSH

iPhoneを「PCのターミナルから叩けるサーバー」にする自作アプリ。
Windows PCで開発 → GitHub Actions(macOSランナー)でビルド → SideStoreで実機に入れる。

## いまの状態（Phase 1）

- ポート **2222** でTCP待ち受け
- 行単位の疑似シェル（`help` / `pwd` / `ls` / `cd` / `cat` / `echo` / `device` / `date` / `exit`）
- アプリを**前面に出している間だけ**動く（起動中は自動ロックを抑止）

## 設計上の前提（重要）

iOSのサンドボックスは `fork` / `posix_spawn` を禁止しているため、
**本物のsshdのように `/bin/sh` を子プロセスとして起動することはできない**。
そのため本アプリはコマンド文字列を解釈して `FileManager` などのAPI呼び出しに変換している。
触れる範囲はアプリ自身のサンドボックス（Documents以下）のみ。

またiOSはアプリがバックグラウンドに入るとリッスン中のソケットを回収するため、
「常時待ち受けするSSHサーバー」は非脱獄端末では実現できない。
App Storeにある FTP/WebDAV サーバーアプリも同じ制約で「開いている間だけ」動作する。

## ロードマップ

| Phase | 内容 | 状態 |
|-------|------|------|
| 1 | TCPサーバー＋疑似シェル、ビルド〜サイドロードのパイプライン確立 | 実装済み・実機未検証 |
| 2 | `swift-nio-ssh` で本物のSSHプロトコル対応（`ssh -p 2222` で繋がる） | 未着手 |
| 3 | 写真ライブラリの取り出し、TLS/鍵認証、バックグラウンド延命の実験 | 未着手 |

## ビルド

GitHub Actions（`.github/workflows/build-ipa.yml`）がpush時に走り、
未署名の `PocketSSH.ipa` をArtifactとして出力する。署名はSideStore側が行う。

ローカルにMacがある場合:

```sh
brew install xcodegen
xcodegen generate
open PocketSSH.xcodeproj
```

## 実機に入れる手順

1. GitHubにこのリポジトリを**パブリック**でpush（公開リポならmacOSランナーが無料・無制限）
2. Actionsの実行完了後、Artifactから `PocketSSH.ipa` をダウンロード
3. iPhoneに **SideStore** をセットアップ（初回のみPC必要）
4. SideStoreで `.ipa` を選んでインストール（無料Apple IDなら7日ごとに再署名）
5. アプリを開いて「起動」→ 表示されたIPに対してPCから接続

```powershell
# PC側（同じWi-Fi）
ncat 192.168.x.x 2222
# または
Test-NetConnection 192.168.x.x -Port 2222
```

初回起動時に「ローカルネットワーク上のデバイスへの接続」を**許可**すること。
拒否すると待ち受けはできてもPCから到達できない。

## 構成

```
project.yml                  XcodeGen定義（.xcodeprojは生成物なのでコミットしない）
Sources/PocketSSHApp.swift   エントリポイント
Sources/ContentView.swift    UI（状態表示・起動停止・ログ）
Sources/TCPServer.swift      NWListenerでの待ち受けと接続管理
Sources/CommandShell.swift   疑似シェル（コマンド → FileManager API）
```
