import AppKit

/// 実行履歴のビューア。左に一覧、右に選択した項目の詳細（プロンプトと回答）を表示する。
@MainActor
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let winWidth: CGFloat = 780
    private let winHeight: CGFloat = 480

    private var window: NSWindow?
    private var table: NSTableView!
    private var detail: NSTextView!
    private var countLabel: NSTextField!

    private var entries: [HistoryEntry] = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    func show() {
        if window == nil { build() }
        guard let window = window else { return }

        reload()

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: winHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "実行履歴"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 360)

        let content = window.contentView!

        // 上部ツールバー
        let reloadButton = NSButton(title: "更新", target: self, action: #selector(reloadTapped))
        reloadButton.frame = NSRect(x: 20, y: winHeight - 44, width: 80, height: 28)
        reloadButton.bezelStyle = .rounded
        reloadButton.autoresizingMask = [.minYMargin]
        content.addSubview(reloadButton)

        let clearButton = NSButton(title: "履歴を消去", target: self, action: #selector(clearTapped))
        clearButton.frame = NSRect(x: 108, y: winHeight - 44, width: 110, height: 28)
        clearButton.bezelStyle = .rounded
        clearButton.autoresizingMask = [.minYMargin]
        content.addSubview(clearButton)

        let count = NSTextField(labelWithString: "")
        count.frame = NSRect(x: 230, y: winHeight - 40, width: 300, height: 20)
        count.textColor = .secondaryLabelColor
        count.autoresizingMask = [.minYMargin, .width]
        content.addSubview(count)
        self.countLabel = count

        let listTop = winHeight - 56
        let listHeight = listTop - 20

        // 左: 一覧テーブル
        let tableScroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 300, height: listHeight))
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.autoresizingMask = [.height]

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 40
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = 280
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableScroll.documentView = tableView
        content.addSubview(tableScroll)
        self.table = tableView

        // 右: 詳細
        let (detailScroll, detailView) = TextViewFactory.make(
            frame: NSRect(x: 336, y: 20, width: winWidth - 356, height: listHeight),
            editable: false,
            fontSize: 13,
            bordered: true
        )
        detailScroll.autoresizingMask = [.width, .height]
        content.addSubview(detailScroll)
        self.detail = detailView

        self.window = window
    }

    private func reload() {
        HistoryStore.shared.load()
        entries = HistoryStore.shared.entries
        table?.reloadData()
        countLabel?.stringValue = "\(entries.count) 件"
        detail?.string = entries.isEmpty ? "履歴はまだありません。" : "左の一覧から選択してください。"
    }

    @objc private func reloadTapped() {
        reload()
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = "履歴をすべて消去しますか？"
        alert.informativeText = "この操作は取り消せません。"
        alert.addButton(withTitle: "消去")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.clear()
            reload()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                field.usesSingleLineMode = false
                field.maximumNumberOfLines = 2
                return field
            }()

        let entry = entries[row]
        let time = Self.dateFormatter.string(from: entry.date)
        cell.stringValue = "\(time)\n\(entry.prompt)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        let e = entries[row]
        let time = Self.dateFormatter.string(from: e.date)
        detail.string = """
            \(time)   [\(e.model)]

            ▼ 質問
            \(e.prompt)

            ▼ 回答
            \(e.response)
            """
    }
}
