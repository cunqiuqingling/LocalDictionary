import AppKit

final class DictionaryPanel: NSPanel {
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }
}

final class DictionaryPanelController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let core: DictionaryCoreBridge
    private let entryFormatter = OxfordEntryFormatter()
    private let searchField = NSSearchField()
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var animating = false

    init(core: DictionaryCoreBridge) {
        self.core = core
        let standardScrollView = NSTextView.scrollableTextView()
        guard let standardTextView = standardScrollView.documentView as? NSTextView else {
            fatalError("AppKit did not create an NSTextView document view")
        }
        scrollView = standardScrollView
        textView = standardTextView
        let panel = DictionaryPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                                    styleMask: [.titled, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: true)
        super.init(window: panel)
        configure(panel)
        installEventMonitors()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }

    var isVisible: Bool { window?.isVisible == true }

    func toggle() {
        isVisible ? hide() : show()
    }

    @discardableResult
    func showAndLookup(_ query: String) -> Bool {
        searchField.stringValue = query
        let found = lookup(query)
        show()
        return found
    }

    func showSelectionTooLongMessage() {
        displayText("所选文本超过 100 个字符，请缩短选择或手动输入。")
        show()
    }

    func show() {
        guard let panel = window as? DictionaryPanel, !animating else { return }
        animating = true
        let finalFrame = shownFrame(for: activeScreen(), panelSize: panel.frame.size)
        var startFrame = finalFrame
        startFrame.origin.x += 24
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.animating = false
        }
    }

    func hide() {
        guard let panel = window as? DictionaryPanel, panel.isVisible, !animating else { return }
        animating = true
        var hiddenFrame = panel.frame
        hiddenFrame.origin.x += 24
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            self?.animating = false
        }
    }

    private func configure(_ panel: DictionaryPanel) {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.escapeHandler = { [weak self] in self?.hide() }

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        panel.contentView = material

        searchField.placeholderString = "输入英文单词"
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(performSearch)

        let starButton = NSButton(image: NSImage(systemSymbolName: "star", accessibilityDescription: "收藏")!,
                                  target: self,
                                  action: #selector(starPlaceholder))
        starButton.isBordered = false
        starButton.bezelStyle = .accessoryBarAction
        starButton.toolTip = "收藏功能将在后续阶段启用"
        starButton.setAccessibilityLabel("收藏（占位）")

        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")!,
                                   target: self,
                                   action: #selector(closePanel))
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.setAccessibilityLabel("关闭")

        let header = NSStackView(views: [searchField, starButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        starButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        closeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 22, height: 12)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.menu = editingContextMenu(includeModificationCommands: false)
        displayText(core.isReady ? "输入英文单词并按回车查询" : core.lastError)
        textView.setAccessibilityLabel("词典释义")

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        material.addSubview(header)
        material.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: material.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -14),
            header.heightAnchor.constraint(equalToConstant: 30),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -8)
        ])
    }

    private func installEventMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in DispatchQueue.main.async { self?.hide() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            if let panel = self?.window, panel.isVisible, event.window !== panel {
                self?.hide()
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.isVisible == true {
                self?.hide()
                return nil
            }
            return event
        }
    }

    @objc private func performSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        _ = lookup(query)
    }

    private func lookup(_ query: String) -> Bool {
        let result = core.lookup(query)
        if let error = result["error"] as? String, !error.isEmpty {
            displayText("查询失败：\(error)")
            return false
        } else if result["found"] as? Bool == true,
                  let html = result["html"] as? String {
            let formatted = entryFormatter.formatHTML(html)
            if formatted.attributedString.length == 0 {
                displayText("词条内容为空")
            } else {
                displayAttributedText(formatted.attributedString)
            }
            textView.scrollToBeginningOfDocument(nil)
            return true
        } else {
            displayText("未找到词条：\(query)")
            return false
        }
    }

    private func displayText(_ value: String) {
        precondition(Thread.isMainThread)
        textView.string = value
        let range = NSRange(location: 0, length: textView.string.utf16.count)
        textView.textStorage?.setAttributes([
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ], range: range)
        textView.needsDisplay = true
    }

    private func displayAttributedText(_ value: NSAttributedString) {
        precondition(Thread.isMainThread)
        textView.textStorage?.setAttributedString(value)
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        if let fieldEditor = searchField.currentEditor() as? NSTextView {
            fieldEditor.allowsUndo = true
            fieldEditor.menu = editingContextMenu(includeModificationCommands: true)
        }
    }

    private func editingContextMenu(includeModificationCommands: Bool) -> NSMenu {
        let menu = NSMenu(title: "编辑")
        if includeModificationCommands {
            menu.addItem(responderMenuItem(title: "剪切", action: "cut:"))
        }
        menu.addItem(responderMenuItem(title: "复制", action: "copy:"))
        if includeModificationCommands {
            menu.addItem(responderMenuItem(title: "粘贴", action: "paste:"))
        }
        menu.addItem(.separator())
        menu.addItem(responderMenuItem(title: "全选", action: "selectAll:"))
        return menu
    }

    private func responderMenuItem(title: String, action: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: "")
        item.target = nil
        return item
    }

    @objc private func starPlaceholder() {}
    @objc private func closePanel() { hide() }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func shownFrame(for screen: NSScreen, panelSize: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let height = min(panelSize.height, visible.height - 32)
        return NSRect(x: visible.maxX - panelSize.width - 16,
                      y: visible.midY - height / 2,
                      width: panelSize.width,
                      height: height)
    }
}
