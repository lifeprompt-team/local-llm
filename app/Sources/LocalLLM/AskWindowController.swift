import AppKit

/// borderless でも key になれるパネル。
final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// ⇧⇧ で出るフローティング入力窓。入力 → Enter で送信し、回答をストリーミング表示する。
@MainActor
final class AskWindowController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let width: CGFloat = 440
    private let pad: CGFloat = 16
    private let inputVerticalMargin: CGFloat = 10.5
    private let inputHorizontalMargin: CGFloat = 14
    private let accessorySize: CGFloat = 18
    private let accessoryGap: CGFloat = 10
    private let outputHeight: CGFloat = 300
    private var inputHeight: CGFloat = 0

    private var compactHeight: CGFloat { inputHeight + inputVerticalMargin * 2 }
    private var expandedHeight: CGFloat {
        inputVerticalMargin + inputHeight + pad + outputHeight + pad
    }

    private var panel: AskPanel?
    private var contentHolder: NSView!
    private var backgroundGradient: CAGradientLayer!
    private var accentBorder: AccentBorderView!
    private var aiIcon: AIIconView!
    private var input: NSTextField!
    private var outputSeparator: NSBox!
    private var reasoningHeader: NSButton!
    private var reasoningScroll: NSScrollView!
    private var reasoningView: NSTextView!
    private var answerScroll: NSScrollView!
    private var answerView: NSTextView!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var cornerRadius: CGFloat { compactHeight / 2 }
    private let headerHeight: CGFloat = 22
    private let reasoningPaneHeight: CGFloat = 110
    private var task: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    /// 現在の生成だけがUIと履歴を更新できるようにする識別子。
    private var activeRequestID: UUID?
    /// 遅延した前面化処理が、閉じた後のパネルを再表示しないための世代番号。
    private var presentationGeneration: UInt = 0
    /// 直近に Space が切り替わった時刻。Space 切り替えに伴う resignKey で
    /// パネルを閉じてしまわないよう、この直後の resignKey は無視する。
    private var lastSpaceChangeAt: Date = .distantPast
    private var receivedFirstContent = false
    private var receivedFirstReasoning = false
    /// 思考セクションが開いているか（ヘッダクリックで開閉）。
    private var reasoningExpanded = false
    /// 出力領域（回答・思考）を表示中か（compact では false）。
    private var outputShown = false
    /// 履歴に保存するのは本文(content)のみ。reasoning は含めない。
    private var contentBuffer = ""
    /// パネルを開いている間だけ保持する会話履歴。閉じて開き直すと新規会話になる。
    private var conversation: [ChatMessage] = []

    /// スラッシュコマンド起動時に親（AppDelegate）が画面を開くためのコールバック。
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?

    private lazy var palette = CommandPalette(width: width - pad * 2) { [weak self] command in
        self?.execute(command)
    }
    private lazy var commands: [SlashCommand] = [
        SlashCommand(name: "/settings", subtitle: "設定（モデル・プロンプト）を開く") { [weak self] in
            self?.onOpenSettings?()
        },
        SlashCommand(name: "/history", subtitle: "実行履歴を開く") { [weak self] in
            self?.onOpenHistory?()
        },
        SlashCommand(name: "/quit", subtitle: "LocalLLM を終了") {
            NSApp.terminate(nil)
        },
    ]

    func toggle() {
        if let panel = panel, panel.isVisible {
            // 前面化に失敗して背後に残ったパネルは、もう一度の ⇧⇧ で回収する。
            // key のときだけ通常のトグルとして閉じる。
            if panel.isKeyWindow {
                hide()
            } else {
                bringToFront(panel)
            }
        } else {
            show()
        }
    }

    func show() {
        if panel == nil { build() }
        guard let panel = panel else { return }

        hideLoading()
        palette.hide()
        receivedFirstContent = false
        receivedFirstReasoning = false
        reasoningExpanded = false
        contentBuffer = ""
        conversation = []
        input.isEnabled = true
        input.stringValue = ""
        setInputPlaceholder("ローカルAIに聞く")
        answerView.string = ""
        reasoningView.string = ""
        collapse()

        position(panel, height: compactHeight)
        bringToFront(panel)
        preloadSelectedModel()
    }

    func hide() {
        presentationGeneration &+= 1
        activeRequestID = nil
        task?.cancel()
        task = nil
        preloadTask?.cancel()
        preloadTask = nil
        hideLoading()
        palette.hide()
        panel?.orderOut(nil)
    }

    /// LSUIElement の非アクティブ状態やフルスクリーン Space からでも確実に前面へ出す。
    /// `activate` は非同期になり得るので、現在と次のメインループの両方で key を要求する。
    private func bringToFront(_ panel: AskPanel) {
        presentationGeneration &+= 1
        let generation = presentationGeneration

        // makeKeyAndOrderFront だけでは、所有アプリが非アクティブな瞬間に他アプリの
        // ウィンドウより後ろへ残ることがある。先に Window Server 側へ前面配置を要求する。
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        panel.makeFirstResponder(input)

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard self.presentationGeneration == generation, panel.isVisible else { return }
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.makeFirstResponder(self.input)
        }
    }

    /// ⇧⇧で窓を開いた時点からモデルロードを始め、入力中の待ち時間に重ねる。
    private func preloadSelectedModel() {
        preloadTask?.cancel()
        preloadTask = nil

        let model = Settings.model
        guard model != Settings.appleFoundationModelID else {
            return
        }

        preloadTask = Task {
            do {
                let startedAt = Date()
                try await LLMClient.preload(model: model)
                let elapsed = Date().timeIntervalSince(startedAt)
                NSLog("[LocalLLM] model preload succeeded: \(model) (\(String(format: "%.1f", elapsed))s)")
            } catch {
                guard !Self.isCancellation(error) else { return }
                NSLog("[LocalLLM] model preload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UI construction

    private func build() {
        // 入力欄の自然な高さを先に確定し、パネル高をその実寸＋上下マージンから決める。
        let field = NSTextField(frame: .zero)
        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.textColor = NSColor(
            srgbRed: 0.90,
            green: 0.82,
            blue: 0.76,
            alpha: 1
        )
        field.placeholderAttributedString = makeInputPlaceholder("ローカルAIに聞く")
        field.controlSize = .large
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.autoresizingMask = []
        inputHeight = ceil(field.intrinsicContentSize.height)

        let panel = AskPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: compactHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // `.floating` より上の一時 UI レベルを使い、独自フルスクリーン実装や
        // Electron 系アプリの補助ウィンドウにも隠されにくくする。
        panel.level = .popUpMenu
        // Spotlight / Siri と同じく、どの Space でも・フルスクリーンアプリの上でも
        // 同じパネルを出す。.canJoinAllSpaces で全 Space に追従、.stationary で
        // Mission Control 中も動かさず、.fullScreenAuxiliary でフルスクリーン上にも出す。
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        // すべての UI を載せるコンテンツ層。
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: width, height: compactHeight))
        holder.wantsLayer = true
        holder.autoresizingMask = [.width, .height]
        holder.layer?.cornerRadius = cornerRadius
        holder.layer?.masksToBounds = true

        // 参照デザインに合わせた、わずかに透ける暖色〜寒色のダークグラデーション。
        let background = CAGradientLayer()
        background.colors = [
            NSColor(srgbRed: 0.29, green: 0.16, blue: 0.09, alpha: 0.93).cgColor,
            NSColor(srgbRed: 0.22, green: 0.11, blue: 0.20, alpha: 0.93).cgColor,
            NSColor(srgbRed: 0.10, green: 0.15, blue: 0.25, alpha: 0.93).cgColor,
        ]
        background.locations = [0, 0.54, 1]
        background.startPoint = CGPoint(x: 0, y: 0.5)
        background.endPoint = CGPoint(x: 1, y: 0.5)
        background.cornerRadius = cornerRadius
        holder.layer?.insertSublayer(background, at: 0)
        self.backgroundGradient = background
        self.contentHolder = holder

        // Glass/Visual Effectを挟むと、その素材色が7%部分を埋めて背後が見えなくなる。
        // 透明なパネルへ直接載せ、グラデーション自身のalphaで透過量を決める。
        panel.contentView = holder

        let icon = AIIconView(frame: .zero)
        holder.addSubview(icon)
        self.aiIcon = icon

        field.frame = NSRect(
            x: inputHorizontalMargin + accessorySize + accessoryGap,
            y: compactHeight - inputVerticalMargin - inputHeight,
            width: width - inputHorizontalMargin * 2 - accessorySize - accessoryGap,
            height: inputHeight
        )
        holder.addSubview(field)
        self.input = field

        // compact時は隠し、回答を展開した時だけ標準セパレータで領域を区切る。
        let separator = NSBox(frame: .zero)
        separator.boxType = .separator
        separator.isHidden = true
        holder.addSubview(separator)
        self.outputSeparator = separator

        let innerW = width - pad * 2

        // 思考セクションの開閉ヘッダ（ディスクロージャ三角＋「思考」）。
        let header = NSButton(title: " 思考", target: self, action: #selector(toggleReasoning))
        header.isBordered = false
        header.bezelStyle = .inline
        header.imagePosition = .imageLeft
        header.imageScaling = .scaleProportionallyDown
        header.alignment = .left
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.contentTintColor = .secondaryLabelColor
        header.autoresizingMask = []
        header.isHidden = true
        holder.addSubview(header)
        self.reasoningHeader = header

        // 思考テキスト（折りたたみ対象）。
        let (rScroll, rView) = TextViewFactory.make(
            frame: NSRect(x: pad, y: pad, width: innerW, height: reasoningPaneHeight),
            editable: false,
            fontSize: 13,
            bordered: false
        )
        rView.isRichText = true
        rScroll.autoresizingMask = []
        rScroll.isHidden = true
        holder.addSubview(rScroll)
        self.reasoningScroll = rScroll
        self.reasoningView = rView

        // 回答テキスト（常に見える位置）。
        let (aScroll, aView) = TextViewFactory.make(
            frame: NSRect(x: pad, y: pad, width: innerW, height: outputHeight),
            editable: false,
            fontSize: 15,
            bordered: false
        )
        aView.isRichText = true
        aScroll.autoresizingMask = []
        aScroll.isHidden = true
        holder.addSubview(aScroll)
        self.answerScroll = aScroll
        self.answerView = aView

        updateReasoningChevron()

        // ローディング（scroll の上に重ねる）
        let indicator = NSProgressIndicator(frame: .zero)
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        indicator.isHidden = true
        holder.addSubview(indicator)
        self.spinner = indicator

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        holder.addSubview(status)
        self.statusLabel = status

        // 外周の多色ボーダーは全コンテンツより前面に置く。クリック判定は透過する。
        let border = AccentBorderView(frame: holder.bounds)
        border.cornerRadius = cornerRadius
        border.borderWidth = 1
        holder.addSubview(border, positioned: .above, relativeTo: nil)
        self.accentBorder = border

        // Space 切り替え（三本指スワイプ等）を検知して、直後の resignKey を無視する。
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        self.panel = panel
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func activeSpaceDidChange() {
        lastSpaceChangeAt = Date()
    }

    private func showLoading(_ text: String) {
        statusLabel.stringValue = text
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.isHidden = false
    }

    /// パネルの高さに合わせて各サブビューを明示的に配置する（autoresizing には頼らない）。
    /// 出力領域は下端(pad)〜入力の下(pad)。思考が有効なら上にヘッダ＋（展開時）思考ペインを
    /// 置き、回答ペインは常に残り全部を占めて下端に接地する（＝常に枠内に見える）。
    private func layoutSubviews(for height: CGFloat) {
        guard input != nil else { return }
        let full = NSRect(x: 0, y: 0, width: width, height: height)
        contentHolder?.frame = full
        backgroundGradient?.frame = full
        backgroundGradient?.cornerRadius = cornerRadius
        accentBorder?.frame = full

        let innerW = width - pad * 2
        let inputY = height - inputVerticalMargin - inputHeight
        let accessoryY = inputY + (inputHeight - accessorySize) / 2
        aiIcon.frame = NSRect(
            x: inputHorizontalMargin,
            y: accessoryY,
            width: accessorySize,
            height: accessorySize
        )
        let inputX = inputHorizontalMargin + accessorySize + accessoryGap
        let inputMaxX = width - inputHorizontalMargin
        input.frame = NSRect(
            x: inputX,
            y: inputY,
            width: inputMaxX - inputX,
            height: inputHeight
        )

        let regionBottom = pad
        let regionTop = height - inputVerticalMargin - inputHeight - pad  // 入力の下端 - pad
        let gap: CGFloat = 4
        outputSeparator.frame = NSRect(x: pad, y: regionTop + pad / 2, width: innerW, height: 1)

        // ローディング表示は領域上部に重ねる（トークン到着前のみ可視）。
        let sy = regionTop - 22
        spinner.frame = NSRect(x: pad, y: sy, width: 18, height: 18)
        statusLabel.frame = NSRect(x: pad + 26, y: sy - 2, width: innerW - 26, height: 20)

        if receivedFirstReasoning {
            let headerY = regionTop - headerHeight
            reasoningHeader.frame = NSRect(x: pad, y: headerY, width: innerW, height: headerHeight)

            let answerTop: CGFloat
            if reasoningExpanded {
                let reasoningY = headerY - gap - reasoningPaneHeight
                reasoningScroll.frame = NSRect(x: pad, y: reasoningY, width: innerW, height: reasoningPaneHeight)
                answerTop = reasoningY - gap
            } else {
                answerTop = headerY - gap
            }
            answerScroll.frame = NSRect(
                x: pad, y: regionBottom, width: innerW, height: max(0, answerTop - regionBottom)
            )
        } else {
            // 思考なし: 回答が出力領域全体を占める（従来どおり）。
            answerScroll.frame = NSRect(
                x: pad, y: regionBottom, width: innerW, height: max(0, regionTop - regionBottom)
            )
        }
    }

    /// 現在の状態に応じて出力サブビューの表示/非表示を更新する。
    private func refreshOutputViews() {
        guard answerScroll != nil else { return }
        outputSeparator.isHidden = !outputShown
        answerScroll.isHidden = !outputShown
        reasoningHeader.isHidden = !(outputShown && receivedFirstReasoning)
        reasoningScroll.isHidden = !(outputShown && receivedFirstReasoning && reasoningExpanded)
    }

    private func updateReasoningChevron() {
        guard reasoningHeader != nil else { return }
        let name = reasoningExpanded ? "chevron.down" : "chevron.right"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            image.isTemplate = true
            reasoningHeader.image = image
        }
    }

    @objc private func toggleReasoning() {
        guard receivedFirstReasoning else { return }
        reasoningExpanded.toggle()
        updateReasoningChevron()
        refreshOutputViews()
        let h = panel?.frame.height ?? expandedHeight
        layoutSubviews(for: h)
    }

    private func hideLoading() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.isHidden = true
    }

    private func makeInputPlaceholder(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor(
                    srgbRed: 0.86,
                    green: 0.77,
                    blue: 0.70,
                    alpha: 0.92
                ),
            ]
        )
    }

    private func setInputPlaceholder(_ text: String) {
        input.placeholderAttributedString = makeInputPlaceholder(text)
    }

    private func position(_ panel: NSPanel, height: CGFloat) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // メニューバー下の可視領域の左上に、上・左 20px の余白で固定。展開は下方向に伸びる。
        let margin: CGFloat = 20
        let x = screen.minX + margin
        let y = screen.maxY - margin - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        layoutSubviews(for: height)
    }

    private func collapse() {
        outputShown = false
        refreshOutputViews()
        if let panel = panel {
            position(panel, height: compactHeight)
        }
    }

    private func expand() {
        outputShown = true
        refreshOutputViews()
        if let panel = panel {
            position(panel, height: expandedHeight)
        }
    }

    // MARK: - Submit / streaming

    private func submit() {
        let prompt = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let requestMessages = conversation + [.user(prompt)]
        input.stringValue = ""
        input.isEnabled = false
        palette.hide()

        receivedFirstContent = false
        receivedFirstReasoning = false
        reasoningExpanded = false
        contentBuffer = ""
        answerView.string = ""
        reasoningView.string = ""
        updateReasoningChevron()
        expand()
        showLoading("生成中…")
        task?.cancel()

        let selectedModel = Settings.model
        let selectedSystemPrompt = Settings.systemPrompt
        let pendingPreload = preloadTask
        let historyModelName =
            selectedModel == Settings.appleFoundationModelID
            ? Settings.appleFoundationModelName
            : selectedModel
        let requestID = UUID()
        activeRequestID = requestID

        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Enterが先読み完了より早かった場合だけ、同じロードの完了を待つ。
                await pendingPreload?.value
                try Task.checkCancellation()
                guard self.activeRequestID == requestID else { return }

                let onEvent: @MainActor @Sendable (StreamEvent) -> Void = { [weak self] event in
                    guard let self, self.activeRequestID == requestID else { return }
                    self.handle(event)
                }

                if selectedModel == Settings.appleFoundationModelID {
                    try await FoundationModelsClient.stream(
                        messages: requestMessages,
                        systemPrompt: selectedSystemPrompt,
                        onEvent: onEvent
                    )
                } else {
                    try await LLMClient.stream(
                        model: selectedModel,
                        systemPrompt: selectedSystemPrompt,
                        messages: requestMessages,
                        onEvent: onEvent
                    )
                }

                try Task.checkCancellation()
                guard self.activeRequestID == requestID else { return }

                self.hideLoading()
                self.task = nil
                self.activeRequestID = nil
                // 履歴には本文(content)のみ保存し、reasoning は含めない。
                let answer = self.contentBuffer
                if !answer.isEmpty {
                    self.conversation = requestMessages + [.assistant(answer)]
                    HistoryStore.shared.add(prompt: prompt, response: answer, model: historyModelName)
                }
                self.input.isEnabled = true
                self.setInputPlaceholder("続けて聞く")
                self.panel?.makeFirstResponder(self.input)
            } catch {
                // 置換・非表示済みの古いリクエストはUIへ一切触れさせない。
                guard self.activeRequestID == requestID else { return }

                if Self.isCancellation(error) {
                    self.hideLoading()
                    self.task = nil
                    self.activeRequestID = nil
                    self.input.isEnabled = true
                    return
                }

                let message: String
                if selectedModel != Settings.appleFoundationModelID,
                    (error as NSError).domain == NSURLErrorDomain
                {
                    message = "MLXモデルをロードできませんでした。\nネットワーク接続と空き容量を確認して、もう一度お試しください。"
                } else {
                    message = "エラー: \(error.localizedDescription)"
                }
                self.hideLoading()
                self.task = nil
                self.activeRequestID = nil
                self.answerView.string = message
                self.answerView.scrollToEndOfDocument(nil)
                self.input.isEnabled = true
                self.input.stringValue = prompt
                self.panel?.makeFirstResponder(self.input)
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .reasoning(let text):
            // 最初の reasoning でスピナーを消し、思考ヘッダ＋思考ペインを開いて進捗を見せる。
            if !receivedFirstReasoning {
                receivedFirstReasoning = true
                reasoningExpanded = true
                hideLoading()
                updateReasoningChevron()
                refreshOutputViews()
                relayout()
            }
            append(to: reasoningView, text, attributes: reasoningAttributes)
        case .content(let text):
            if !receivedFirstContent {
                receivedFirstContent = true
                hideLoading()
                // reasoning があった場合は、最初の content で思考を自動的に折りたたむ。
                if receivedFirstReasoning {
                    reasoningExpanded = false
                    updateReasoningChevron()
                }
                refreshOutputViews()
                relayout()
            }
            contentBuffer += text
            append(to: answerView, text, attributes: contentAttributes)
        }
    }

    private func relayout() {
        let h = panel?.frame.height ?? (outputShown ? expandedHeight : compactHeight)
        layoutSubviews(for: h)
    }

    private var reasoningAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }

    private var contentAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    private func append(to textView: NSTextView, _ text: String, attributes: [NSAttributedString.Key: Any]) {
        guard let storage = textView.textStorage else {
            textView.string += text
            textView.scrollToEndOfDocument(nil)
            return
        }
        storage.append(NSAttributedString(string: text, attributes: attributes))
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updatePalette()
    }

    private func updatePalette() {
        guard let panel = panel else { return }
        let text = input.stringValue
        guard text.hasPrefix("/") else {
            palette.hide()
            return
        }
        let query = text.lowercased()
        let matches = commands.filter { $0.name.lowercased().hasPrefix(query) }
        if matches.isEmpty {
            palette.hide()
            return
        }
        let anchorInWindow = NSRect(
            x: pad,
            y: input.frame.minY,
            width: width - pad * 2,
            height: input.frame.height
        )
        palette.update(items: matches, anchorBelow: panel.convertToScreen(anchorInWindow), parent: panel)
    }

    private func executeSelectedCommand() {
        guard let command = palette.selectedCommand else { return }
        execute(command)
    }

    private func execute(_ command: SlashCommand) {
        palette.hide()
        input.stringValue = ""
        command.action()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 候補表示中は矢印キー / Enter / Esc をパレット操作に割り当てる。
        if palette.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                palette.moveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                palette.moveSelection(1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                #selector(NSResponder.insertTab(_:)):
                // コマンド確定。本文は送信しない。
                executeSelectedCommand()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                palette.hide()
                return true
            default:
                return false
            }
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    // MARK: - NSWindowDelegate

    // 別アプリ等をクリックして key を失ったら閉じる（Spotlight 風）。
    // ただし生成中は閉じない（回答を取り逃さないため）。
    // また、Space 切り替え（三本指スワイプ）や Mission Control に伴う resignKey では
    // 閉じない。パネルは全 Space に追従するので、置いていかれず出続ける。
    func windowDidResignKey(_ notification: Notification) {
        guard task == nil else { return }

        // resignKey と Space 変更通知は前後し得るため、少し遅らせて判定する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            guard self.task == nil else { return }
            guard let panel = self.panel, panel.isVisible else { return }
            // Space 切り替え直後の resignKey なら閉じない。
            if Date().timeIntervalSince(self.lastSpaceChangeAt) < 0.5 { return }
            // すでに key に戻っている（同一 Space 内に戻ってきた等）なら閉じない。
            if panel.isKeyWindow { return }
            self.hide()
        }
    }
}
