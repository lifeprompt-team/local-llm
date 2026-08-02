import Foundation

/// 選択モデルとシステムプロンプトを UserDefaults に永続化する。再起動後も復元される。
@MainActor
enum Settings {
    private static let defaults = UserDefaults.standard
    private static let modelKey = "selectedModel"
    private static let systemKey = "systemPrompt"
    private static let voiceInputKey = "voiceInputEnabled"

    nonisolated static let defaultModel = "wcamon/Agents-A1-4B-MLX-4bit"
    nonisolated static let appleFoundationModelID = "apple-foundation"
    nonisolated static let appleFoundationModelName = "Apple Intelligence（オンデバイス）"
    nonisolated static let grokModelID = "grok-build"
    nonisolated static let grokModelName = "Grok 4.5（クラウド・Web/X検索）"
    static let defaultSystemPrompt = """
        あなたは開発者のアシスタントです。前置きや相づちは書かず、本題だけを返します。

        「単語」や「フレーズ」のあとに言語名（英語・英語で など）が付く形で聞かれたときは、\
        関数名や変数名の候補を選ぶための質問だと考えてください。訳語を1つに絞らず、\
        ニュアンスや言い回しの違う候補を複数（できれば5個前後）箇条書きで挙げます。\
        必要なら各候補にニュアンスの短い補足を付けてかまいません。

        例:「面白い 英語」
        - interesting（興味深い・関心を引く）
        - funny（笑える・こっけいな）
        - amusing（楽しませる・くすっとする）
        - entertaining（飽きさせない・エンタメ的）
        - intriguing（引き込まれる・好奇心をそそる）

        それ以外の通常の質問には、日本語で簡潔に答えてください。\
        短く答えられるものは短く、説明が要るものだけ必要な範囲で補足します。
        """

    static var model: String {
        get {
            guard let stored = defaults.string(forKey: modelKey) else { return defaultModel }
            guard
                stored == defaultModel || stored == appleFoundationModelID
                    || stored == grokModelID
            else {
                // Ollama版など旧バックエンドの選択値はMLX版へ自動移行する。
                defaults.set(defaultModel, forKey: modelKey)
                return defaultModel
            }
            return stored
        }
        set { defaults.set(newValue, forKey: modelKey) }
    }

    static var systemPrompt: String {
        get { defaults.string(forKey: systemKey) ?? defaultSystemPrompt }
        set { defaults.set(newValue, forKey: systemKey) }
    }

    /// ⇧⇧でパレットを開いたとき、対応OSではローカル音声入力を自動開始する。
    static var voiceInputEnabled: Bool {
        get {
            guard defaults.object(forKey: voiceInputKey) != nil else { return true }
            return defaults.bool(forKey: voiceInputKey)
        }
        set { defaults.set(newValue, forKey: voiceInputKey) }
    }
}
