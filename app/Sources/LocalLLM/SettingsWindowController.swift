import AppKit

/// 管理画面。MLXモデルの選択と、システムプロンプト編集を行う。
/// モデルは選択した瞬間に即反映し、システムプロンプトは「保存」で永続化する。
/// 変更は UserDefaults に保存され、再起動後も保持される。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let winWidth: CGFloat = 560
    private let winHeight: CGFloat = 460

    private var window: NSWindow?
    private var modelPopup: NSPopUpButton!
    private var promptView: NSTextView!
    private var statusLabel: NSTextField!
    private var saveButton: NSButton!
    private var voiceCheckbox: NSButton!

    /// プログラム的なポップアップ選択中は true。モデル選択アクションの誤発火を防ぐ。
    private var isPopulatingModels = false

    /// 保存メッセージの自動クリア用トークン。保存ごとにインクリメントする。
    private var statusToken = 0

    func show() {
        if window == nil { build() }
        guard let window = window else { return }

        loadIntoUI()
        refreshModels()

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: winHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalLLM 設定"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = window.contentView!

        // モデル選択
        let modelLabel = makeLabel("モデル", frame: NSRect(x: 20, y: winHeight - 52, width: 120, height: 20))
        content.addSubview(modelLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 20, y: winHeight - 84, width: 388, height: 26), pullsDown: false)
        popup.target = self
        popup.action = #selector(modelSelectionChanged)
        content.addSubview(popup)
        self.modelPopup = popup

        let refresh = NSButton(
            title: "一覧を再取得",
            target: self,
            action: #selector(refreshTapped)
        )
        refresh.frame = NSRect(x: 418, y: winHeight - 85, width: 122, height: 28)
        refresh.bezelStyle = .rounded
        refresh.toolTip = "利用可能なMLXモデルを再確認"
        content.addSubview(refresh)

        let voice = NSButton(
            checkboxWithTitle: "⇧⇧で開いたらローカル音声入力を開始",
            target: self,
            action: #selector(voiceSettingChanged)
        )
        voice.frame = NSRect(x: 20, y: winHeight - 122, width: 420, height: 22)
        voice.font = .systemFont(ofSize: 13)
        if #available(macOS 26.0, *) {
            voice.toolTip = "Apple SpeechAnalyzerでオンデバイス転写します"
        } else {
            voice.isEnabled = false
            voice.toolTip = "音声入力にはmacOS 26以降が必要です"
        }
        content.addSubview(voice)
        self.voiceCheckbox = voice

        // システムプロンプト
        let promptLabel = makeLabel(
            "システムプロンプト",
            frame: NSRect(x: 20, y: winHeight - 158, width: 300, height: 20)
        )
        content.addSubview(promptLabel)

        let (scroll, textView) = TextViewFactory.make(
            frame: NSRect(x: 20, y: 70, width: 520, height: winHeight - 234),
            editable: true,
            fontSize: 13,
            bordered: true
        )
        textView.isRichText = false
        textView.delegate = self
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        self.promptView = textView

        // ステータス（保存通知など）
        let status = makeLabel("", frame: NSRect(x: 20, y: 24, width: 360, height: 20))
        status.textColor = .secondaryLabelColor
        content.addSubview(status)
        self.statusLabel = status

        // 保存ボタン
        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.frame = NSRect(x: winWidth - 130, y: 18, width: 110, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)
        self.saveButton = save

        self.window = window
    }

    private func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    // MARK: - Data

    private func loadIntoUI() {
        promptView?.string = Settings.systemPrompt
        voiceCheckbox?.state = Settings.voiceInputEnabled ? .on : .off
        statusLabel?.stringValue = ""
        // 一覧取得前でも現在値を選択肢として出しておく。
        isPopulatingModels = true
        ensureItem(Settings.model)
        selectModel(Settings.model)
        isPopulatingModels = false
        updateDirtyState()
    }

    /// システムプロンプトの未保存差分を判定し、保存ボタンとステータス表示を更新する。
    private func updateDirtyState() {
        let hasUnsaved = (promptView?.string ?? "") != Settings.systemPrompt
        saveButton?.isEnabled = hasUnsaved
        if hasUnsaved {
            statusToken &+= 1
            statusLabel?.stringValue = "未保存の変更があります"
        }
    }

    private func ensureItem(_ modelID: String) {
        guard let popup = modelPopup else { return }
        if item(for: modelID) == nil {
            popup.menu?.addItem(makeModelItem(modelID))
        }
    }

    private func makeModelItem(_ modelID: String) -> NSMenuItem {
        let item = NSMenuItem(title: displayTitle(for: modelID), action: nil, keyEquivalent: "")
        item.representedObject = modelID
        if modelID == Settings.appleFoundationModelID {
            item.isEnabled = FoundationModelsClient.isAvailable
            if !item.isEnabled {
                item.toolTip = FoundationModelsClient.unavailableReason
            }
        } else if modelID == Settings.grokModelID {
            item.isEnabled = GrokClient.isAvailable
            if !item.isEnabled {
                item.toolTip = "Grok Build CLIのインストールとgrok loginが必要です"
            }
        }
        return item
    }

    private func displayTitle(for modelID: String) -> String {
        if modelID == Settings.appleFoundationModelID {
            if let reason = FoundationModelsClient.unavailableReason {
                return "\(Settings.appleFoundationModelName)（利用不可: \(reason)）"
            }
            return Settings.appleFoundationModelName
        }
        if modelID == Settings.grokModelID {
            return GrokClient.isAvailable
                ? Settings.grokModelName
                : "\(Settings.grokModelName)（CLIなし）"
        }
        return modelID == Settings.defaultModel ? "Agents-A1 4B（MLX 4bit・推奨）" : modelID
    }

    private func item(for modelID: String) -> NSMenuItem? {
        modelPopup?.itemArray.first { ($0.representedObject as? String) == modelID }
    }

    private func selectModel(_ modelID: String) {
        guard let item = item(for: modelID) else { return }
        modelPopup?.select(item)
    }

    private func refreshModels() {
        statusLabel?.stringValue = "モデル一覧を取得中…"
        Task {
            do {
                let models = try await LLMClient.availableModels()
                await MainActor.run { self.populate(models) }
            } catch {
                await MainActor.run {
                    self.populate([])
                    self.statusLabel?.stringValue = "MLXモデルの確認に失敗しました"
                }
            }
        }
    }

    private func populate(_ models: [String]) {
        guard let popup = modelPopup else { return }
        isPopulatingModels = true
        defer { isPopulatingModels = false }
        let current = Settings.model
        popup.removeAllItems()
        var list = models
        if current != Settings.appleFoundationModelID, current != Settings.grokModelID,
            !list.contains(current)
        {
            list.insert(current, at: 0)
        }
        popup.menu?.addItem(makeModelItem(Settings.appleFoundationModelID))
        popup.menu?.addItem(makeModelItem(Settings.grokModelID))
        popup.menu?.addItem(.separator())
        list.forEach { popup.menu?.addItem(makeModelItem($0)) }
        selectModel(current)
        statusLabel?.stringValue = "\(models.count) 件のMLXモデルが利用可能"
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        refreshModels()
    }

    @objc private func voiceSettingChanged() {
        Settings.voiceInputEnabled = voiceCheckbox?.state == .on
        statusToken &+= 1
        statusLabel?.stringValue = "音声入力設定を変更しました"
    }

    /// ポップアップの選択が変わった瞬間に呼ばれ、モデルを即時反映する。
    @objc private func modelSelectionChanged() {
        guard !isPopulatingModels else { return }
        guard let item = modelPopup?.selectedItem else { return }
        // 利用不可の項目（例: Apple Foundation が使えない環境）は反映しない。
        guard item.isEnabled else { return }
        guard let modelID = item.representedObject as? String else { return }
        Settings.model = modelID
        statusToken &+= 1
        statusLabel?.stringValue = "モデルを変更しました（次の質問から反映）"
    }

    @objc private func saveTapped() {
        Settings.systemPrompt = promptView?.string ?? Settings.defaultSystemPrompt
        statusLabel?.stringValue = "保存しました"
        updateDirtyState()
        statusToken &+= 1
        let token = statusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.statusToken == token else { return }
            self.statusLabel?.stringValue = ""
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        let hasUnsaved = (promptView?.string ?? "") != Settings.systemPrompt
        if !hasUnsaved {
            statusLabel?.stringValue = ""
        }
        updateDirtyState()
    }
}
