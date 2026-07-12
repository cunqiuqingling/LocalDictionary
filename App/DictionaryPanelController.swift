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
    private let noteStore: ObsidianNoteStore
    private let notePicker: ObsidianNotePicker
    private let searchField = NSSearchField()
    private let starButton = NSButton()
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private var currentEntry: StructuredDictionaryEntry?
    private var feedbackPopover: NSPopover?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var isShowingNoteMenu = false
    private var animating = false

    init(core: DictionaryCoreBridge,
         noteStore: ObsidianNoteStore,
         notePicker: ObsidianNotePicker) {
        self.core = core
        self.noteStore = noteStore
        self.notePicker = notePicker
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
        setCurrentEntry(nil)
        displayText("所选文本超过 100 个字符，请缩短选择或手动输入。")
        show()
    }

    func targetNoteDidChange() {
        refreshStarState()
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

        starButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "保存词条")
        starButton.target = self
        starButton.action = #selector(showNoteMenu)
        starButton.isBordered = false
        starButton.bezelStyle = .accessoryBarAction
        starButton.toolTip = "当前没有可以保存的词条"
        starButton.setAccessibilityLabel("保存到 Obsidian 笔记")
        starButton.isEnabled = false

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
            if self?.notePicker.isChoosing == true || self?.isShowingNoteMenu == true {
                return event
            }
            if let attachedSheet = self?.window?.attachedSheet, event.window === attachedSheet {
                return event
            }
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
        guard !query.isEmpty else {
            setCurrentEntry(nil)
            return
        }
        _ = lookup(query)
    }

    private func lookup(_ query: String) -> Bool {
        setCurrentEntry(nil)
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
                let parsed = formatted.structuredEntry
                let entry = StructuredDictionaryEntry(
                    headword: parsed.headword,
                    phonetics: parsed.phonetics,
                    partsOfSpeech: parsed.partsOfSpeech,
                    definitions: parsed.definitions,
                    examples: parsed.examples,
                    source: parsed.source
                )
                if entry.isValid { setCurrentEntry(entry) }
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

    @objc private func showNoteMenu() {
        guard let entry = currentEntry, entry.isValid, !isShowingNoteMenu else { return }
        let menu = NSMenu(title: "保存词条")
        if let target = noteStore.targetURL {
            let filename = abbreviatedFilename(target.lastPathComponent)
            let addCurrent = NSMenuItem(title: "加入当前笔记：\(filename)",
                                        action: #selector(addToCurrentNote),
                                        keyEquivalent: "")
            addCurrent.target = self
            addCurrent.toolTip = target.path
            addCurrent.state = (try? noteStore.contains(headword: entry.headword)) == true
                ? .on : .off
            menu.addItem(addCurrent)
            menu.addItem(.separator())
        }

        let chooseExisting = NSMenuItem(title: "选择已有 Markdown 笔记…",
                                        action: #selector(selectExistingNote),
                                        keyEquivalent: "")
        chooseExisting.target = self
        menu.addItem(chooseExisting)

        let createNew = NSMenuItem(title: "新建 Markdown 笔记…",
                                   action: #selector(createNewNote),
                                   keyEquivalent: "")
        createNew.target = self
        menu.addItem(createNew)

        isShowingNoteMenu = true
        defer { isShowingNoteMenu = false }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: starButton.bounds.minX, y: starButton.bounds.minY - 4),
                   in: starButton)
    }

    @objc private func addToCurrentNote() {
        guard let entry = currentEntry, entry.isValid else { return }
        save(entry)
    }

    @objc private func selectExistingNote() {
        selectExistingForCurrentEntry()
    }

    @objc private func createNewNote() {
        guard let entry = currentEntry, entry.isValid else { return }
        let directory = noteStore.targetURL?.deletingLastPathComponent()
        guard let url = notePicker.chooseNewNote(initialDirectory: directory) else { return }
        save(entry, to: url, creatingIfNeeded: true)
    }

    private func selectExistingForCurrentEntry() {
        guard let entry = currentEntry, entry.isValid else { return }
        let directory = noteStore.targetURL?.deletingLastPathComponent()
        guard let url = notePicker.chooseExistingNote(initialDirectory: directory) else { return }
        save(entry, to: url, creatingIfNeeded: false)
    }

    private func save(_ entry: StructuredDictionaryEntry) {
        do {
            _ = try noteStore.save(entry)
            refreshStarState()
            showFeedback("已保存")
        } catch {
            refreshStarState()
            presentSaveError(error, entry: entry)
        }
    }

    private func save(_ entry: StructuredDictionaryEntry,
                      to url: URL,
                      creatingIfNeeded: Bool) {
        do {
            if creatingIfNeeded {
                _ = try noteStore.createOrSave(entry, at: url)
            } else {
                _ = try noteStore.save(entry, to: url)
            }
            try noteStore.rememberTarget(url)
            refreshStarState()
            showFeedback("已保存")
        } catch {
            refreshStarState()
            presentSaveError(error, entry: entry)
        }
    }

    private func setCurrentEntry(_ entry: StructuredDictionaryEntry?) {
        currentEntry = entry
        refreshStarState()
    }

    private func refreshStarState() {
        guard let entry = currentEntry, entry.isValid else {
            starButton.isEnabled = false
            setStarFilled(false)
            starButton.toolTip = "当前没有可以保存的词条"
            return
        }

        starButton.isEnabled = true
        let isSaved = (try? noteStore.contains(headword: entry.headword)) == true
        setStarFilled(isSaved)
        starButton.toolTip = isSaved ? "已保存到 Obsidian 笔记" : "保存到 Obsidian 笔记"
    }

    private func setStarFilled(_ filled: Bool) {
        let symbol = filled ? "star.fill" : "star"
        starButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "保存词条")
        starButton.setAccessibilityValue(filled ? "已保存" : "未保存")
    }

    private func abbreviatedFilename(_ filename: String) -> String {
        let maximumCharacters = 44
        guard filename.count > maximumCharacters else { return filename }
        let suffix = filename.hasSuffix(".md") ? ".md" : ""
        let prefixCount = maximumCharacters - suffix.count - 1
        return String(filename.prefix(prefixCount)) + "…" + suffix
    }

    private func showFeedback(_ message: String) {
        feedbackPopover?.close()
        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 0, y: 0, width: 92, height: 34)

        let controller = NSViewController()
        controller.view = label
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = label.frame.size
        popover.contentViewController = controller
        feedbackPopover = popover
        popover.show(relativeTo: starButton.bounds, of: starButton, preferredEdge: .maxY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak popover] in
            popover?.close()
            if self?.feedbackPopover === popover { self?.feedbackPopover = nil }
        }
    }

    private func presentSaveError(_ error: Error, entry: StructuredDictionaryEntry) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存词条"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "选择已有笔记")
        alert.addButton(withTitle: "取消")

        guard let panel = window else { return }
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  self.currentEntry == entry else { return }
            self.selectExistingForCurrentEntry()
        }
    }

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
