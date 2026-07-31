# 署名・公証なしのpreviewビルド

このpreviewは無料で配布するため、**Apple Developer IDによる署名とAppleの公証を行っていません**。そのため、macOSは初回起動を標準でブロックします。LifePromptの公式GitHubリポジトリから取得し、必要に応じて添付の`checksums.txt`でファイルを検証してください。

## インストール

1. DMGをダウンロードし、`LocalLLM.app`をApplicationsへ移動します。
2. LocalLLMを一度開こうとして、表示されたセキュリティ警告を閉じます。
3. 「システム設定 → プライバシーとセキュリティ」を開き、セキュリティ欄までスクロールします。
4. LocalLLMの「このまま開く」を選び、認証後の確認画面でも「開く」を選択します。
5. グローバルなShiftダブルタップを使うため、「プライバシーとセキュリティ → アクセシビリティ」でLocalLLMを有効にします。

「このまま開く」は、最初に起動を試してから約1時間表示されます。詳しくは[Apple公式の案内](https://support.apple.com/guide/mac-help/mh40617/mac)を参照してください。この許可はビルドごとに保存されます。将来Developer IDで署名・公証した正式版では、この操作は不要になります。

## 必要環境

- Apple Silicon Mac
- macOS 14 Sonoma以降
- 初回取得するモデル用に約3GBの空き容量
