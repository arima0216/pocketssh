# SideStore セットアップ手順（Windows 11 + iPhone 16e）

自作アプリ `PocketSSH.ipa` を実機に入れるための下ごしらえ。
初回だけ手間がかかるが、一度通せば以後はiPhone単体で完結する。

前提: iPhoneにパスコードが設定されていること / Wi-Fi接続（モバイル回線では動作しない）

---

## STEP 1【PC】iTunes を入れる

USB経由でiPhoneと通信するためのドライバが必要。iTunes自体は使わない。

- ダウンロード: https://www.apple.com/itunes/download/win64
- Microsoft Store版より **Apple公式サイト版が推奨**（公式ドキュメント記載）

インストール後、iTunesを起動する必要はない。

## STEP 2【iPhone】LocalDevVPN を入れる

SideStoreが端末内部で通信するために使う「見せかけのVPN」。
外部には一切通信せず、電池もほぼ食わない（公式FAQ明言）。

- App Store: https://apps.apple.com/app/localdevvpn/id6755608044
- 入れるだけでOK。接続はSTEP 7で行う

> 古い記事にある **StosVPN / WireGuard は現在は非推奨**。LocalDevVPNに一本化された。

## STEP 3【PC】iloader を入れる

以前の AltServer に代わる現行の公式ツール。

- ダウンロード（MSI推奨）:
  https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.msi

## STEP 4【PC + iPhone】ペアリング

1. iPhoneをUSBでPCに接続
2. iPhone側に「このコンピュータを信頼しますか？」→ **信頼** → パスコード入力
3. PCで iloader を起動
4. 「**Delete Stored Pairing**」→ 一覧から自分のiPhoneを選択
5. iPhone側に出る **Trust** をタップ
6. 「**Manage Pairing File**」→ SideStore の横の「**Place**」をクリック
7. 緑字で `Pairing file placed successfully!` が出れば成功

## STEP 5【PC】SideStore 本体をiPhoneに入れる

1. iloader に Apple ID でサインイン（大文字小文字を区別）
2. デバイス一覧から自分のiPhoneを選択
3. 「**Install SideStore (Stable)**」をクリック

> Apple IDについて: 通常のIDで動くが、公式のトラブルシューティングでは
> 「サイドロード専用の別Apple ID」を作ることが随所で推奨されている。
> 昔あった「アカウントロック」は古いAnisetteサーバーが原因で、
> 現行版(0.6.3)では起きにくいと公式が明記している。

## STEP 6【iPhone】証明書を信頼＋デベロッパモードON

1. 設定 → 一般 → **VPNとデバイス管理**
2. 「デベロッパApp」欄の自分のApple ID名をタップ
3. 「信頼」→「許可して再起動」→ パスコード入力
4. 設定 → **プライバシーとセキュリティ** → 一番下の「**デベロッパモード**」をON
5. 端末が再起動する

## STEP 7【iPhone】SideStore 初回セットアップ

1. **LocalDevVPN** を開いて「Connect」
2. **SideStore** を開く
3. STEP 5と同じApple IDでサインイン
4. 「My Apps」タブへ
5. SideStoreの右の「**7 DAYS**」をタップして手動リフレッシュ
6. 証明書の確認プロンプトが出たら「Yes」/「Refresh Now」

ホーム画面に戻ってSideStoreが再度開けば成功。

## STEP 8【iPhone】PocketSSH を入れる

1. `PocketSSH.ipa` をiPhoneに渡す
   （AirDrop不可なので、iCloud Drive / メール添付 / LocalSend など。
    またはGitHubのActionsページからiPhoneのSafariで直接ダウンロード）
2. SideStore → 「My Apps」→ 右上の「+」→ `PocketSSH.ipa` を選択
3. インストール完了を待つ

## STEP 9【動作確認】

1. iPhoneで PocketSSH を開く → 「起動」をタップ
2. 初回に出る「ローカルネットワーク上のデバイスへの接続」→ **許可**（重要）
3. 画面に出るIPアドレスを確認
4. PCから接続:

```powershell
ncat 192.168.x.x 2222
```

`ncat` が無い場合は Nmap 付属版を入れるか、PowerShellで簡易接続:

```powershell
$c = New-Object System.Net.Sockets.TcpClient("192.168.x.x", 2222)
$s = $c.GetStream(); $r = New-Object System.IO.StreamReader($s); $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true
# 以後 $w.WriteLine("help") で送信、$r.ReadLine() で受信
```

`help` と打ってコマンド一覧が出れば成功。

---

## つまづいたら

| 症状 | 対処 |
|------|------|
| AFC connection failure / minimuxerエラー4,27 | LocalDevVPNとWi-Fiが両方接続されているか確認 → SideStore再起動 → ペアリングやり直し |
| ペアリング失敗（エラー1006） | SideStore設定「Reset Pairing File」→ iloaderでDelete Stored Pairing → やり直し |
| 証明書エラー | SideStore設定でAnisetteサーバーを変更 → サインアウト/イン → 端末再起動 |
| 3アプリまでしか入らない | 無料Apple IDの制限（SideStore本体も1枠使う）。LiveContainerを使うと回避できる |

公式ドキュメント: https://docs.sidestore.io/
