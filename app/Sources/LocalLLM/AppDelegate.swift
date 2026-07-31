import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!
    private let hotKey = ShiftDoubleTapMonitor()
    private lazy var settingsController = SettingsWindowController()
    private lazy var historyController = HistoryWindowController()
    private lazy var askController: AskWindowController = {
        let controller = AskWindowController()
        controller.onOpenSettings = { [weak self] in self?.settingsController.show() }
        controller.onOpenHistory = { [weak self] in self?.historyController.show() }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        requestAccessibilityIfNeeded()

        hotKey.onDoubleTap = { [weak self] in
            self?.askController.toggle()
        }
        hotKey.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await MLXModelManager.shared.unloadImmediately()
        }
    }

    /// LSUIElement（メニューバー常駐・Dock 無し）では既定の mainMenu が無く、
    /// Cmd+C/V/X/A/Z など標準編集ショートカットが入力中のテキストフィールドに
    /// 配送されない。mainMenu に編集メニューを載せると、各項目の keyEquivalent が
    /// レスポンダチェーン（target=nil）経由でファーストレスポンダに届くようになる。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "編集")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setupStatusItem()
            }
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            NSLog("[LocalLLM] statusItem.button is nil")
            return
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LocalLLM")?
            .withSymbolConfiguration(config)
        {
            img.isTemplate = true
            button.image = img
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.title = ""
            // 既定の variableLength は左右に余白が入るため、画像幅ぴったりに詰める。
            statusItem.length = img.size.width
        } else {
            button.image = nil
            button.title = "✨"
            button.imagePosition = .noImage
            statusItem.length = 26
        }
        button.toolTip = "LocalLLM（⇧⇧で質問）"
        statusItem.isVisible = true

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "質問する（⇧⇧）", action: #selector(toggleAsk), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "実行履歴…", action: #selector(openHistory), keyEquivalent: "y"))
        menu.addItem(NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(
            title: "ログイン時に起動",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "アクセシビリティ設定を開く",
                action: #selector(openAccessibility),
                keyEquivalent: ""
            ))
        menu.addItem(
            NSMenuItem(
                title: "LocalLLM を終了",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ))

        menu.delegate = self
        statusItem.menu = menu
        updateLaunchAtLoginState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginState()
    }

    @objc private func toggleAsk() {
        askController.toggle()
    }

    @objc private func openHistory() {
        historyController.show()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    private func updateLaunchAtLoginState() {
        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
                NSLog("[LocalLLM] login item unregistered")
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
                NSLog("[LocalLLM] login item registered")
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            @unknown default:
                break
            }
        } catch {
            NSLog("[LocalLLM] login item toggle failed: \(error.localizedDescription)")
        }
        updateLaunchAtLoginState()
    }

    @objc private func openAccessibility() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        // kAXTrustedCheckOptionPrompt はCの共有可変グローバルとしてimportされるため、
        // 公開されているCFString値を直接使い、Swift 6の並行性警告を避ける。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
