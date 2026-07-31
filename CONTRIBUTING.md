# Contributing

IssueやPull Requestを歓迎します。UI変更はmacOSの通常表示とフルスクリーン表示の両方で確認してください。

## 開発環境

- Apple Silicon Mac
- macOS 14以降
- Swift 6.1以降を含むXcode
- Xcode Metal Toolchain component

```bash
xcodebuild -downloadComponent metalToolchain
cd app
./build.sh
```

変更前後に次を実行してください。

```bash
cd app
xcodebuild \
  -scheme LocalLLM \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build
```

モデル推論まで確認する場合は、ビルド済み実行ファイルへ `--smoke-test` を渡します。初回は約2.4GBのモデルを取得します。

Pythonユーティリティを変更する場合は[`uv`](https://docs.astral.sh/uv/)で依存関係を同期してください。

```bash
uv sync --locked
```
