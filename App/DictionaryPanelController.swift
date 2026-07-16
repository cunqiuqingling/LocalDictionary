import AppKit
import ObjectiveC

struct SupplementalDictionaryRuntime {
    let id: DictionarySourceID
    let displayName: String
    let priority: Int
    let core: DictionaryCoreBridge
}

private struct PreferredDictionaryPresentation {
    let dictionaryID: String
    let attributedString: NSAttributedString
    let structuredSource: StructuredDictionarySource
    let headword: String
}

final class DictionaryPanel: NSPanel {
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }
}

final class DictionaryPanelController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
                                       NSTextViewDelegate {
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
    private let managedDictionaryQueryService: ManagedDictionaryQueryService
    private let openAISettings: () -> Void
    private let aiEntryFormatter = AIEntryFormatter()
    private let aiSentenceFormatter = AISentenceEntryFormatter()
    private let aiMarkdownFormatter = AIExplanationMarkdownFormatter()
    private let localGlossaryFormatter = LocalSentenceGlossaryFormatter()
    private let sentenceMarkdownFormatter = SentenceAnalysisMarkdownFormatter()
    private let inlineAttributedFormatter = InlineLookupAttributedFormatter()
    private let inlineMarkdownFormatter = InlineLookupMarkdownFormatter()
    private let genericManagedPresenter = GenericManagedDictionaryPresenter()
    private lazy var inlinePageRenderer = InlinePageRenderer(formatter: inlineAttributedFormatter)
    private let searchField = NSSearchField()
    private let starButton = NSButton()
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let aiFooter = NSStackView()
    private let aiStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let aiActionButton = NSButton()
    private let aiSettingsButton = NSButton()
    private let aiClearCacheButton = NSButton()
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
    private var managedQueryTask: Task<Void, Never>?
    private var managedCatalogGeneration: UInt64 = 0
    private var preferredCatalogDescriptors: [String: DictionaryDescriptor] = [:]
    private var currentAIPresentation: AIExplanationPresentation?
    private var currentSentencePresentation: AISentenceAnalysisPresentation?
    private var currentLocalGlossary: LocalSentenceGlossary?
    private var currentSentenceStatus: String?
    private var aiSectionCharacterLocation: Int?
    private var queryGeneration = AIQueryGenerationGate()
    private var feedbackPopover: NSPopover?
    private var localKeyMonitor: Any?
    private var isShowingNoteMenu = false
    private var animating = false
    private var reportedUnavailableDictionaryIDs: Set<String> = []
    private var inlinePageID = UUID()
    private var inlineBaseContent = NSAttributedString(string: "")
    private var inlineBaseBlocks: [InlineBaseBlock] = []
    private var inlineSupplements: [InlineLookupSupplement] = []
    private var inlineTasks: [UUID: Task<Void, Never>] = [:]
    private var inlineControlButtons: [NSButton] = []
    private let inlineSelectionButton = NSButton()
    private var pendingInlineSelection: InlineSelectionSnapshot?
    private var inlineLayoutRetryScheduled = false
#if DEBUG
    private var didLogInlineLayoutDiagnostics = false
#endif

    private var localGlossaryService: LocalSentenceGlossaryService!
    private var inlineLocalLookupService: InlineLocalLookupService!

    private enum AIAction: Equatable {
        case none
        case configure
        case explain(domain: String, bypassCache: Bool)
        case analyzeSentence(bypassCache: Bool)
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
         managedDictionaryQueryService: ManagedDictionaryQueryService,
         dictionaryCatalog: DictionaryCatalog = .empty(),
         openAISettings: @escaping () -> Void) {
        oxfordCore = core
        self.supplementalDictionaries = supplementalDictionaries.sorted {
            $0.priority < $1.priority
        }
        self.noteStore = noteStore
        self.notePicker = notePicker
        self.aiService = aiService
        self.managedDictionaryQueryService = managedDictionaryQueryService
        self.openAISettings = openAISettings
        preferredCatalogDescriptors = Dictionary(uniqueKeysWithValues:
            dictionaryCatalog.dictionaries.filter {
                $0.sourceKind == .legacyReference
            }.map { ($0.dictionaryID, $0) }
        )
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
        localGlossaryService = LocalSentenceGlossaryService(
            sources: makeLocalGlossarySources(),
            managedFallback: { [managedDictionaryQueryService] term in
                let batch = await managedDictionaryQueryService.lookup(term)
                guard let hit = batch.hits.first,
                      !hit.conciseChineseDefinitions.isEmpty else { return nil }
                return LocalGlossaryLookupResult(
                    partOfSpeech: "",
                    definitions: hit.conciseChineseDefinitions,
                    source: hit.displayName
                )
            }
        )
        inlineLocalLookupService = InlineLocalLookupService(
            sources: makeInlineLocalLookupSources(),
            managedFallback: { [managedDictionaryQueryService] term in
                let batch = await managedDictionaryQueryService.lookup(term)
                return batch.hits.map(Self.inlineHit(from:))
            }
        )
        configure(panel)
        installEventMonitors()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        aiTask?.cancel()
        localGlossaryTask?.cancel()
        managedQueryTask?.cancel()
        inlineTasks.values.forEach { $0.cancel() }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    var isVisible: Bool { window?.isVisible == true }

    func updateDictionaryCatalog(_ catalog: DictionaryCatalog) {
        managedCatalogGeneration &+= 1
        managedQueryTask?.cancel()
        managedQueryTask = nil
        preferredCatalogDescriptors = Dictionary(uniqueKeysWithValues:
            catalog.dictionaries.filter {
                $0.sourceKind == .legacyReference
            }.map { ($0.dictionaryID, $0) }
        )
    }

    func managedDictionaryWillBeRemoved(dictionaryID: String) {
        managedCatalogGeneration &+= 1
        managedQueryTask?.cancel()
        managedQueryTask = nil
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        inlineTasks.values.forEach { $0.cancel() }
        inlineTasks.removeAll()
    }

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
        aiTask?.cancel()
        aiTask = nil
        _ = queryGeneration.beginQuery()
        currentAIPresentation = nil
        currentSentencePresentation = nil
        currentSentenceStatus = nil
        aiSectionCharacterLocation = nil
        aiIncludeCheckbox.state = .off
        aiIncludeCheckbox.isHidden = true
        aiStatusLabel.stringValue = ""
        aiClearCacheButton.isHidden = true
        if currentIntent == .sentence {
            renderSentenceContent()
        } else if let localResultContent {
            displayAttributedText(localResultContent)
        }
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
        managedQueryTask?.cancel()
        managedQueryTask = nil
        cancelAllInlineLookups(clear: true)
        renderInlinePage()
        hideInlineSelectionButton()
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        textView.delegate = self
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
        inlineSelectionButton.bezelStyle = .rounded
        inlineSelectionButton.controlSize = .small
        inlineSelectionButton.font = .systemFont(ofSize: 11, weight: .medium)
        inlineSelectionButton.target = self
        inlineSelectionButton.action = #selector(performInlineLookupFromSelection)
        inlineSelectionButton.sendAction(on: .leftMouseDown)
        inlineSelectionButton.isHidden = true
        inlineSelectionButton.setAccessibilityLabel("查询选中的正文")
        scrollView.addSubview(inlineSelectionButton)
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inlineScrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

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
        aiClearCacheButton.title = "清除本条缓存"
        aiClearCacheButton.bezelStyle = .inline
        aiClearCacheButton.isBordered = false
        aiClearCacheButton.controlSize = .small
        aiClearCacheButton.target = self
        aiClearCacheButton.action = #selector(clearCurrentAICache)
        aiClearCacheButton.isHidden = true
        let aiButtons = NSStackView(views: [aiActionButton, aiSettingsButton, aiClearCacheButton])
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
        var preferredResults: [PreferredDictionaryPresentation] = []
        var failures: [(id: String, name: String)] = []

        let oxfordID = DictionarySourceID.oxfordOALD8.rawValue
        if isPreferredDictionaryEnabled(oxfordID) {
            let oxfordResult = synchronizedLookup(core: oxfordCore, query: query)
            if let error = oxfordResult["error"] as? String, !error.isEmpty {
                failures.append((oxfordID, "牛津高阶 8"))
            } else if oxfordResult["found"] as? Bool == true,
                      let html = oxfordResult["html"] as? String {
                let formatted = entryFormatter.formatHTML(html)
                let parsed = formatted.structuredEntry
                let source = StructuredDictionarySource(
                    phonetics: parsed.phonetics,
                    partsOfSpeech: parsed.partsOfSpeech,
                    definitions: parsed.definitions,
                    examples: parsed.examples,
                    source: "牛津高阶 8",
                    semanticEntry: structuredSemanticEntry(from: parsed.semanticEntry)
                )
                if formatted.attributedString.length > 0 {
                    preferredResults.append(PreferredDictionaryPresentation(
                        dictionaryID: oxfordID,
                        attributedString: formatted.attributedString,
                        structuredSource: source,
                        headword: parsed.headword
                    ))
                }
            }
        }

        for dictionary in supplementalDictionaries
        where isPreferredDictionaryEnabled(dictionary.id.rawValue) {
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
            let parsed = formatted.structuredEntry
            let source = StructuredDictionarySource(
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
            )
            preferredResults.append(PreferredDictionaryPresentation(
                dictionaryID: dictionary.id.rawValue,
                attributedString: formatted.attributedString,
                structuredSource: source,
                headword: parsed.headword.isEmpty ? matchedHeadword : parsed.headword
            ))
        }

        preferredResults.sort {
            let left = preferredSortKey($0.dictionaryID)
            let right = preferredSortKey($1.dictionaryID)
            return left.position == right.position
                ? left.dictionaryID < right.dictionaryID
                : left.position < right.position
        }
        failures.sort {
            let left = preferredSortKey($0.id)
            let right = preferredSortKey($1.id)
            return left.position == right.position
                ? left.dictionaryID < right.dictionaryID
                : left.position < right.position
        }
        let attributedSections = preferredResults.map(\.attributedString)
        let structuredSources = preferredResults.map(\.structuredSource)
        let headword = preferredResults.lazy.map(\.headword).first { !$0.isEmpty } ?? ""

        let newlyUnavailable = failures.filter {
            !reportedUnavailableDictionaryIDs.contains($0.id)
        }
        reportedUnavailableDictionaryIDs.formUnion(newlyUnavailable.map { $0.id })

        guard !attributedSections.isEmpty else {
            startManagedDictionaryLookup(
                query: query,
                intent: intent,
                generation: queryGeneration.generation,
                unavailablePreferredNames: newlyUnavailable.map(\.name)
            )
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

    private func isPreferredDictionaryEnabled(_ dictionaryID: String) -> Bool {
        guard let descriptor = preferredCatalogDescriptors[dictionaryID] else { return true }
        return descriptor.enabled && descriptor.queryLevel == .preferred
    }

    private func preferredSortKey(_ dictionaryID: String)
        -> (position: Int64, dictionaryID: String) {
        if let descriptor = preferredCatalogDescriptors[dictionaryID] {
            return (descriptor.sortPosition, dictionaryID)
        }
        let defaultIndex = DictionaryCatalogOrdering.legacyDefaultOrder
            .firstIndex(of: dictionaryID)
        return (Int64((defaultIndex ?? Int.max - 1) + 1), dictionaryID)
    }

    private func startManagedDictionaryLookup(
        query: String,
        intent: QueryIntent,
        generation: UInt64,
        unavailablePreferredNames: [String]
    ) {
        displayText("正在查询已托管词典…")
        let catalogGeneration = managedCatalogGeneration
        managedQueryTask = Task { [weak self, managedDictionaryQueryService] in
            let batch = await managedDictionaryQueryService.lookup(query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.currentQuery == query,
                      self.currentIntent == intent,
                      self.managedCatalogGeneration == catalogGeneration,
                      self.queryGeneration.accepts(generation) else { return }
                self.managedQueryTask = nil
                if batch.hits.isEmpty {
                    var message = "未找到词条：\(query)"
                    if !unavailablePreferredNames.isEmpty {
                        message += "\n部分词典暂不可用：" +
                            unavailablePreferredNames.joined(separator: "、")
                    }
                    if !batch.unavailableDictionaryIDs.isEmpty {
                        message += "\n部分托管词典暂不可用"
                    }
                    self.displayText(message)
                    self.localResultContent = self.textView.attributedString()
                    self.configureAIAction(hasLocalResult: false, hasChinese: false)
                    return
                }
                self.displayManagedDictionaryHits(batch.hits, query: query)
            }
        }
    }

    private func displayManagedDictionaryHits(_ hits: [ManagedDictionaryQueryHit],
                                              query: String) {
        let combined = NSMutableAttributedString(string: "")
        var sources: [StructuredDictionarySource] = []
        for hit in hits {
            if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
            combined.append(genericManagedPresenter.attributedString(for: hit))
            sources.append(StructuredDictionarySource(
                phonetics: [],
                partsOfSpeech: [],
                definitions: hit.noteDefinitions,
                examples: [],
                source: hit.displayName,
                dictionaryID: hit.dictionaryID
            ))
        }
        guard !sources.isEmpty else { return }
        displayAttributedText(combined)
        let headword = hits.first?.matchedHeadword.isEmpty == false
            ? hits[0].matchedHeadword : query
        let entry = StructuredDictionaryEntry(headword: headword, sources: sources)
        setCurrentEntry(entry)
        localResultContent = combined.copy() as? NSAttributedString
        localResultHasChinese = hits.contains { !$0.conciseChineseDefinitions.isEmpty }
        configureAIAction(hasLocalResult: true, hasChinese: localResultHasChinese)
        textView.scrollToBeginningOfDocument(nil)
    }

    private func resetAIState(query: String, intent: QueryIntent) {
        aiTask?.cancel()
        aiTask = nil
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        managedQueryTask?.cancel()
        managedQueryTask = nil
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
        aiClearCacheButton.isHidden = true
        aiSettingsButton.title = "打开 AI 设置…"
        updateAIFooter(visible: false)
        clearInlinePage()
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
                self.aiAction = .explain(domain: self.suggestedDomain(), bypassCache: false)
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
        case .explain(let domain, let bypassCache):
            requestAIExplanation(domain: domain, bypassCache: bypassCache)
        case .analyzeSentence(let bypassCache):
            requestSentenceAnalysis(bypassCache: bypassCache)
        case .cancelSentence:
            cancelSentenceAnalysis()
        }
    }

    @objc private func openAISettingsWindow() {
        openAISettings()
    }

    @objc private func clearCurrentAICache() {
        let query = currentQuery
        let intent = currentIntent
        let providerID = intent == .sentence
            ? currentSentencePresentation?.providerID : currentAIPresentation?.providerID
        let generation = queryGeneration.generation
        guard !query.isEmpty else { return }
        aiClearCacheButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await aiService.clearCurrentCache(for: query, intent: intent,
                                                      providerID: providerID)
                await MainActor.run {
                    guard self.currentQuery == query, self.currentIntent == intent,
                          self.queryGeneration.accepts(generation) else { return }
                    self.aiClearCacheButton.isHidden = true
                    self.aiClearCacheButton.isEnabled = true
                    self.aiStatusLabel.stringValue = "本条 AI 缓存已清除。"
                    self.updateAIFooter(visible: true, compact: self.aiAction == .none)
                }
            } catch {
                await MainActor.run {
                    guard self.currentQuery == query, self.currentIntent == intent,
                          self.queryGeneration.accepts(generation) else { return }
                    self.aiClearCacheButton.isEnabled = true
                    self.aiStatusLabel.stringValue = "无法清除本条缓存：\(error.localizedDescription)"
                    self.updateAIFooter(visible: true)
                }
            }
        }
    }

    private func refreshCurrentAICacheControl(query: String) {
        let intent = currentIntent
        let providerID = intent == .sentence
            ? currentSentencePresentation?.providerID : currentAIPresentation?.providerID
        let generation = queryGeneration.generation
        Task { [weak self] in
            guard let self else { return }
            let exists = await aiService.hasCurrentCache(for: query, intent: intent,
                                                         providerID: providerID)
            await MainActor.run {
                guard self.currentQuery == query, self.currentIntent == intent,
                      self.queryGeneration.accepts(generation) else { return }
                self.aiClearCacheButton.isHidden = !exists
                self.aiClearCacheButton.isEnabled = true
                if !self.aiFooter.isHidden {
                    self.aiFooterHeightConstraint?.constant = exists ? 48 : 22
                }
            }
        }
    }

    private func aiFailureMessage(_ error: Error) -> String {
        if let failure = error as? AIProviderRequestFailure {
            return failure.localizedDescription
        }
        return error.localizedDescription
    }

    private func requestAIExplanation(domain: String, bypassCache: Bool = false) {
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
                let presentation = try await aiService.explain(query: query, domain: domain,
                                                                bypassCache: bypassCache)
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
                    self.refreshCurrentAICacheControl(query: query)
                    self.updateAIFooter(visible: true, compact: true)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.currentQuery == query,
                          self.currentIntent != .sentence,
                          self.queryGeneration.accepts(generation) else { return }
                    self.aiAction = .explain(domain: domain, bypassCache: true)
                    self.aiStatusLabel.stringValue = self.aiFailureMessage(error)
                    self.aiActionButton.title = "重新查询"
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = false
                    self.aiSettingsButton.title = "更换 AI 服务…"
                    self.refreshCurrentAICacheControl(query: query)
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
                    self.aiAction = .analyzeSentence(bypassCache: false)
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

    private func requestSentenceAnalysis(expectedGeneration: UInt64? = nil,
                                         bypassCache: Bool = false) {
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
                let presentation = try await aiService.analyzeSentence(
                    sentence, bypassCache: bypassCache
                )
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
                    self.refreshCurrentAICacheControl(query: sentence)
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
                    self.aiAction = .analyzeSentence(bypassCache: true)
                    self.aiStatusLabel.stringValue = self.aiFailureMessage(error)
                    self.aiActionButton.title = "重新查询"
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = false
                    self.aiSettingsButton.title = "更换 AI 服务…"
                    self.refreshCurrentAICacheControl(query: sentence)
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
        aiAction = .analyzeSentence(bypassCache: true)
        aiStatusLabel.stringValue = "句子分析已取消"
        aiActionButton.title = "重新查询"
        aiActionButton.isHidden = false
        aiActionButton.isEnabled = true
        aiSettingsButton.isHidden = false
        updateAIFooter(visible: true)
        refreshStarState()
    }

    private func updateAIFooter(visible: Bool, compact: Bool = false) {
        aiFooter.isHidden = !visible
        if visible, compact { aiActionButton.isHidden = true }
        let compactHeight: CGFloat = aiClearCacheButton.isHidden ? 22 : 48
        aiFooterHeightConstraint?.constant = visible ? (compact ? compactHeight : 52) : 0
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

    private func makeInlineLocalLookupSources() -> [InlineLocalLookupSource] {
        var sources: [InlineLocalLookupSource] = [
            InlineLocalLookupSource(name: "牛津高阶 8", priority: 1) { [weak self] term in
                self?.lookupOxfordInline(term)
            }
        ]
        let ordered: [(DictionarySourceID, String, Int)] = [
            (.century21, "21世纪大英汉词典", 2),
            (.newOxford, "新牛津英文", 3),
            (.medicalEnglishChinese, "英中医学辞海", 4),
            (.affixRootA, "词根词缀", 5)
        ]
        sources += ordered.map { id, name, priority in
            InlineLocalLookupSource(name: name, priority: priority) { [weak self] term in
                self?.lookupSupplementalInline(term, sourceID: id, sourceName: name)
            }
        }
        return sources
    }

    private func lookupOxfordInline(_ term: String) -> InlineLocalDictionaryHit? {
        guard isPreferredDictionaryEnabled(DictionarySourceID.oxfordOALD8.rawValue) else {
            return nil
        }
        let result = synchronizedLookup(core: oxfordCore, query: term)
        guard result["found"] as? Bool == true,
              let html = result["html"] as? String else { return nil }
        let parsed = OxfordEntryFormatter().formatHTML(html).structuredEntry
        let semantic = parsed.semanticEntry
        let chinese = Self.uniqueInlineStrings(
            parsed.definitions.filter(Self.containsCJK) + Self.glossaryDefinitions(from: semantic),
            maximum: 12
        )
        let examples = Self.uniqueInlineStrings(
            parsed.examples + semantic.partOfSpeechSections.flatMap { section in
                section.senses.flatMap(Self.inlineExamples)
            }, maximum: 8
        )
        let relations = semantic.partOfSpeechSections.flatMap { section in
            section.relations.flatMap(\.values) + section.senses.flatMap(Self.inlineRelations)
        } + semantic.entryLevelRelations.flatMap(\.values)
        return InlineLocalDictionaryHit(
            source: "牛津高阶 8",
            partOfSpeech: parsed.partsOfSpeech.first ?? "",
            chineseDefinitions: chinese,
            additionalDefinitions: Array(chinese.dropFirst(3)),
            examples: examples,
            collocations: Self.uniqueInlineStrings(relations, maximum: 8),
            inflections: semantic.inflections,
            roots: [],
            isRootDictionary: false
        )
    }

    private func lookupSupplementalInline(_ term: String, sourceID: DictionarySourceID,
                                          sourceName: String) -> InlineLocalDictionaryHit? {
        guard isPreferredDictionaryEnabled(sourceID.rawValue) else { return nil }
        guard let dictionary = supplementalDictionaries.first(where: { $0.id == sourceID }) else {
            return nil
        }
        let result = synchronizedLookup(core: dictionary.core, query: term)
        guard result["found"] as? Bool == true,
              let html = result["html"] as? String else { return nil }
        let matched = (result["matchedHeadword"] as? String) ?? term
        let parsed = formatSupplementalHTML(html, matchedHeadword: matched,
                                           sourceID: sourceID).structuredEntry
        var values = parsed.definitions
        values += parsed.partOfSpeechSections.flatMap { section in
            section.senses.flatMap { [$0.definition] + $0.labels }
        }
        values += Self.glossaryDefinitions(from: parsed.semanticEntry)
        let chinese = Self.uniqueInlineStrings(values.filter(Self.containsCJK), maximum: 12)
        var examples = parsed.examples
        examples += parsed.partOfSpeechSections.flatMap { $0.senses.flatMap(\.examples) }
        examples += parsed.semanticEntry.partOfSpeechSections.flatMap { section in
            section.senses.flatMap(Self.inlineExamples)
        }
        let relations = parsed.semanticEntry.partOfSpeechSections.flatMap { section in
            section.relations.flatMap(\.values) + section.senses.flatMap(Self.inlineRelations)
        } + parsed.semanticEntry.entryLevelRelations.flatMap(\.values)
        let isRoot = sourceID == .affixRootA
        return InlineLocalDictionaryHit(
            source: sourceName,
            partOfSpeech: parsed.partsOfSpeech.first ?? "",
            chineseDefinitions: chinese,
            additionalDefinitions: Array(chinese.dropFirst(3)),
            examples: Self.uniqueInlineStrings(examples, maximum: 8),
            collocations: Self.uniqueInlineStrings(relations, maximum: 8),
            inflections: parsed.semanticEntry.inflections,
            roots: isRoot ? Self.uniqueInlineStrings(values, maximum: 8) : [],
            isRootDictionary: isRoot
        )
    }

    private static func inlineExamples(_ sense: DictionarySemanticSense) -> [String] {
        var values = sense.examples.map { example in
            let translations = example.translations.joined(separator: "；")
            return translations.isEmpty ? example.english : "\(example.english) — \(translations)"
        }
        values += sense.subsenses.flatMap(inlineExamples)
        return values
    }

    private static func inlineRelations(_ sense: DictionarySemanticSense) -> [String] {
        var values = sense.relations.flatMap(\.values)
        values += sense.subsenses.flatMap(inlineRelations)
        return values
    }

    private static func uniqueInlineStrings(_ values: [String], maximum: Int) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values {
            let clean = SentenceTextNormalizer.normalize(value)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            output.append(clean)
            if output.count == maximum { break }
        }
        return output
    }

    nonisolated private static func inlineHit(from hit: ManagedDictionaryQueryHit)
        -> InlineLocalDictionaryHit {
        let primary = hit.conciseChineseDefinitions.isEmpty
            ? hit.noteDefinitions : hit.conciseChineseDefinitions
        return InlineLocalDictionaryHit(
            source: hit.displayName,
            partOfSpeech: "",
            chineseDefinitions: primary,
            additionalDefinitions: Array(hit.noteDefinitions.dropFirst(3)),
            examples: [],
            collocations: [],
            inflections: [],
            roots: [],
            isRootDictionary: false
        )
    }

    private func glossarySource(id: DictionarySourceID, name: String,
                                priority: Int) -> LocalGlossaryDictionarySource {
        LocalGlossaryDictionarySource(name: name, priority: priority) { [weak self] term in
            self?.lookupSupplementalGlossary(term, sourceID: id, sourceName: name)
        }
    }

    private func lookupOxfordGlossary(_ term: String) -> LocalGlossaryLookupResult? {
        guard isPreferredDictionaryEnabled(DictionarySourceID.oxfordOALD8.rawValue) else {
            return nil
        }
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
        guard isPreferredDictionaryEnabled(sourceID.rawValue) else { return nil }
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
        let attributed = NSMutableAttributedString(string: value)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.setAttributes([
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ], range: range)
        setInlineBaseContent(attributed)
    }

    private func displayAttributedText(_ value: NSAttributedString) {
        precondition(Thread.isMainThread)
        setInlineBaseContent(value)
    }

    private func setInlineBaseContent(_ value: NSAttributedString) {
        let next = value.copy() as? NSAttributedString ?? value
        let contentChanged = !inlineBaseContent.isEqual(to: next)
        if inlineBaseContent.length > 0, contentChanged {
            if !inlineSupplements.isEmpty { cancelAllInlineLookups(clear: true) }
            inlinePageID = UUID()
            pendingInlineSelection = nil
            hideInlineSelectionButton()
        }
        inlineBaseContent = next
        if contentChanged || inlineBaseBlocks.isEmpty {
            inlineBaseBlocks = InlineBaseBlockBuilder.build(from: next)
        }
        renderInlinePage()
    }

    private func clearInlinePage() {
        cancelAllInlineLookups(clear: true)
        inlinePageID = UUID()
        inlineBaseContent = NSAttributedString(string: "")
        inlineBaseBlocks = []
        pendingInlineSelection = nil
        hideInlineSelectionButton()
    }

    private func cancelAllInlineLookups(clear: Bool) {
        inlineTasks.values.forEach { $0.cancel() }
        inlineTasks.removeAll()
        if clear { inlineSupplements.removeAll() }
    }

    private func renderInlinePage(allowRetry: Bool = true) {
        precondition(Thread.isMainThread)
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        let visibleOrigin = scrollView.contentView.bounds.origin
        let layoutMetrics = currentInlineLayoutMetrics()
        let output = inlinePageRenderer.render(baseBlocks: inlineBaseBlocks,
                                               supplements: inlineSupplements,
                                               layout: layoutMetrics)
        textView.textStorage?.setAttributedString(output)
        textView.needsLayout = true
        textView.needsDisplay = true
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        positionInlineControlButtons()
        if !aiIncludeCheckbox.isHidden { positionAIIncludeCheckbox() }
        if !inlineSupplements.isEmpty, layoutMetrics == nil, allowRetry {
            scheduleInlineLayoutRetry()
        }
    }

    private func currentInlineLayoutMetrics() -> InlineLayoutMetrics? {
        guard let container = textView.textContainer else { return nil }
        let metrics = InlineLayoutMetrics.calculate(
            textContainerWidth: container.containerSize.width,
            textViewWidth: textView.bounds.width,
            lineFragmentPadding: container.lineFragmentPadding,
            pageInsetLeft: textView.textContainerInset.width,
            pageInsetRight: textView.textContainerInset.width
        )
#if DEBUG
        if !didLogInlineLayoutDiagnostics, !inlineSupplements.isEmpty {
            didLogInlineLayoutDiagnostics = true
            NSLog("Inline layout: container=%.1f available=%.1f content=%.1f indent=0 tail=0 first=0 attachment=none",
                  metrics.textContainerWidth, metrics.availableWidth, metrics.blockContentWidth)
        }
#endif
        return metrics.isUsable ? metrics : nil
    }

    private func scheduleInlineLayoutRetry() {
        guard !inlineLayoutRetryScheduled else { return }
        inlineLayoutRetryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inlineLayoutRetryScheduled = false
            self.renderInlinePage(allowRetry: false)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard notification.object as? NSTextView === textView else { return }
        updateInlineSelectionButton()
    }

    private func updateInlineSelectionButton() {
        let range = textView.selectedRange()
        guard range.length > 0, let storage = textView.textStorage,
              NSMaxRange(range) <= storage.length,
              !renderedRangeContainsInlineSupplement(range),
              let snapshot = InlineSelectionSnapshotFactory.capture(
                from: storage,
                selectedRange: range,
                pageGenerationID: inlinePageID,
                currentEntryID: currentInlineEntryID
              ) else {
            hideInlineSelectionButton()
            return
        }
        pendingInlineSelection = snapshot
        inlineSelectionButton.title = snapshot.selectionKind == .sentence ? "翻译" : "查词"
        inlineSelectionButton.sizeToFit()
        inlineSelectionButton.frame.size = NSSize(
            width: max(48, inlineSelectionButton.frame.width + 12), height: 23
        )
        inlineSelectionButton.isHidden = !positionInlineSelectionButton(for: range)
    }

    private func renderedRangeContainsInlineSupplement(_ range: NSRange) -> Bool {
        var contains = false
        textView.textStorage?.enumerateAttribute(.inlineSupplementID, in: range) { value, _, stop in
            if value != nil { contains = true; stop.pointee = true }
        }
        return contains
    }

    @discardableResult
    private func positionInlineSelectionButton(for range: NSRange) -> Bool {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return false
        }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var lineRects: [NSRect] = []
        var usedLineRects: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, lineGlyphs, _ in
            let selectedGlyphs = NSIntersectionRange(glyphs, lineGlyphs)
            guard selectedGlyphs.length > 0 else { return }
            let textRect = layout.boundingRect(forGlyphRange: selectedGlyphs, in: container)
                .offsetBy(dx: self.textView.textContainerOrigin.x,
                          dy: self.textView.textContainerOrigin.y)
            lineRects.append(self.scrollView.convert(textRect, from: self.textView))
            let fullLine = usedRect.offsetBy(dx: self.textView.textContainerOrigin.x,
                                             dy: self.textView.textContainerOrigin.y)
            usedLineRects.append(self.scrollView.convert(fullLine, from: self.textView))
        }
        let visible = scrollView.contentView.frame
        var occupiedTextRects: [NSRect] = []
        let allGlyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: allGlyphs) { _, usedRect, _, _, _ in
            let textRect = usedRect.offsetBy(dx: self.textView.textContainerOrigin.x,
                                             dy: self.textView.textContainerOrigin.y)
            let converted = self.scrollView.convert(textRect, from: self.textView)
            if converted.intersects(visible) { occupiedTextRects.append(converted) }
        }
        let anchorBlockRect = pendingInlineSelection.flatMap {
            renderedRect(forBaseBlockID: $0.anchor.blockID, layout: layout, container: container)
        }
        guard let result = InlineFloatingButtonLayout.place(
            buttonSize: inlineSelectionButton.frame.size,
            selectionLineRects: lineRects,
            visibleRect: visible,
            selectionLineUsedRects: usedLineRects,
            anchorBlockRect: anchorBlockRect,
            occupiedTextRects: occupiedTextRects
        ) else { return false }
        inlineSelectionButton.frame = result.frame
        return true
    }

    private func renderedRect(forBaseBlockID blockID: UUID, layout: NSLayoutManager,
                              container: NSTextContainer) -> NSRect? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        var renderedRange: NSRange?
        storage.enumerateAttribute(.inlineBaseBlockID,
                                   in: NSRange(location: 0, length: storage.length)) {
            value, range, stop in
            if (value as? String) == blockID.uuidString {
                renderedRange = range
                stop.pointee = true
            }
        }
        guard let renderedRange else { return nil }
        let glyphRange = layout.glyphRange(forCharacterRange: renderedRange,
                                           actualCharacterRange: nil)
        let textRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        return scrollView.convert(textRect, from: textView)
    }

    private func hideInlineSelectionButton(clearSnapshot: Bool = true) {
        inlineSelectionButton.isHidden = true
        if clearSnapshot { pendingInlineSelection = nil }
    }

    @objc private func inlineScrollBoundsDidChange(_ notification: Notification) {
        guard !inlineSelectionButton.isHidden, pendingInlineSelection != nil else { return }
        let positioned = positionInlineSelectionButton(for: textView.selectedRange())
        if !positioned { hideInlineSelectionButton() }
    }

    func windowDidResize(_ notification: Notification) {
        renderInlinePage()
        if !inlineSelectionButton.isHidden, pendingInlineSelection != nil,
           !positionInlineSelectionButton(for: textView.selectedRange()) {
            hideInlineSelectionButton(clearSnapshot: false)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hideInlineSelectionButton()
        window?.level = .normal
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.level = .floating
    }

    @objc private func performInlineLookupFromSelection() {
        guard let snapshot = pendingInlineSelection, let storage = textView.textStorage else {
            return
        }
        guard InlineSelectionSnapshotFactory.validate(
            snapshot, in: storage, pageGenerationID: inlinePageID,
            currentEntryID: currentInlineEntryID
        ), inlineBaseBlocks.contains(where: { $0.blockID == snapshot.anchor.blockID }) else {
            hideInlineSelectionButton()
            showFeedback("页面内容已变化，请重新选择文字")
            return
        }
        hideInlineSelectionButton()
        if let existing = inlineSupplements.first(where: {
            $0.duplicateKey == snapshot.duplicateKey
        }) {
            scrollInlineSupplementToVisible(existing.supplementID)
            return
        }
        let id = UUID()
        let pageID = inlinePageID
        inlineSupplements.append(InlineLookupSupplement(
            supplementID: id,
            parentEntryID: pageID,
            selectionSnapshot: snapshot,
            quickResult: nil,
            expandedResult: nil,
            preparedLocalExpansion: nil,
            localSource: nil,
            aiProvider: nil,
            aiModel: nil,
            state: .loadingQuick,
            generation: 1
        ))
        renderInlinePage()
        let task = Task { [weak self] in
            guard let self else { return }
            switch snapshot.selectionKind {
            case .sentence:
                await self.performInlineSentenceQuick(id: id, pageID: pageID,
                                                      text: snapshot.selectedText,
                                                      normalizedText: snapshot.normalizedText,
                                                      generation: 1)
            case .word, .phrase:
                await self.performInlineWordQuick(id: id, pageID: pageID,
                                                  text: snapshot.selectedText,
                                                  normalizedText: snapshot.normalizedText,
                                                  generation: 1)
            }
        }
        inlineTasks[id] = task
    }

    private var currentInlineEntryID: String {
        let kind: String
        switch currentIntent {
        case .word: kind = "word"
        case .phrase: kind = "phrase"
        case .sentence: kind = "sentence"
        case .textTooLong: kind = "invalid"
        }
        return "\(kind)|\(currentQuery.precomposedStringWithCanonicalMapping)"
    }

    private func performInlineWordQuick(id: UUID, pageID: UUID, text: String,
                                        normalizedText: String, generation: UInt64) async {
        let local = await inlineLocalLookupService.lookup(text)
        guard !Task.isCancelled else { return }
        if let quick = local.quick {
            await MainActor.run {
                self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                            expectedNormalizedText: normalizedText) {
                    $0.quickResult = .word(quick)
                    $0.preparedLocalExpansion = local.expansion
                    $0.localSource = quick.source
                    $0.state = .success
                }
            }
            return
        }
        let mayRequestAI = await MainActor.run {
            self.inlineQueryStillValid(id: id, pageID: pageID, generation: generation,
                                       expectedNormalizedText: normalizedText)
        }
        guard mayRequestAI, !Task.isCancelled else { return }
        do {
            let quick = try await aiService.inlineWordQuick(text)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                            expectedNormalizedText: normalizedText) {
                    $0.quickResult = .word(quick)
                    $0.preparedLocalExpansion = local.expansion
                    $0.aiProvider = quick.providerDisplayName
                    $0.aiModel = quick.model
                    $0.state = .success
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            let message = Self.inlineFailureMessage(error, localMiss: true)
            await MainActor.run {
                self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                            expectedNormalizedText: normalizedText) {
                    $0.state = .failed(message)
                }
            }
        }
    }

    private func performInlineSentenceQuick(id: UUID, pageID: UUID, text: String,
                                            normalizedText: String, generation: UInt64) async {
        let mayRequestAI = await MainActor.run {
            self.inlineQueryStillValid(id: id, pageID: pageID, generation: generation,
                                       expectedNormalizedText: normalizedText)
        }
        guard mayRequestAI, !Task.isCancelled else { return }
        do {
            let result = try await aiService.inlineSentenceQuick(text)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                            expectedNormalizedText: normalizedText) {
                    $0.quickResult = .sentence(result)
                    $0.aiProvider = result.providerDisplayName
                    $0.aiModel = result.model
                    $0.state = .success
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                            expectedNormalizedText: normalizedText) {
                    $0.state = .failed(Self.inlineFailureMessage(error, localMiss: false))
                }
            }
        }
    }

    private static func inlineFailureMessage(_ error: Error, localMiss: Bool) -> String {
        if localMiss, error is AIConfigurationError { return "本地词典未收录" }
        if localMiss, let client = error as? AIClientError,
           client == .offline || client == .timeout { return "本地词典未收录" }
        return error.localizedDescription
    }

    private func updateInlineSupplement(id: UUID, pageID: UUID, generation: UInt64,
                                        expectedNormalizedText: String,
                                        mutate: (inout InlineLookupSupplement) -> Void) {
        guard inlinePageID == pageID,
              let index = inlineSupplements.firstIndex(where: {
                $0.supplementID == id && $0.parentEntryID == pageID &&
                    $0.generation == generation &&
                    $0.normalizedText == expectedNormalizedText
              }),
              inlineBaseBlocks.contains(where: {
                $0.blockID == inlineSupplements[index].anchor.blockID
              }) else { return }
        mutate(&inlineSupplements[index])
        inlineTasks[id] = nil
        renderInlinePage()
        refreshStarState()
    }

    private func inlineQueryStillValid(id: UUID, pageID: UUID, generation: UInt64,
                                       expectedNormalizedText: String) -> Bool {
        guard inlinePageID == pageID,
              let supplement = inlineSupplements.first(where: {
                $0.supplementID == id && $0.parentEntryID == pageID &&
                    $0.generation == generation &&
                    $0.normalizedText == expectedNormalizedText &&
                    $0.selectionSnapshot.pageGenerationID == pageID
              }),
              inlineBaseBlocks.contains(where: { $0.blockID == supplement.anchor.blockID }) else {
            return false
        }
        return InlineSelectionSnapshotFactory.normalizedIdentity(
            supplement.selectedText, kind: supplement.selectionKind
        ) == expectedNormalizedText
    }

    @objc private func expandInlineSupplement(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let index = inlineSupplements.firstIndex(where: { $0.supplementID == id }),
              inlineSupplements[index].quickResult != nil,
              inlineSupplements[index].expandedResult == nil else { return }
        inlineTasks[id]?.cancel()
        inlineSupplements[index].generation &+= 1
        let generation = inlineSupplements[index].generation
        let pageID = inlinePageID
        if let local = inlineSupplements[index].preparedLocalExpansion, local.hasContent {
            inlineSupplements[index].expandedResult = .local(local)
            let sources = Self.uniqueInlineStrings(
                [inlineSupplements[index].localSource ?? ""] + local.sources,
                maximum: 5
            )
            inlineSupplements[index].localSource = sources.joined(separator: "、")
            inlineSupplements[index].state = .success
            renderInlinePage()
            refreshStarState()
            return
        }
        let text = inlineSupplements[index].selectedText
        let normalizedText = inlineSupplements[index].normalizedText
        let kind = inlineSupplements[index].selectionKind
        inlineSupplements[index].state = .loadingExpansion
        renderInlinePage()
        let task = Task { [weak self] in
            guard let self else { return }
            let mayRequestAI = await MainActor.run {
                self.inlineQueryStillValid(id: id, pageID: pageID, generation: generation,
                                           expectedNormalizedText: normalizedText)
            }
            guard mayRequestAI, !Task.isCancelled else { return }
            do {
                let expanded: InlineLookupExpandedResult
                switch kind {
                case .sentence:
                    expanded = .aiSentence(try await self.aiService.inlineSentenceExpansion(text))
                case .word, .phrase:
                    expanded = .aiWord(try await self.aiService.inlineWordExpansion(text))
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.updateInlineSupplement(id: id, pageID: pageID,
                                                generation: generation,
                                                expectedNormalizedText: normalizedText) {
                        $0.expandedResult = expanded
                        switch expanded {
                        case .aiWord(let value):
                            $0.aiProvider = value.providerDisplayName; $0.aiModel = value.model
                        case .aiSentence(let value):
                            $0.aiProvider = value.providerDisplayName; $0.aiModel = value.model
                        case .local: break
                        }
                        $0.state = .success
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.updateInlineSupplement(id: id, pageID: pageID,
                                                generation: generation,
                                                expectedNormalizedText: normalizedText) {
                        $0.state = .failed(error.localizedDescription)
                    }
                }
            }
        }
        inlineTasks[id] = task
    }

    @objc private func closeInlineSupplement(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let index = inlineSupplements.firstIndex(where: { $0.supplementID == id }) else {
            return
        }
        inlineTasks[id]?.cancel()
        inlineTasks[id] = nil
        inlineSupplements[index].generation &+= 1
        inlineSupplements.remove(at: index)
        renderInlinePage()
        refreshStarState()
    }

    private func positionInlineControlButtons() {
        inlineControlButtons.forEach { $0.removeFromSuperview() }
        inlineControlButtons.removeAll()
        guard let storage = textView.textStorage, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        for supplement in inlineSupplements {
            let marker = supplement.supplementID.uuidString
            var anchorRange: NSRange?
            storage.enumerateAttribute(.inlineControlAnchor,
                                       in: NSRange(location: 0, length: storage.length)) {
                value, range, stop in
                if value as? String == marker { anchorRange = range; stop.pointee = true }
            }
            guard let range = anchorRange else { continue }
            let glyph = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            var x = rect.minX + 12
            if supplement.quickResult != nil && supplement.expandedResult == nil {
                let more = inlineControlButton(title: supplement.state == .loadingExpansion
                                               ? "正在展开…" : "了解更多",
                                               id: supplement.supplementID,
                                               action: #selector(expandInlineSupplement))
                more.isEnabled = supplement.state != .loadingExpansion
                more.frame.origin = NSPoint(x: x, y: rect.minY)
                x += more.frame.width + 8
            }
            let close = inlineControlButton(title: "关闭", id: supplement.supplementID,
                                            action: #selector(closeInlineSupplement))
            close.frame.origin = NSPoint(x: x, y: rect.minY)
        }
    }

    private func inlineControlButton(title: String, id: UUID, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        button.isBordered = false
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10.5, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.sizeToFit()
        button.frame.size.height = 18
        textView.addSubview(button)
        inlineControlButtons.append(button)
        return button
    }

    private func scrollInlineSupplementToVisible(_ id: UUID) {
        guard let storage = textView.textStorage else { return }
        storage.enumerateAttribute(.inlineSupplementID,
                                   in: NSRange(location: 0, length: storage.length)) {
            value, range, stop in
            if value as? String == id.uuidString {
                self.textView.scrollRangeToVisible(range)
                stop.pointee = true
            }
        }
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
        let inlineItems = inlineMarkdownFormatter.items(from: inlineSupplements)
        if currentIntent == .sentence {
            let base = sentenceMarkdownFormatter.content(
                sourceText: currentQuery,
                aiPresentation: currentSentencePresentation,
                glossary: currentLocalGlossary
            )
            guard base != nil || !inlineItems.isEmpty else { return nil }
            let content = SentenceNoteSaveContent(
                sourceText: base?.sourceText ?? currentQuery,
                title: base?.title ?? sentenceMarkdownFormatter.title(for: currentQuery),
                aiSectionMarkdown: base?.aiSectionMarkdown,
                glossarySectionMarkdown: base?.glossarySectionMarkdown,
                inlineSupplements: inlineItems
            )
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
                                                aiSection: aiSection,
                                                inlineSupplements: inlineItems)
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
