import AppKit

/// スラッシュコマンド1件。
@MainActor
struct SlashCommand {
    let name: String  // 例: "/settings"
    let subtitle: String  // 例: "設定を開く"
    let action: () -> Void
}

/// 候補1行の表示。標準の選択色を使い、キーボードとクリックの両方に対応する。
@MainActor
final class CommandRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var selected = false
    var onPress: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        addSubview(nameLabel)
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ cmd: SlashCommand) {
        nameLabel.stringValue = cmd.name
        subtitleLabel.stringValue = cmd.subtitle
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateSelectionAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateSelectionAppearance() {
        layer?.backgroundColor =
            selected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        nameLabel.frame = NSRect(x: 12, y: bounds.height / 2 - 9, width: 104, height: 18)
        let sx: CGFloat = 122
        subtitleLabel.frame = NSRect(x: sx, y: bounds.height / 2 - 8, width: bounds.width - sx - 12, height: 16)
    }
}

/// 入力欄の下に出る候補ドロップダウン。親ウィンドウの子ウィンドウとして表示する。
@MainActor
final class CommandPalette {
    private let width: CGFloat
    private let rowHeight: CGFloat = 38
    private let vpad: CGFloat = 6
    private let gap: CGFloat = 6
    private let onChoose: (SlashCommand) -> Void

    private var panel: NSPanel?
    private var background: NSView?
    private var rows: [CommandRowView] = []
    private(set) var items: [SlashCommand] = []
    private var selectedIndex = 0

    init(width: CGFloat, onChoose: @escaping (SlashCommand) -> Void) {
        self.width = width
        self.onChoose = onChoose
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    var selectedCommand: SlashCommand? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        highlight()
    }

    /// 候補を更新して表示する。`anchorBelow` は入力欄のスクリーン座標。
    func update(items: [SlashCommand], anchorBelow inputScreenRect: NSRect, parent: NSWindow) {
        guard !items.isEmpty else { hide(); return }
        ensurePanel()
        guard let panel = panel else { return }

        self.items = items
        selectedIndex = max(0, min(selectedIndex, items.count - 1))
        rebuildRows()

        let height = CGFloat(items.count) * rowHeight + vpad * 2
        let x = inputScreenRect.minX
        let y = inputScreenRect.minY - gap - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        layoutRows(height: height)

        if panel.parent == nil {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        highlight()
    }

    func hide() {
        guard let panel = panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        selectedIndex = 0
    }

    // MARK: - private

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        // 親パネルと同じく全 Space・フルスクリーン上に追従させる。
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let content = NSView(frame: .zero)
        content.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular
            glass.cornerRadius = 12
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            p.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            content.frame = effect.bounds
            effect.addSubview(content)
            p.contentView = effect
        }

        panel = p
        background = content
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, cmd in
            let row = CommandRowView(frame: .zero)
            row.configure(cmd)
            row.onPress = { [weak self] in
                guard let self, self.items.indices.contains(index) else { return }
                self.selectedIndex = index
                self.onChoose(self.items[index])
            }
            background?.addSubview(row)
            return row
        }
    }

    private func layoutRows(height: CGFloat) {
        for (i, row) in rows.enumerated() {
            // 先頭を上に並べる。
            let y = height - vpad - CGFloat(i + 1) * rowHeight
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: rowHeight)
        }
    }

    private func highlight() {
        for (i, row) in rows.enumerated() {
            row.setSelected(i == selectedIndex)
        }
    }
}
