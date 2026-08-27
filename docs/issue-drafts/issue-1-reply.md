詳細な調査と再現手順まで、本当にありがとうございます。おかげで原因を正確に特定できました。
こちらでも全リリースを再確認したところ、**ご指摘の内容は事実で、しかも当初こちらが把握していたより影響範囲が広い**ことが分かりました。

## 確認結果

配布 zip への AppleDouble（`._*`）混入は **v1.0.0 〜 v1.5.2 のすべて**に該当していました（v1.5.3 で解消済み）。

| バージョン | zip 内の `._` | `ditto` 展開 | **Finder（アーカイブユーティリティ）展開** | `unzip` 展開 |
|---|---|---|---|---|
| v1.0.0 – v1.2.0 | 8–9 個 | OK | OK | NG |
| v1.3.0 – v1.5.2 | 166 個 | OK | **NG** | NG |
| v1.5.3 | 0 個 | OK | OK | OK |

そして、こちらの認識に誤りがありました。**Finder でダブルクリック展開した場合も壊れます。**
v1.5.3 のリリースノートに「Finder での展開・Homebrew・自動アップデートは影響を受けていません」と書きましたが、**Finder についてはこれが誤り**でした。訂正してお詫びします。リリースノートも修正します。

### 原因

`Sparkle.framework` の**シンボリックリンク**です。アーカイブユーティリティは `._X` を `X` の拡張属性へ復元してくれますが、`X` がシンボリックリンクの場合は復元できず、`._X` が実ファイルとして残ります。v1.5.2 を Finder で展開すると、ちょうど 9 個（すべて framework 内のシンボリックリンク）が残ります:

```
Sparkle.framework/._Autoupdate      Sparkle.framework/._Modules
Sparkle.framework/._Updater.app     Sparkle.framework/._PrivateHeaders
Sparkle.framework/._XPCServices     Sparkle.framework/._Resources
Sparkle.framework/._Headers         Sparkle.framework/._Sparkle
Sparkle.framework/Versions/._Current
```

これが framework 直下に残るため、ご報告のとおり
`unsealed contents present in the root directory of an embedded framework`
になります。手元でも同一メッセージを再現しました。（`ditto -x -k` は `NOFOLLOW` で拡張属性を設定するため 0 個になり、これがこちらの誤検証の原因でした）

影響を受けない経路も確認しました:
- **Homebrew**: cask のダウンロードは `merge_xattrs: true` で、zip に `._` が含まれる場合は `ditto -x -k` で展開されます → クリーン
- **アプリ内の自動アップデート**: Sparkle の `SUPipedUnarchiver` が `/usr/bin/ditto -x -k` を使います → クリーン

## 復旧方法

### いちばん簡単な方法（入れ直し不要・検証済み）

余分なファイルを消すだけで署名は回復します。

```bash
# 残っている Sparkle のプロセスを終了
pkill -f 'com.atsushisagae.ClaudeBar'    # Autoupdate と Updater
pkill -x ClaudeBar                        # 本体

# 余分な ._ ファイルを削除（正常なバンドルには ._ で始まるファイルは 1 つもありません）
find /Applications/ClaudeBar.app -name '._*' -delete

# 中途半端に残った Sparkle の作業ディレクトリも掃除
rm -rf ~/Library/Caches/com.atsushisagae.ClaudeBar/org.sparkle-project.Sparkle

# 確認 → "accepted / source=Notarized Developer ID" と出れば OK
spctl -a -vv /Applications/ClaudeBar.app

open -a ClaudeBar
```

### v1.5.3 に入れ直す場合

```bash
pkill -f 'com.atsushisagae.ClaudeBar'; pkill -x ClaudeBar
rm -rf ~/Library/Caches/com.atsushisagae.ClaudeBar/org.sparkle-project.Sparkle

cd ~/Downloads
curl -fLO https://github.com/sagaway3105/claude-bar/releases/download/v1.5.3/ClaudeBar-v1.5.3.zip
rm -rf /tmp/claudebar && ditto -x -k ClaudeBar-v1.5.3.zip /tmp/claudebar
rm -rf /Applications/ClaudeBar.app
mv /tmp/claudebar/ClaudeBar.app /Applications/

spctl -a -vv /Applications/ClaudeBar.app
open -a ClaudeBar
```

### Homebrew の場合

```bash
pkill -f 'com.atsushisagae.ClaudeBar'; pkill -x ClaudeBar
brew update && brew reinstall --cask sagaway3105/tap/claudebar
```

※ cask は `auto_updates true` なので通常の `brew upgrade` では更新されません。`brew reinstall` か `brew upgrade --cask --greedy claudebar` をお使いください。

## Sparkle が止まっていた件について

こちらは調べた結果、**署名検証で弾かれていたわけではなさそう**です。Sparkle 2.9.4 の `SUUpdateValidator` は「アーカイブの EdDSA 署名」か「新旧バンドルの Apple 署名の一致」のどちらか一方が通れば受理する実装で、`SUPublicEDKey` は 1.5.2 と 1.5.3 で同一のため、旧バンドルの seal が壊れていても検証自体は通ります。

止まっていた直接の原因は、**アプリ側が終了しない限り Sparkle のインストーラが待ち続ける**ためです。Sparkle は「アプリの終了 → 差し替え → 再起動」の順で動きますが、当アプリはメニューバー常駐で終了する機会がないうえ、

- `showInstallingUpdate(withApplicationTerminated:retryTerminatingApplication:)` を空実装にしていて、再度終了を促す導線がない
- `applicationShouldHandleReopen` が未実装のため、再度 .app を開いても無反応

という2点が重なって、`Autoupdate` / `Updater` が何日も残る状態になっていました。

この2点は修正済みで、次のリリース（v1.5.4）に含めます。加えて、自動ダウンロードで更新の準備ができた時点で「再起動してアップデート」を一度だけ確認するようにし、常駐アプリでもインストール待ちのプロセスが何日も残らないようにしました。

## 対応状況

1. ✅ v1.5.3 のリリースノートの誤記（Finder 展開は無傷、という記述）を訂正
2. ✅ README と旧リリースページ（v1.0.0〜v1.5.2）に、この症状と上記の復旧手順を追記
3. ✅ CI とリリーススクリプトの両方で「配布 zip に `._` が 0 件であること」と「ditto / unzip 展開後の署名有効性」を必ず検証するように
4. ✅ `applicationShouldHandleReopen`（再オープンでパネル表示）と、更新インストール時の終了導線を実装 — **v1.5.4 で配信します**

重ねて、丁寧な切り分けとログの提示をありがとうございました。とても助かりました。
