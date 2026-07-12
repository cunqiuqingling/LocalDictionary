import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: DictionaryPanelController?
    private var hotKey: GlobalHotKey?
    private let selectionReader = AccessibilitySelectionReader()
    private let clipboardFallback = ClipboardSelectionFallback()
    private let permissionPrompter = AccessibilityPermissionPrompter()
    private let noteStore = ObsidianNoteStore()
    private let notePicker = ObsidianNotePicker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        configureStatusItem()
        configureDictionary()
        hotKey = GlobalHotKey { [weak self] in self?.handleGlobalHotKey() }
    }

    private func handleGlobalHotKey() {
        guard let panelController else { return }
        if panelController.isVisible {
            panelController.hide()
            return
        }

        // Capture the source application before showing or activating the panel.
        let sourceApplication = NSWorkspace.shared.frontmostApplication
        debugLog("frontmost_application=\(sourceApplication != nil)")

        switch selectionReader.readSelection(from: sourceApplication) {
        case .text(let rawText):
            handleCapturedText(rawText, with: panelController)
        case .permissionDenied:
            debugLog("accessibility_trusted=false")
            panelController.show()
            DispatchQueue.main.async { [permissionPrompter] in
                permissionPrompter.showIfNeeded()
            }
        case .secureInput:
            debugLog("secure_input=true selection_read=false")
            panelController.show()
        case .noSelection, .unavailable:
            debugLog("ax_selection_nonempty=false clipboard_fallback=true")
            handleClipboardFallback(from: sourceApplication, with: panelController)
        }
    }

    private func handleClipboardFallback(from application: NSRunningApplication?,
                                         with panelController: DictionaryPanelController) {
        switch clipboardFallback.readSelection(from: application) {
        case .text(let rawText):
            debugLog("clipboard_fallback_nonempty=true characters=\(rawText.count)")
            handleCapturedText(rawText, with: panelController)
        case .noText:
            debugLog("clipboard_fallback_nonempty=false")
            panelController.show()
        case .unsafeSnapshot:
            debugLog("clipboard_fallback_aborted=unsafe_snapshot")
            panelController.show()
        case .restoreFailed:
            debugLog("clipboard_fallback_restore=false")
            panelController.show()
        case .secureInput:
            debugLog("secure_input=true clipboard_fallback=false")
            panelController.show()
        case .unavailable:
            debugLog("clipboard_fallback_unavailable=true")
            panelController.show()
        }
    }

    private func handleCapturedText(_ rawText: String,
                                    with panelController: DictionaryPanelController) {
        switch SelectedTextCleaner.clean(rawText) {
        case .value(let query):
            debugLog("selection_nonempty=true characters=\(query.count)")
            let found = panelController.showAndLookup(query)
            debugLog("lookup_found=\(found)")
        case .tooLong(let count):
            debugLog("selection_nonempty=true characters=\(count) too_long=true")
            panelController.showSelectionTooLongMessage()
        case .empty:
            debugLog("selection_nonempty=false")
            panelController.show()
        }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        NSLog("LocalDictionary AX: %@", message())
        #endif
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationItem = NSMenuItem(title: "本地词典", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "本地词典")
        let about = NSMenuItem(title: "关于本地词典",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = NSApp
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏本地词典",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        hide.target = NSApp
        applicationMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "隐藏其他应用",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        applicationMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: "显示全部",
                                 action: #selector(NSApplication.unhideAllApplications(_:)),
                                 keyEquivalent: "")
        showAll.target = NSApp
        applicationMenu.addItem(showAll)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出本地词典",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(responderMenuItem(title: "撤销", action: "undo:", key: "z"))
        let redo = responderMenuItem(title: "重做", action: "redo:", key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem(title: "剪切", action: "cut:", key: "x"))
        editMenu.addItem(responderMenuItem(title: "复制", action: "copy:", key: "c"))
        editMenu.addItem(responderMenuItem(title: "粘贴", action: "paste:", key: "v"))
        editMenu.addItem(responderMenuItem(title: "全选", action: "selectAll:", key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func responderMenuItem(title: String, action: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
        item.target = nil
        return item
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "本地词典")
            button.toolTip = "本地词典"
        }
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示词典", action: #selector(showDictionary), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let selectNote = NSMenuItem(title: "选择 Obsidian 笔记…",
                                    action: #selector(selectObsidianNote),
                                    keyEquivalent: "")
        selectNote.target = self
        menu.addItem(selectNote)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func configureDictionary() {
        do {
            let config = try AppConfig.load()
            let core = DictionaryCoreBridge(dictionaryPath: config.primaryDictionary,
                                            indexPath: config.indexPath)
            panelController = DictionaryPanelController(core: core,
                                                        noteStore: noteStore,
                                                        notePicker: notePicker)
        } catch {
            let core = DictionaryCoreBridge(dictionaryPath: "", indexPath: "")
            panelController = DictionaryPanelController(core: core,
                                                        noteStore: noteStore,
                                                        notePicker: notePicker)
        }
    }

    @objc private func showDictionary() { panelController?.show() }
    @objc private func selectObsidianNote() {
        guard notePicker.chooseTarget(for: noteStore) else { return }
        panelController?.targetNoteDidChange()
    }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}
