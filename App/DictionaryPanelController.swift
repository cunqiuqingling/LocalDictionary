import AppKit
import ObjectiveC

struct SupplementalDictionaryRuntime {
    let id: DictionarySourceID
    let displayName: String
    let priority: Int
    let core: DictionaryCoreBridge
}

final class DictionaryPanel: NSPanel {
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }
}

final class DictionaryPanelController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let oxfordCore: DictionaryCoreBridge
    private let supplementalDictionaries: [SupplementalDictionaryRuntime]
    private let entryFormatter = OxfordEntryFormatter()
    private let century21Formatter = Century21EntryFormatter()
    private let newOxfordFormatter = NewOxfordEntryFormatter()
    private let medicalFormatter = MedicalEntryFormatter()
    private let affixRootFormatter = AffixRootEntryFormatter()
    private let noteStore: ObsidianNoteStore
    private let notePicker: ObsidianNotePicker
    private let aiService: AIExplanationService
    private let openAISettings: () -> Void
    private let aiEntryFormatter = AIEntryFormatter()
    private let aiSentenceFormatter = AISentenceEntryFormatter()
    private let aiMarkdownFormatter = AIExplanationMarkdownFormatter()
    private let localGlossaryFormatter = LocalSentenceGlossaryFormatter()
    private let sentenceMarkdownFormatter = SentenceAnalysisMarkdownFormatter()
    private let searchField = NSSearchField()
    private let starButton = NSButton()
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let aiFooter = NSStackView()
    private let aiStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let aiActionButton = NSButton()
    private let aiSettingsButton = NSButton()
    private let aiIncludeCheckbox = NSButton(
        checkboxWithTitle: "收藏时加入 AI 内容", target: nil, action: nil
    )
    private var aiFooterHeightConstraint: NSLayoutConstraint?
    private var currentEntry: StructuredDictionaryEntry?
    private var currentQuery = ""
    private var currentIntent: QueryIntent = .word
    private var localResultContent: NSAttributedString?
    private var localResultHasChinese = false
    private var aiAction: AIAction = .none
    private var aiTask: Task<Void, Never>?
    private var localGlossaryTask: Task<Void, Never>?
    private var currentAIPresentation: AIExplanationPresentation?
    private var currentSentencePresentation: AISentenceAnalysisPresentation?
    private var currentLocalGlossary: LocalSentenceGlossary?
    private var currentSentenceStatus: String?
    private var aiSectionCharacterLocation: Int?
    private var queryGeneration = AIQueryGenerationGate()
    private var feedbackPopover: NSPopover?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var isShowingNoteMenu = false
    private var animating = false
    private var reportedUnavailableDictionaryIDs: Set<String> = []

    private lazy var localGlossaryService = LocalSentenceGlossaryService(
        sources: makeLocalGlossarySources()
    )

    private enum AIAction {
        case none
        case configure
        case explain(domain: String)
        case analyzeSentence
        case cancelSentence
    }

    private enum NoteSaveContent {
        case vocabulary(VocabularyNoteSaveContent)
        case sentence(SentenceNoteSaveContent)

        var identity: String {
            switch self {
            case .vocabulary(let content):
                return content.headword.precomposedStringWithCanonicalMapping.lowercased()
            case .sentence(let content):
                return SentenceNoteSaveContent.normalizedSentence(content.sourceText)
            }
        }
    }

    init(core: DictionaryCoreBridge,
         supplementalDictionaries: [SupplementalDictionaryRuntime] = [],
         noteStore: ObsidianNoteStore,
         notePicker: ObsidianNotePicker,
         aiService: AIExplanationService,
         openAISettings: @escaping () -> Void) {
        oxfordCore = core
        self.supplementalDictionaries = supplementalDictionaries.sorted {
            $0.priority < $1.priority
        }
        self.noteStore = noteStore
        self.notePicker = notePicker
        self.aiService = aiService
        self.openAISettings = openAISettings
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
        aiTask?.cancel()
        localGlossaryTask?.cancel()
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
        let found = processQuery(query)
        show()
        return found
    }

    func showSelectionTooLongMessage() {
        resetAIState(query: "", intent: .textTooLong)
        setCurrentEntry(nil)
        displayText("选择内容较长，请缩短为一个句子后再分析。")
        show()
    }

    func targetNoteDidChange() {
        refreshStarState()
    }

    func aiConfigurationDidChange() {
        if currentIntent == .sentence, currentSentencePresentation == nil {
            configureSentenceAction(for: currentQuery)
        } else if currentIntent != .sentence {
            configureAIAction(hasLocalResult: currentEntry?.isValid == true,
                              hasChinese: localResultHasChinese)
        }
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
        aiTask?.cancel()
        aiTask = nil
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        _ = queryGeneration.beginQuery()
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
        aiIncludeCheckbox.controlSize = .small
        aiIncludeCheckbox.font = .systemFont(ofSize: 11)
        aiIncludeCheckbox.target = self
        aiIncludeCheckbox.action = #selector(aiInclusionDidChange)
        aiIncludeCheckbox.toolTip = "勾选后，点击星号会把当前已生成的 AI 解释一并写入 Markdown 笔记。"
        aiIncludeCheckbox.setAccessibilityLabel("收藏时加入 AI 内容")
        aiIncludeCheckbox.isHidden = true
        aiIncludeCheckbox.autoresizingMask = [.minXMargin]
        textView.addSubview(aiIncludeCheckbox)
        let hasReadyDictionary = oxfordCore.isReady || supplementalDictionaries.contains {
            $0.core.isReady
        }
        displayText(hasReadyDictionary ? "输入英文单词并按回车查询" : oxfordCore.lastError)
        textView.setAccessibilityLabel("词典释义")

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        aiStatusLabel.font = .systemFont(ofSize: 11)
        aiStatusLabel.textColor = .secondaryLabelColor
        aiStatusLabel.maximumNumberOfLines = 2
        aiActionButton.bezelStyle = .rounded
        aiActionButton.controlSize = .small
        aiActionButton.target = self
        aiActionButton.action = #selector(performAIAction)
        aiSettingsButton.title = "打开 AI 设置…"
        aiSettingsButton.bezelStyle = .inline
        aiSettingsButton.isBordered = false
        aiSettingsButton.controlSize = .small
        aiSettingsButton.target = self
        aiSettingsButton.action = #selector(openAISettingsWindow)
        let aiButtons = NSStackView(views: [aiActionButton, aiSettingsButton])
        aiButtons.orientation = .horizontal
        aiButtons.spacing = 8
        aiButtons.alignment = .centerY
        aiFooter.addArrangedSubview(aiStatusLabel)
        aiFooter.addArrangedSubview(aiButtons)
        aiFooter.orientation = .vertical
        aiFooter.alignment = .leading
        aiFooter.spacing = 4
        aiFooter.translatesAutoresizingMaskIntoConstraints = false
        aiFooter.isHidden = true

        material.addSubview(header)
        material.addSubview(scrollView)
        material.addSubview(aiFooter)
        let footerHeight = aiFooter.heightAnchor.constraint(equalToConstant: 0)
        aiFooterHeightConstraint = footerHeight
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: material.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -14),
            header.heightAnchor.constraint(equalToConstant: 30),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: aiFooter.topAnchor, constant: -6),
            aiFooter.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 22),
            aiFooter.trailingAnchor.constraint(lessThanOrEqualTo: material.trailingAnchor, constant: -22),
            aiFooter.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -8),
            footerHeight
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
        guard !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resetAIState(query: "", intent: .textTooLong)
            setCurrentEntry(nil)
            displayText("")
            return
        }
        _ = processQuery(searchField.stringValue)
    }

    private func processQuery(_ source: String) -> Bool {
        let classification = QueryIntentClassifier.classify(source)
        switch classification.intent {
        case .textTooLong:
            resetAIState(query: classification.normalizedText, intent: .textTooLong)
            setCurrentEntry(nil)
            searchField.stringValue = classification.normalizedText
            if classification.rejectionReason == .empty {
                displayText("")
            } else {
                displayText("选择内容较长，请缩短为一个句子后再分析。")
            }
            return false
        case .word, .phrase:
            switch SelectedTextCleaner.clean(classification.normalizedText) {
            case .value(let dictionaryQuery):
                searchField.stringValue = dictionaryQuery
                return lookup(dictionaryQuery, intent: classification.intent)
            case .empty:
                resetAIState(query: "", intent: .textTooLong)
                setCurrentEntry(nil)
                displayText("")
                return false
            case .tooLong:
                resetAIState(query: classification.normalizedText, intent: .textTooLong)
                setCurrentEntry(nil)
                displayText("选择内容较长，请缩短为一个句子后再分析。")
                return false
            }
        case .sentence:
            let sentence = classification.normalizedText
            if classification.shouldAttemptLocalLookupFirst,
               case .value(let dictionaryQuery) = SelectedTextCleaner.clean(sentence),
               lookup(dictionaryQuery, intent: .phrase) {
                searchField.stringValue = dictionaryQuery
                return true
            }
            searchField.stringValue = sentence
            prepareSentenceMode(sentence)
            return false
        }
    }

    private func lookup(_ query: String, intent: QueryIntent) -> Bool {
        resetAIState(query: query, intent: intent)
        setCurrentEntry(nil)
        var attributedSections: [NSAttributedString] = []
        var structuredSources: [StructuredDictionarySource] = []
        var headword = ""
        var failures: [(id: String, name: String)] = []

        let oxfordResult = synchronizedLookup(core: oxfordCore, query: query)
        if let error = oxfordResult["error"] as? String, !error.isEmpty {
            failures.append((DictionarySourceID.oxfordOALD8.rawValue, "牛津高阶 8"))
        } else if oxfordResult["found"] as? Bool == true,
                  let html = oxfordResult["html"] as? String {
            let formatted = entryFormatter.formatHTML(html)
            if formatted.attributedString.length > 0 {
                attributedSections.append(formatted.attributedString)
                let parsed = formatted.structuredEntry
                if headword.isEmpty { headword = parsed.headword }
                structuredSources.append(StructuredDictionarySource(
                    phonetics: parsed.phonetics,
                    partsOfSpeech: parsed.partsOfSpeech,
                    definitions: parsed.definitions,
                    examples: parsed.examples,
                    source: "牛津高阶 8",
                    semanticEntry: structuredSemanticEntry(from: parsed.semanticEntry)
                ))
            }
        }

        for dictionary in supplementalDictionaries {
            let lookupResult = synchronizedLookup(core: dictionary.core, query: query)
            if let error = lookupResult["error"] as? String, !error.isEmpty {
                failures.append((dictionary.id.rawValue, dictionary.displayName))
                continue
            }
            guard lookupResult["found"] as? Bool == true,
                  let html = lookupResult["html"] as? String else { continue }
            let matchedHeadword = (lookupResult["matchedHeadword"] as? String) ?? query
            let formatted = formatSupplementalHTML(html,
                                                   matchedHeadword: matchedHeadword,
                                                   sourceID: dictionary.id)
            guard formatted.attributedString.length > 0 else { continue }
            attributedSections.append(formatted.attributedString)
            let parsed = formatted.structuredEntry
            if headword.isEmpty {
                headword = parsed.headword.isEmpty ? matchedHeadword : parsed.headword
            }
            structuredSources.append(StructuredDictionarySource(
                phonetics: parsed.phonetics,
                partsOfSpeech: parsed.partsOfSpeech,
                definitions: parsed.definitions,
                examples: parsed.examples,
                source: dictionary.displayName,
                partOfSpeechSections: dictionary.id == .century21
                    ? structuredPartOfSpeechSections(from: parsed)
                    : nil,
                semanticEntry: dictionary.id == .newOxford
                    ? structuredSemanticEntry(from: parsed.semanticEntry)
                    : nil
            ))
        }

        let newlyUnavailable = failures.filter {
            !reportedUnavailableDictionaryIDs.contains($0.id)
        }
        reportedUnavailableDictionaryIDs.formUnion(newlyUnavailable.map { $0.id })

        guard !attributedSections.isEmpty else {
            var message = "未找到词条：\(query)"
            if !newlyUnavailable.isEmpty {
                message += "\n部分词典暂不可用：" + newlyUnavailable.map { $0.name }.joined(separator: "、")
            }
            displayText(message)
            localResultContent = textView.attributedString()
            configureAIAction(hasLocalResult: false, hasChinese: false)
            return false
        }

        let combined = NSMutableAttributedString(string: "")
        for section in attributedSections {
            if combined.length > 0 {
                combined.append(NSAttributedString(string: "\n\n"))
            }
            combined.append(section)
        }
        if !newlyUnavailable.isEmpty {
            appendAvailabilityNotice(newlyUnavailable.map { $0.name }, to: combined)
        }
        displayAttributedText(combined)
        let entry = StructuredDictionaryEntry(headword: headword.isEmpty ? query : headword,
                                              sources: structuredSources)
        if entry.isValid { setCurrentEntry(entry) }
        localResultContent = combined.copy() as? NSAttributedString
        localResultHasChinese = containsChineseContent(entry)
        configureAIAction(hasLocalResult: true, hasChinese: localResultHasChinese)
        textView.scrollToBeginningOfDocument(nil)
        return true
    }

    private func resetAIState(query: String, intent: QueryIntent) {
        aiTask?.cancel()
        aiTask = nil
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        _ = queryGeneration.beginQuery()
        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentIntent = intent
        localResultContent = nil
        localResultHasChinese = false
        aiAction = .none
        currentAIPresentation = nil
        currentSentencePresentation = nil
        currentLocalGlossary = nil
        currentSentenceStatus = nil
        aiSectionCharacterLocation = nil
        aiIncludeCheckbox.state = .off
        aiIncludeCheckbox.isHidden = true
        updateAIFooter(visible: false)
    }

    private func configureAIAction(hasLocalResult: Bool, hasChinese: Bool) {
        guard !currentQuery.isEmpty else {
            updateAIFooter(visible: false)
            return
        }
        let query = currentQuery
        let generation = queryGeneration.generation
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            guard let self else { return }
            let availability = await aiService.availability()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentQuery == query,
                      self.currentIntent != .sentence,
                      self.queryGeneration.accepts(generation) else { return }
                if !hasLocalResult && (!availability.isEnabled || !availability.isConfigured) {
                    self.aiAction = .configure
                    self.aiStatusLabel.stringValue = "未配置可用的 AI 服务"
                    self.aiActionButton.title = "配置 AI 服务…"
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = true
                    self.updateAIFooter(visible: true)
                    return
                }
                guard availability.isEnabled && availability.isConfigured else {
                    self.aiAction = .none
                    self.updateAIFooter(visible: false)
                    return
                }
                self.aiAction = .explain(domain: self.suggestedDomain())
                self.aiStatusLabel.stringValue = ""
                self.aiActionButton.isHidden = false
                if !hasLocalResult {
                    self.aiActionButton.title = "AI 双语解释"
                } else if !hasChinese {
                    self.aiActionButton.title = "AI 中文解读"
                } else {
                    self.aiActionButton.title = "AI 双语补充"
                }
                self.aiActionButton.isEnabled = true
                self.aiSettingsButton.isHidden = true
                self.updateAIFooter(visible: true)
            }
        }
    }

    @objc private func performAIAction() {
        switch aiAction {
        case .none:
            return
        case .configure:
            openAISettings()
        case .explain(let domain):
            requestAIExplanation(domain: domain)
        case .analyzeSentence:
            requestSentenceAnalysis()
        case .cancelSentence:
            cancelSentenceAnalysis()
        }
    }

    @objc private func openAISettingsWindow() {
        openAISettings()
    }

    private func requestAIExplanation(domain: String) {
        guard !currentQuery.isEmpty else { return }
        let query = currentQuery
        let generation = queryGeneration.generation
        aiActionButton.isEnabled = false
        aiActionButton.title = "正在生成…"
        aiSettingsButton.isHidden = true
        aiStatusLabel.stringValue = "正在请求所配置的第三方 AI 服务"
        updateAIFooter(visible: true)
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let presentation = try await aiService.explain(query: query, domain: domain)
                guard !Task.isCancelled else { return }
                let formatted = aiEntryFormatter.format(presentation)
                await MainActor.run {
                    guard self.currentQuery == query,
                          self.currentIntent != .sentence,
                          self.queryGeneration.accepts(generation) else { return }
                    let output = NSMutableAttributedString()
                    if let local = self.localResultContent,
                       self.currentEntry?.isValid == true {
                        output.append(local)
                        output.append(NSAttributedString(string: "\n\n"))
                    }
                    self.aiSectionCharacterLocation = output.length
                    output.append(formatted)
                    self.displayAttributedText(output)
                    self.currentAIPresentation = presentation
                    self.aiIncludeCheckbox.state = .off
                    self.aiIncludeCheckbox.isHidden = false
                    self.positionAIIncludeCheckbox()
                    self.refreshStarState()
                    self.textView.scrollToBeginningOfDocument(nil)
                    self.aiAction = .none
                    self.aiStatusLabel.stringValue = presentation.fromCache
                        ? "已显示本机缓存的 AI 结果" : "AI 结果已生成"
                    self.aiActionButton.isHidden = true
                    self.aiSettingsButton.isHidden = true
                    self.updateAIFooter(visible: true, compact: true)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentQuery == query,
                          self.currentIntent != .sentence,
                          self.queryGeneration.accepts(generation) else { return }
                    self.aiAction = .explain(domain: domain)
                    self.aiStatusLabel.stringValue = error.localizedDescription
                    self.aiActionButton.title = "重试"
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = false
                    self.updateAIFooter(visible: true)
                }
            }
        }
    }

    private func prepareSentenceMode(_ sentence: String) {
        resetAIState(query: sentence, intent: .sentence)
        setCurrentEntry(nil)
        renderSentenceContent()
        refreshStarState()
        textView.scrollToBeginningOfDocument(nil)
        startLocalGlossaryAnalysis(for: sentence)
        configureSentenceAction(for: sentence)
    }

    private func startLocalGlossaryAnalysis(for sentence: String) {
        let generation = queryGeneration.generation
        localGlossaryTask?.cancel()
        localGlossaryTask = Task { [weak self] in
            guard let self else { return }
            let glossary = await localGlossaryService.analyze(sentence: sentence)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentIntent == .sentence,
                      self.currentQuery == sentence,
                      self.currentSentencePresentation == nil,
                      self.queryGeneration.accepts(generation) else { return }
                self.currentLocalGlossary = glossary
                self.renderSentenceContent()
                self.refreshStarState()
            }
        }
    }

    private func renderSentenceContent() {
        guard currentIntent == .sentence else { return }
        if let presentation = currentSentencePresentation {
            displayAttributedText(aiSentenceFormatter.format(presentation))
            return
        }
        let output = NSMutableAttributedString(
            attributedString: aiSentenceFormatter.placeholder(sourceText: currentQuery,
                                                               status: currentSentenceStatus)
        )
        if let glossary = currentLocalGlossary {
            output.append(NSAttributedString(string: "\n"))
            output.append(localGlossaryFormatter.format(glossary))
        }
        displayAttributedText(output)
    }

    private func configureSentenceAction(for sentence: String) {
        guard currentIntent == .sentence, !sentence.isEmpty,
              currentSentencePresentation == nil else { return }
        let generation = queryGeneration.generation
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            guard let self else { return }
            let availability = await aiService.availability()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentIntent == .sentence,
                      self.currentQuery == sentence,
                      self.queryGeneration.accepts(generation) else { return }
                guard availability.isEnabled, availability.isConfigured else {
                    self.aiAction = .configure
                    self.currentSentenceStatus = "未配置可用的 AI 服务"
                    self.aiStatusLabel.stringValue = "未配置可用的 AI 服务"
                    self.aiActionButton.title = "配置 AI 服务…"
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = true
                    self.updateAIFooter(visible: true)
                    self.renderSentenceContent()
                    return
                }
                if availability.automaticSentenceAnalysisEnabled {
                    self.requestSentenceAnalysis(expectedGeneration: generation)
                } else {
                    self.aiAction = .analyzeSentence
                    self.currentSentenceStatus = "可按需请求 AI；本地词语参考不会联网"
                    self.aiStatusLabel.stringValue = "完整句子不会自动发送"
                    self.aiActionButton.title = "AI 翻译与句子解析"
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = true
                    self.updateAIFooter(visible: true)
                    self.renderSentenceContent()
                }
            }
        }
    }

    private func requestSentenceAnalysis(expectedGeneration: UInt64? = nil) {
        guard currentIntent == .sentence, !currentQuery.isEmpty else { return }
        let sentence = currentQuery
        let generation = expectedGeneration ?? queryGeneration.generation
        guard queryGeneration.accepts(generation) else { return }
        aiTask?.cancel()
        aiAction = .cancelSentence
        currentSentenceStatus = "正在分析句子…"
        aiStatusLabel.stringValue = "正在分析句子…"
        aiActionButton.title = "取消"
        aiActionButton.isHidden = false
        aiActionButton.isEnabled = true
        aiSettingsButton.isHidden = true
        updateAIFooter(visible: true)
        renderSentenceContent()
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let presentation = try await aiService.analyzeSentence(sentence)
                guard !Task.isCancelled else { return }
                let formatted = aiSentenceFormatter.format(presentation)
                await MainActor.run {
                    guard self.currentIntent == .sentence,
                          self.currentQuery == sentence,
                          self.queryGeneration.accepts(generation) else { return }
                    self.currentSentencePresentation = presentation
                    self.currentLocalGlossary = nil
                    self.currentSentenceStatus = nil
                    self.localGlossaryTask?.cancel()
                    self.localGlossaryTask = nil
                    self.currentAIPresentation = nil
                    self.aiIncludeCheckbox.state = .off
                    self.aiIncludeCheckbox.isHidden = true
                    self.displayAttributedText(formatted)
                    self.refreshStarState()
                    self.textView.scrollToBeginningOfDocument(nil)
                    self.aiAction = .none
                    self.aiStatusLabel.stringValue = presentation.fromCache
                        ? "已显示本机缓存的句子解析" : "句子解析已生成"
                    self.aiSettingsButton.isHidden = true
                    self.updateAIFooter(visible: true, compact: true)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentIntent == .sentence,
                          self.currentQuery == sentence,
                          self.queryGeneration.accepts(generation) else { return }
                    self.currentSentencePresentation = nil
                    self.currentSentenceStatus = error.localizedDescription
                    self.renderSentenceContent()
                    self.aiAction = .analyzeSentence
                    self.aiStatusLabel.stringValue = error.localizedDescription
                    self.aiActionButton.title = "重试"
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = false
                    self.updateAIFooter(visible: true)
                    self.refreshStarState()
                }
            }
        }
    }

    private func cancelSentenceAnalysis() {
        guard currentIntent == .sentence else { return }
        aiTask?.cancel()
        aiTask = nil
        _ = queryGeneration.beginQuery()
        currentSentencePresentation = nil
        currentSentenceStatus = "句子分析已取消"
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        renderSentenceContent()
        startLocalGlossaryAnalysis(for: currentQuery)
        aiAction = .analyzeSentence
        aiStatusLabel.stringValue = "句子分析已取消"
        aiActionButton.title = "重试"
        aiActionButton.isHidden = false
        aiActionButton.isEnabled = true
        aiSettingsButton.isHidden = false
        updateAIFooter(visible: true)
        refreshStarState()
    }

    private func updateAIFooter(visible: Bool, compact: Bool = false) {
        aiFooter.isHidden = !visible
        if visible { aiActionButton.isHidden = compact }
        aiFooterHeightConstraint?.constant = visible ? (compact ? 22 : 52) : 0
    }

    @objc private func aiInclusionDidChange() {
        refreshStarState()
    }

    private func positionAIIncludeCheckbox() {
        guard let location = aiSectionCharacterLocation,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              location < textView.string.utf16.count else {
            aiIncludeCheckbox.isHidden = true
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let characterRange = NSRange(location: location,
                                     length: min(8, textView.string.utf16.count - location))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange,
                                                  actualCharacterRange: nil)
        let titleRect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                   in: textContainer)
        let origin = textView.textContainerOrigin
        let size = NSSize(width: 162, height: 18)
        let preferredX = textView.bounds.width - origin.x - size.width
        aiIncludeCheckbox.frame = NSRect(x: max(origin.x + 126, preferredX),
                                        y: origin.y + titleRect.minY,
                                        width: size.width,
                                        height: size.height)
    }

    private func suggestedDomain() -> String {
        guard let entry = currentEntry else { return "general" }
        return entry.sources.contains { $0.source.contains("医学") } ? "medicine" : "general"
    }

    private func containsChineseContent(_ entry: StructuredDictionaryEntry) -> Bool {
        for source in entry.sources {
            var values = source.definitions + source.examples
            if let sections = source.partOfSpeechSections {
                values += sections.flatMap { section in
                    section.senses.flatMap { [$0.definition] + $0.labels + $0.examples }
                }
            }
            if let semantic = source.semanticEntry {
                values += semantic.partOfSpeechSections.flatMap { section in
                    section.senses.flatMap(Self.semanticText)
                }
            }
            if values.contains(where: Self.containsCJK) { return true }
        }
        return false
    }

    private static func semanticText(_ sense: StructuredSemanticSense) -> [String] {
        var values = [sense.definitionEnglish] + sense.definitionChinese + sense.labels
        values += sense.examples.flatMap { [$0.english] + $0.translations }
        values += sense.subsenses.flatMap(semanticText)
        return values
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    private func makeLocalGlossarySources() -> [LocalGlossaryDictionarySource] {
        [
            glossarySource(id: .century21, name: "21世纪大英汉词典", priority: 1),
            glossarySource(id: .medicalEnglishChinese, name: "英中医学辞海", priority: 2),
            LocalGlossaryDictionarySource(name: "牛津高阶 8", priority: 3) {
                [weak self] term in self?.lookupOxfordGlossary(term)
            },
            glossarySource(id: .newOxford, name: "新牛津英文", priority: 4),
            glossarySource(id: .affixRootA, name: "词根词缀", priority: 5)
        ]
    }

    private func glossarySource(id: DictionarySourceID, name: String,
                                priority: Int) -> LocalGlossaryDictionarySource {
        LocalGlossaryDictionarySource(name: name, priority: priority) { [weak self] term in
            self?.lookupSupplementalGlossary(term, sourceID: id, sourceName: name)
        }
    }

    private func lookupOxfordGlossary(_ term: String) -> LocalGlossaryLookupResult? {
        let result = synchronizedLookup(core: oxfordCore, query: term)
        guard result["found"] as? Bool == true,
              let html = result["html"] as? String else { return nil }
        let parsed = OxfordEntryFormatter().formatHTML(html).structuredEntry
        let definitions = parsed.definitions + Self.glossaryDefinitions(from: parsed.semanticEntry)
        return LocalGlossaryLookupResult(
            partOfSpeech: parsed.partsOfSpeech.first ?? "",
            definitions: definitions,
            source: "牛津高阶 8"
        )
    }

    private func lookupSupplementalGlossary(_ term: String,
                                            sourceID: DictionarySourceID,
                                            sourceName: String) -> LocalGlossaryLookupResult? {
        guard let dictionary = supplementalDictionaries.first(where: { $0.id == sourceID }) else {
            return nil
        }
        let result = synchronizedLookup(core: dictionary.core, query: term)
        guard result["found"] as? Bool == true,
              let html = result["html"] as? String else { return nil }
        let matched = (result["matchedHeadword"] as? String) ?? term
        let formatted: SupplementalFormatResult
        switch sourceID {
        case .century21:
            formatted = Century21EntryFormatter().formatHTML(html, matchedHeadword: matched)
        case .newOxford:
            formatted = NewOxfordEntryFormatter().formatHTML(html, matchedHeadword: matched)
        case .medicalEnglishChinese:
            formatted = MedicalEntryFormatter().formatHTML(html, matchedHeadword: matched)
        case .affixRootA:
            formatted = AffixRootEntryFormatter().formatHTML(html, matchedHeadword: matched)
        case .oxfordOALD8:
            return nil
        }
        let parsed = formatted.structuredEntry
        var definitions = parsed.definitions
        definitions += parsed.partOfSpeechSections.flatMap { section in
            section.senses.flatMap { [$0.definition] + $0.labels }
        }
        definitions += Self.glossaryDefinitions(from: parsed.semanticEntry)
        return LocalGlossaryLookupResult(
            partOfSpeech: parsed.partsOfSpeech.first ?? "",
            definitions: definitions,
            source: sourceName
        )
    }

    private static func glossaryDefinitions(from entry: DictionarySemanticEntry) -> [String] {
        entry.partOfSpeechSections.flatMap { section in
            section.senses.flatMap(glossaryDefinitions)
        }
    }

    private static func glossaryDefinitions(from sense: DictionarySemanticSense) -> [String] {
        var values = sense.definitionChinese
        if containsCJK(sense.definitionEnglish) { values.append(sense.definitionEnglish) }
        values += sense.subsenses.flatMap(glossaryDefinitions)
        return values
    }

    private func synchronizedLookup(core: DictionaryCoreBridge,
                                    query: String) -> [String: Any] {
        objc_sync_enter(core)
        defer { objc_sync_exit(core) }
        return core.lookup(query)
    }

    private func formatSupplementalHTML(_ html: String,
                                        matchedHeadword: String,
                                        sourceID: DictionarySourceID) -> SupplementalFormatResult {
        switch sourceID {
        case .century21:
            return century21Formatter.formatHTML(html, matchedHeadword: matchedHeadword)
        case .newOxford:
            return newOxfordFormatter.formatHTML(html, matchedHeadword: matchedHeadword)
        case .medicalEnglishChinese:
            return medicalFormatter.formatHTML(html, matchedHeadword: matchedHeadword)
        case .affixRootA:
            return affixRootFormatter.formatHTML(html, matchedHeadword: matchedHeadword)
        case .oxfordOALD8:
            preconditionFailure("Oxford uses OxfordEntryFormatter")
        }
    }

    private func structuredPartOfSpeechSections(
        from entry: SupplementalStructuredEntry
    ) -> [StructuredPartOfSpeechSection] {
        entry.partOfSpeechSections.map { section in
            StructuredPartOfSpeechSection(
                partOfSpeech: section.partOfSpeech,
                senses: section.senses.map { sense in
                    StructuredPartOfSpeechSense(
                        definition: sense.definition,
                        labels: sense.labels,
                        examples: sense.examples,
                        number: Int(sense.number),
                        indentationLevel: Int(sense.indentationLevel)
                    )
                }
            )
        }
    }

    private func structuredSemanticEntry(
        from entry: DictionarySemanticEntry
    ) -> StructuredSemanticEntry? {
        let structured = StructuredSemanticEntry(
            inflections: entry.inflections,
            partOfSpeechSections: entry.partOfSpeechSections.map { section in
                StructuredSemanticPartOfSpeechSection(
                    partOfSpeech: section.partOfSpeech,
                    pronunciations: section.pronunciations,
                    grammarLabels: section.grammarLabels,
                    senses: section.senses.map(structuredSemanticSense),
                    relations: section.relations.map(structuredSemanticRelation),
                    derivatives: section.derivatives.map(structuredSemanticDerivative)
                )
            },
            entryLevelRelations: entry.entryLevelRelations.map(structuredSemanticRelation),
            derivatives: entry.derivatives.map(structuredSemanticDerivative)
        )
        return structured.hasContent ? structured : nil
    }

    private func structuredSemanticSense(
        _ sense: DictionarySemanticSense
    ) -> StructuredSemanticSense {
        StructuredSemanticSense(
            number: sense.number,
            labels: sense.labels,
            definitionEnglish: sense.definitionEnglish,
            definitionChinese: sense.definitionChinese,
            grammarPatterns: sense.grammarPatterns,
            examples: sense.examples.map {
                StructuredSemanticExample(english: $0.english,
                                          translations: $0.translations)
            },
            relations: sense.relations.map(structuredSemanticRelation),
            subsenses: sense.subsenses.map(structuredSemanticSense)
        )
    }

    private func structuredSemanticRelation(
        _ relation: DictionarySemanticRelationGroup
    ) -> StructuredSemanticRelationGroup {
        StructuredSemanticRelationGroup(kind: relation.kind,
                                        title: relation.title,
                                        values: relation.values)
    }

    private func structuredSemanticDerivative(
        _ derivative: DictionarySemanticDerivative
    ) -> StructuredSemanticDerivative {
        StructuredSemanticDerivative(headword: derivative.headword,
                                     partOfSpeech: derivative.partOfSpeech,
                                     pronunciations: derivative.pronunciations,
                                     summary: derivative.summary,
                                     sourceHeadword: derivative.sourceHeadword,
                                     sourcePartOfSpeech: derivative.sourcePartOfSpeech)
    }

    private func appendAvailabilityNotice(_ names: [String],
                                          to output: NSMutableAttributedString) {
        guard !names.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 10
        style.lineBreakMode = .byWordWrapping
        output.append(NSAttributedString(
            string: "\n\n部分词典暂不可用：" + names.joined(separator: "、"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style
            ]
        ))
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
        guard let content = currentNoteSaveContent(), !isShowingNoteMenu else { return }
        let menu = NSMenu(title: "保存到 Markdown 笔记")
        if let target = noteStore.targetURL {
            let filename = abbreviatedFilename(target.lastPathComponent)
            let addCurrent = NSMenuItem(title: "加入当前笔记：\(filename)",
                                        action: #selector(addToCurrentNote),
                                        keyEquivalent: "")
            addCurrent.target = self
            addCurrent.toolTip = target.path
            addCurrent.state = isSaved(content) ? .on : .off
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
        guard let content = currentNoteSaveContent() else { return }
        save(content)
    }

    @objc private func selectExistingNote() {
        selectExistingForCurrentEntry()
    }

    @objc private func createNewNote() {
        guard let content = currentNoteSaveContent() else { return }
        let directory = noteStore.targetURL?.deletingLastPathComponent()
        guard let url = notePicker.chooseNewNote(initialDirectory: directory) else { return }
        save(content, to: url, creatingIfNeeded: true)
    }

    private func selectExistingForCurrentEntry() {
        guard let content = currentNoteSaveContent() else { return }
        let directory = noteStore.targetURL?.deletingLastPathComponent()
        guard let url = notePicker.chooseExistingNote(initialDirectory: directory) else { return }
        save(content, to: url, creatingIfNeeded: false)
    }

    private func currentNoteSaveContent() -> NoteSaveContent? {
        if currentIntent == .sentence {
            guard let content = sentenceMarkdownFormatter.content(
                sourceText: currentQuery,
                aiPresentation: currentSentencePresentation,
                glossary: currentLocalGlossary
            ) else { return nil }
            return .sentence(content)
        }
        let headword = currentEntry?.headword ?? currentQuery
        let aiSection: AIExplanationNoteSection?
        if aiIncludeCheckbox.state == .on, let presentation = currentAIPresentation {
            aiSection = aiMarkdownFormatter.section(for: presentation, headword: headword)
        } else {
            aiSection = nil
        }
        let content = VocabularyNoteSaveContent(headword: headword,
                                                localEntry: currentEntry,
                                                aiSection: aiSection)
        return content.isValid ? .vocabulary(content) : nil
    }

    private func save(_ content: NoteSaveContent) {
        do {
            let feedback: String
            switch content {
            case .vocabulary(let value):
                feedback = feedbackText(for: try noteStore.save(value))
            case .sentence(let value):
                feedback = feedbackText(for: try noteStore.save(value), content: value)
            }
            refreshStarState()
            showFeedback(feedback)
        } catch {
            refreshStarState()
            presentSaveError(error, expectedIdentity: content.identity)
        }
    }

    private func save(_ content: NoteSaveContent,
                      to url: URL,
                      creatingIfNeeded: Bool) {
        do {
            let feedback: String
            switch content {
            case .vocabulary(let value):
                let result = creatingIfNeeded
                    ? try noteStore.createOrSave(value, at: url)
                    : try noteStore.save(value, to: url)
                feedback = feedbackText(for: result)
            case .sentence(let value):
                let result = creatingIfNeeded
                    ? try noteStore.createOrSave(value, at: url)
                    : try noteStore.save(value, to: url)
                feedback = feedbackText(for: result, content: value)
            }
            try noteStore.rememberTarget(url)
            refreshStarState()
            showFeedback(feedback)
        } catch {
            refreshStarState()
            presentSaveError(error, expectedIdentity: content.identity)
        }
    }

    private func feedbackText(for result: VocabularyNoteSaveResult) -> String {
        switch result {
        case .localSaved, .localAlreadySaved:
            return "已收藏"
        case .savedWithAI:
            return "已收藏，并加入 AI 内容"
        case .aiAddedToExistingEntry:
            return "已将 AI 内容加入现有词条"
        case .aiAlreadyPresent:
            return "AI 内容已加入笔记"
        }
    }

    private func feedbackText(for result: SentenceNoteSaveResult,
                              content: SentenceNoteSaveContent) -> String {
        switch result {
        case .saved:
            return content.validAISection ? "已收藏，并加入 AI 解析" : "已收藏"
        case .alreadySaved:
            return "该句子已加入笔记"
        case .aiAddedToExistingSentence:
            return "已将 AI 解析加入现有句子"
        case .aiAlreadyPresent:
            return "该句子已包含 AI 解析"
        }
    }

    private func setCurrentEntry(_ entry: StructuredDictionaryEntry?) {
        currentEntry = entry
        refreshStarState()
    }

    private func refreshStarState() {
        guard let content = currentNoteSaveContent() else {
            starButton.isEnabled = false
            setStarFilled(false)
            if currentIntent == .sentence {
                starButton.toolTip = "当前没有可以保存的句子学习内容"
            } else {
                starButton.toolTip = currentAIPresentation != nil && currentEntry == nil
                    ? "勾选“收藏时加入 AI 内容”后可保存"
                    : "当前没有可以保存的词条"
            }
            return
        }

        starButton.isEnabled = true
        let isSaved = isSaved(content)
        setStarFilled(isSaved)
        starButton.toolTip = isSaved ? "已保存到 Obsidian 笔记" : "保存到 Obsidian 笔记"
    }

    private func isSaved(_ content: NoteSaveContent) -> Bool {
        switch content {
        case .vocabulary(let value):
            return (try? noteStore.contains(headword: value.headword)) == true
        case .sentence(let value):
            return (try? noteStore.contains(sentence: value.sourceText)) == true
        }
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
        let width = max(92, min(240, label.intrinsicContentSize.width + 24))
        label.frame = NSRect(x: 0, y: 0, width: width, height: 34)

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

    private func presentSaveError(_ error: Error, expectedIdentity: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存到 Markdown 笔记"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "选择已有笔记")
        alert.addButton(withTitle: "取消")

        guard let panel = window else { return }
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  self.currentNoteSaveContent()?.identity == expectedIdentity else { return }
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
