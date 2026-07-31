# macOS Distribution

LocalLLMは、GitHub ActionsでDeveloper ID署名、公証、ZIP/DMG作成、GitHub Release公開まで自動化できます。

## 配布に必要なもの

1. Apple Developer Programのメンバーシップ
2. `Developer ID Application`証明書
3. App Store Connect APIキー（Developer権限以上）
4. GitHubリポジトリのActions secrets

Developer IDを使わないローカルビルドも作れますが、他のMacではGatekeeperの警告が表示されます。一般配布では署名とApple公証を省略しないでください。

## GitHub Actions secrets

リポジトリの「Settings → Secrets and variables → Actions」に次を登録します。

| Secret | 内容 |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64` | Developer ID Application証明書を含む`.p12`のBase64 |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD` | `.p12`の書き出しパスワード |
| `DEVELOPER_ID_APPLICATION_IDENTITY` | `Developer ID Application: Name (TEAMID)`という署名ID |
| `APPLE_API_KEY_BASE64` | App Store Connect APIキー`.p8`のBase64 |
| `APPLE_API_KEY_ID` | APIキーID |
| `APPLE_API_ISSUER_ID` | Issuer ID |

バイナリをBase64化する例です。値はターミナルへ表示せず、直接クリップボードへ渡してください。

```bash
base64 -i DeveloperID.p12 | pbcopy
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

## リリース

`v`から始まるSemVerタグをpushすると`.github/workflows/release.yml`が動きます。

```bash
git tag v0.1.0
git push origin v0.1.0
```

ワークフローは次を順番に行います。

1. Xcode Metal Toolchainを準備
2. ReleaseビルドとHardened Runtime付きDeveloper ID署名
3. Apple notary serviceへ送信し、承認を待機
4. 公証チケットを`.app`とDMGへstaple
5. Gatekeeper検証
6. SHA-256付きZIP/DMGをGitHub Releaseへ公開

## ローカルで配布物を作る

未公証の開発用ZIP/DMGは次で作成できます。

```bash
cd app
./package-release.sh 0.1.0
```

Keychainへnotarytool profileを登録済みなら、公証まで実行できます。

```bash
xcrun notarytool store-credentials LocalLLM-notary
SIGN_IDENTITY='Developer ID Application: Name (TEAMID)' \
NOTARY_PROFILE='LocalLLM-notary' \
REQUIRE_NOTARIZATION=1 \
./package-release.sh 0.1.0
```

成果物は`app/build/dist`へ作成されます。
