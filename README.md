# LocalLLM

macOSのどこからでも `Shift` を素早く2回押して呼び出せる、Apple Silicon向けのローカルAIパレットです。質問と回答はMacの中で処理され、普段使っているアプリやフルスクリーンの手前に小さな入力ウィンドウを表示します。

既定モデルは [`wcamon/Agents-A1-4B-MLX-4bit`](https://huggingface.co/wcamon/Agents-A1-4B-MLX-4bit) です。

## 特長

- `Shift` のダブルタップで、どのSpaceからでもすぐ質問
- AppKitベースのmacOSネイティブUIと半透明のグラデーション
- [MLX Swift](https://github.com/ml-explore/mlx-swift-lm)をアプリ内で直接実行。PythonやローカルHTTPサーバーは不要
- 回答をストリーミング表示し、同じウィンドウ内では会話を継続
- 最後の利用から60秒後にモデルをメモリから解放
- 質問履歴、システムプロンプト、モデル選択をローカル保存
- 対応するMacではApple Foundation Modelsも選択可能

## 必要環境

- Apple Silicon Mac
- macOS 14 Sonoma以降
- 初回モデル取得用のインターネット接続と約3GBの空き容量
- グローバルショートカット用のアクセシビリティ権限

## インストール

署名・公証済みビルドは[GitHub Releases](https://github.com/lifeprompt-team/local-llm/releases)で配布します。DMGを開き、`LocalLLM.app`をApplicationsへ移動してください。

初回起動時は「システム設定 → プライバシーとセキュリティ → アクセシビリティ」でLocalLLMを有効にします。その後、メニューバーのアイコンから一度終了し、もう一度起動してください。

モデルは初回の質問時にHugging Faceから取得します。`mlx_lm`で同じモデルを取得済みの場合は既存のキャッシュを再利用します。

## 使い方

- `Shift`を素早く2回: 入力パレットを表示
- `Enter`: 質問を送信
- `Esc`またはパレット外をクリック: 閉じる
- メニューバーのLocalLLMアイコン: 質問、履歴、設定、終了

入力欄の先頭で `/` を打つとコマンド候補が表示されます。

- `/settings`: 設定を開く
- `/history`: 履歴を開く
- `/quit`: LocalLLMを終了

履歴は `~/Library/Application Support/LocalLLM/history.json` に最大500件保存されます。

## ソースからビルド

XcodeのSwift 6.1以降とMetal Toolchainが必要です。Xcodeの「Settings → Components」からMetal Toolchainを追加するか、次を実行します。

```bash
xcodebuild -downloadComponent metalToolchain
git clone https://github.com/lifeprompt-team/local-llm.git
cd local-llm/app
./build.sh --install
```

ビルド結果は `app/build/LocalLLM.app` です。MLXのMetalライブラリを生成するため、`swift build`ではなく`xcodebuild`を使用しています。

モデル込みの動作確認は次のコマンドで実行できます。

```bash
cd app/build/DerivedData/Build/Products/Release
./LocalLLM --smoke-test
```

## CLIツール（任意）

リポジトリ直下のPythonスクリプトは、MLXをCLIやOpenAI互換サーバーとして試すための開発用ユーティリティです。macOSアプリの実行には不要です。

```bash
uv sync
uv run mlx_lm.chat --model wcamon/Agents-A1-4B-MLX-4bit
./serve.sh
./curl_example.sh 8088 "こんにちは"
```

## プライバシー

推論、プロンプト、回答履歴はローカルで処理されます。テレメトリはありません。初回モデル取得時のみHugging Faceへ接続します。選択したモデル自体には、それぞれの配布元のライセンスが適用されます。

## 配布と開発

- 配布ビルドとApple公証: [DISTRIBUTION.md](DISTRIBUTION.md)
- コントリビューション: [CONTRIBUTING.md](CONTRIBUTING.md)
- 脆弱性の報告: [SECURITY.md](SECURITY.md)

## License

アプリケーションコードは[MIT License](LICENSE)で公開しています。依存ライブラリとダウンロードするモデルには、それぞれのライセンスが適用されます。
