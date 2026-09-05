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

private struct CombinedDictionaryPresentation {
    let dictionaryID: String
    let order: Int64
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

private final class DictionaryAppearanceView: NSVisualEffectView {
    var appearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
    }
}

final class DictionaryPanelController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
                                       NSTextViewDelegate, GlobalSelectionWindowHosting {
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
    private let longTextFormatter = LongTextResultFormatter()
    private let genericManagedPresenter = GenericManagedDictionaryPresenter()
    private lazy var inlinePageRenderer = InlinePageRenderer(formatter: inlineAttributedFormatter)
    private let searchField = NSSearchField()
    private let starButton = NSButton()
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let aiFooter = NSStackView()
    private let localActionGroup = NSStackView()
    private let remoteAIActionGroup = NSStackView()
    private let aiStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let aiActionButton = NSButton()
    private let aiTranslationButton = NSButton()
    private let aiSettingsButton = NSButton()
    private let aiClearCacheButton = NSButton()
    private let aiIncludeCheckbox = NSButton(
        checkboxWithTitle: "收藏时加入 AI 内容", target: nil, action: nil
    )
    private let systemTranslationHost = SystemTranslationHostController()
    private let offlineActionButton = NSButton()
    private let reverseIndexButton = NSButton()
    private var aiFooterHeightConstraint: NSLayoutConstraint?
    private var currentEntry: StructuredDictionaryEntry?
    private var currentQuery = ""
    private var currentIntent: QueryIntent = .word
    private var localResultContent: NSAttributedString?
    private var localResultHasChinese = false
    private var aiAction: AIAction = .none
    private var aiTask: Task<Void, Never>?
    private var aiTranslationTask: Task<Void, Never>?
    private var aiRequestLifecycle = AIRequestLifecycle()
    private var localGlossaryTask: Task<Void, Never>?
    private var longTextTask: Task<Void, Never>?
    private var reverseLookupTask: Task<Void, Never>?
    private var reverseBuildTask: Task<Void, Never>?
    private var offlineAvailabilityTask: Task<Void, Never>?
    private var offlineActionTask: Task<Void, Never>?
    private var offlineActionGeneration: UInt64 = 0
    private var managedQueryTask: Task<Void, Never>?
    private var managedCatalogGeneration: UInt64 = 0
    private var preferredCatalogDescriptors: [String: DictionaryDescriptor] = [:]
    private var currentAIPresentation: AIExplanationPresentation?
    private var currentSentencePresentation: AISentenceAnalysisPresentation?
    private var currentSentenceStudyText: StudyText?
    private var currentLocalGlossary: LocalSentenceGlossary?
    private var currentSentenceStatus: String?
    private var currentLongTextResult: LongTextAnalysisResult?
    private var currentLongTextAI: [String: AISentenceAnalysisPresentation] = [:]
    private var currentLongTextAIStates: [String: LongTextAISentenceState] = [:]
    private var longTextSentenceAITasks: [String: Task<Void, Never>] = [:]
    private var longTextSentenceAIGate = AISentenceOperationGate()
    private var longTextSentenceAICancellationReasons: [UUID: AIRequestCancellationReason] = [:]
    private var currentLongTextTranslation: AITextTranslationPresentation?
    private var currentLongTextAIStudyText: AIStudyText?
    private var currentLongTextAIStudyTextTask:
        Task<CanonicalAIStudyTextResolution, Error>?
    private var currentOfflineStudyTexts: [String: OfflineStudyText] = [:]
    private var currentLongTextTranslationStatus: String?
    private var currentLongTextTranslationDisplay: LongTextAITranslationDisplay? {
        currentLongTextTranslation.map {
            LongTextAITranslationDisplay(
                translation: $0.result.translation,
                providerDisplayName: $0.providerDisplayName,
                model: $0.model,
                fromCache: $0.fromCache,
                isPartial: $0.result.responseParseMode.isPartial
            )
        }
    }
    private var directionTasks: [String: Task<Void, Never>] = [:]
    private var directionGenerationGate = SentenceDirectionGenerationGate()
    private var longTextResultRevision: UInt64 = 0
    private var offlineActionPair: OfflineTranslationPair?
    private var offlineActionSource = ""
    private var offlineActionAutoStart = false
    private var shortNativeOfflineResult: OfflineTranslationResponse?
    private var shortNativeLocalDisplay: NSAttributedString?
    private var shortNativeOfflineStatus = ""
    private var shortLearningOfflineResult: OfflineTranslationResponse?
    private var shortLearningLocalDisplay: NSAttributedString?
    private var shortLearningOfflineStatus = ""
    private var aiSectionCharacterLocation: Int?
    private var queryGeneration = AIQueryGenerationGate()
    private var feedbackPopover: NSPopover?
    nonisolated(unsafe) private var localKeyMonitor: Any?
    private var tripleReturnAITrigger = TripleReturnAITrigger()
    private var pendingTripleReturnAITask: Task<Void, Never>?
    private var isShowingNoteMenu = false
    private var animating = false
    private let globalSelectionPlacement = GlobalSelectionPlacementController()
    private var pendingGlobalSelectionContext: GlobalSelectionContext?
    private var pendingGlobalSelectionFrame: CGRect?
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
    private let reverseLookupService: ReverseLookupService
    private let reverseIndexCoordinator: ReverseIndexCoordinator
    private let backgroundWorkCoordinator: LocalHeavyWorkCoordinator
    private var reverseDictionarySources: [ReverseDictionarySource]
    private var offlineTranslation: OfflineTranslationCoordinator!
    private lazy var longTextPipeline = LongTextAnalysisPipeline(
        translation: offlineTranslation,
        glossary: localGlossaryService
    )

    private enum AIAction: Equatable {
        case none
        case configure
        case explain(domain: String, bypassCache: Bool)
        case analyzeSentence(bypassCache: Bool)
        case analyzeLongText
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
         reverseLookupService: ReverseLookupService,
         reverseIndexCoordinator: ReverseIndexCoordinator,
         backgroundWorkCoordinator: LocalHeavyWorkCoordinator,
         reverseDictionarySources: [ReverseDictionarySource] = [],
         offlineTranslationOverride: OfflineTranslationCoordinator? = nil,
         openAISettings: @escaping () -> Void) {
        oxfordCore = core
        self.supplementalDictionaries = supplementalDictionaries.sorted {
            $0.priority < $1.priority
        }
        self.noteStore = noteStore
        self.notePicker = notePicker
        self.aiService = aiService
        self.managedDictionaryQueryService = managedDictionaryQueryService
        self.reverseLookupService = reverseLookupService
        self.reverseIndexCoordinator = reverseIndexCoordinator
        self.backgroundWorkCoordinator = backgroundWorkCoordinator
        self.reverseDictionarySources = reverseDictionarySources
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
                                    styleMask: DictionaryPanelInteractionPolicy.styleMask,
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
        if let offlineTranslationOverride {
            offlineTranslation = offlineTranslationOverride
        } else {
            offlineTranslation = OfflineTranslationCoordinator(
                maximumConcurrentTasks: 1,
                heavyWorkCoordinator: backgroundWorkCoordinator
            ) { [weak model = systemTranslationHost.model] in
                guard let model else { throw OfflineTranslationError.hostEnded }
                return await SystemTranslationEngine(model: model)
            }
        }
        configure(panel)
        installEventMonitors()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        aiTask?.cancel()
        aiTranslationTask?.cancel()
        localGlossaryTask?.cancel()
        longTextTask?.cancel()
        reverseLookupTask?.cancel()
        reverseBuildTask?.cancel()
        offlineAvailabilityTask?.cancel()
        offlineActionGeneration &+= 1
        offlineActionTask?.cancel()
        directionTasks.values.forEach { $0.cancel() }
        managedQueryTask?.cancel()
        longTextSentenceAITasks.values.forEach { $0.cancel() }
        longTextSentenceAIGate.invalidateAll()
        inlineTasks.values.forEach { $0.cancel() }
        pendingTripleReturnAITask?.cancel()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    func prepareForTermination() {
        aiTask?.cancel()
        aiTranslationTask?.cancel()
        localGlossaryTask?.cancel()
        longTextTask?.cancel()
        reverseLookupTask?.cancel()
        reverseBuildTask?.cancel()
        offlineAvailabilityTask?.cancel()
        offlineActionGeneration &+= 1
        offlineActionTask?.cancel()
        managedQueryTask?.cancel()
        directionTasks.values.forEach { $0.cancel() }
        cancelAllLongTextSentenceAI(reason: .appQuit)
        inlineTasks.values.forEach { $0.cancel() }
        reverseIndexCoordinator.cancel()
        systemTranslationHost.detach()
        feedbackPopover?.close()
        window?.orderOut(nil)
    }

    var terminationActivity: (reverseIndexActive: Bool, translationWaitActive: Bool) {
        (
            reverseLookupTask != nil || reverseBuildTask != nil,
            offlineAvailabilityTask != nil || offlineActionTask != nil ||
                systemTranslationHost.model.hasPendingOperations
        )
    }

    var isVisible: Bool { window?.isVisible == true }

    func updateDictionaryCatalog(_ catalog: DictionaryCatalog) {
        managedCatalogGeneration &+= 1
        managedQueryTask?.cancel()
        managedQueryTask = nil
        directionTasks.values.forEach { $0.cancel() }
        directionTasks.removeAll()
        longTextTask?.cancel()
        longTextTask = nil
        offlineAvailabilityTask?.cancel()
        offlineAvailabilityTask = nil
        offlineActionGeneration &+= 1
        offlineActionTask?.cancel()
        offlineActionTask = nil
        reverseLookupTask?.cancel()
        reverseLookupTask = nil
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
        longTextTask?.cancel()
        longTextTask = nil
        reverseLookupTask?.cancel()
        reverseLookupTask = nil
        inlineTasks.values.forEach { $0.cancel() }
        inlineTasks.removeAll()
    }

    func updateReverseDictionarySources(_ sources: [ReverseDictionarySource]) {
        reverseDictionarySources = sources
        if currentIntent == .word, isNativeLanguageLookup(currentQuery) {
            reverseIndexButton.isHidden = !sources.contains {
                $0.reverseCapability.isBuildEligible
            }
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    @discardableResult
    func showAndLookup(_ query: String,
                       globalSelectionContext: GlobalSelectionContext? = nil,
                       generation: UInt64? = nil) -> Bool {
        updateGlobalSelectionContext(
            globalSelectionContext, generation: generation, expectedText: query
        )
        let found = processQuery(query)
        show()
        return found
    }

    #if REVERSE_INDEX_CONTROLLER_TESTING
    func waitForPanelTesting(milliseconds: Int = 250) async {
        let slices = max(1, milliseconds / 10)
        for _ in 0..<slices {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func submitSearchReturnForTesting(_ query: String) {
        searchField.stringValue = query
        performSearch()
    }

    func panelTestingSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [
            "currentQuery": currentQuery,
            "content": textView.string,
            "offlineTitle": offlineActionButton.title,
            "offlineVisible": !offlineActionButton.isHidden,
            "offlineEnabled": offlineActionButton.isEnabled,
            "aiTitle": aiActionButton.title,
            "aiVisible": !aiActionButton.isHidden,
            "aiEnabled": aiActionButton.isEnabled,
            "aiTranslationTitle": aiTranslationButton.title,
            "aiTranslationVisible": !aiTranslationButton.isHidden,
            "aiTranslationEnabled": aiTranslationButton.isEnabled,
            "status": aiStatusLabel.stringValue,
            "starEnabled": starButton.isEnabled,
            "starValue": starButton.accessibilityValue() as? String ?? "",
            "aiIncludeVisible": !aiIncludeCheckbox.isHidden,
            "aiIncludeOn": aiIncludeCheckbox.state == .on,
            "aiCacheControlVisible": !aiClearCacheButton.isHidden,
            "aiCacheControlTitle": aiClearCacheButton.title,
            "aiCacheControlBordered": aiClearCacheButton.isBordered,
            "aiCacheControlClass": String(describing: type(of: aiClearCacheButton)),
            "aiCacheControlInstanceCount": remoteAIActionGroup.arrangedSubviews.filter {
                $0 === aiClearCacheButton
            }.count,
            "canonicalAIStudyText": currentLongTextAIStudyText?.studyText.text ?? "",
            "deepAITranslationText": currentLongTextTranslation?.result.translation ?? "",
            "sentenceAIResultCount": currentLongTextAI.count,
            "offlineStudyTextCount": currentOfflineStudyTexts.count,
            "hasLongTextResult": currentLongTextResult != nil
        ]
        if let content = currentNoteSaveContent() {
            switch content {
            case .vocabulary(let value):
                snapshot["noteKind"] = "vocabulary"
                snapshot["noteHasLocal"] = value.localEntry != nil
                snapshot["noteHasAI"] = value.aiSection != nil
                snapshot["noteMarkdown"] = value.aiSection?.markdown ?? ""
                snapshot["noteLanguageMetadata"] = value.languageMetadata?.markdownComment ?? ""
            case .sentence(let value):
                snapshot["noteKind"] = "sentence"
                snapshot["noteHasLocal"] = value.validGlossarySection
                snapshot["noteHasAI"] = value.validAISection
                snapshot["noteMarkdown"] = [
                    value.glossarySectionMarkdown, value.aiSectionMarkdown
                ].compactMap { $0 }.joined(separator: "\n\n")
                snapshot["noteLanguageMetadata"] = value.languageMetadata?.markdownComment ?? ""
            }
        }
        if let result = currentLongTextResult {
            snapshot["studyLanguageCodes"] = result.sentences.compactMap {
                $0.studyText?.language.rawValue
            }
            snapshot["studyTexts"] = result.sentences.compactMap(\.studyText?.text)
            snapshot["aiAnalysisSourceTexts"] = result.sentences.compactMap {
                currentLongTextAI[$0.id]?.analysis.sourceText
            }
            snapshot["aiSentenceTranslations"] = result.sentences.compactMap {
                currentLongTextAI[$0.id]?.analysis.translationZH
            }
        }
        return snapshot
    }

    func triggerOfflineActionForTesting() -> Bool {
        guard !offlineActionButton.isHidden, offlineActionButton.isEnabled else {
            return false
        }
        offlineActionButton.performClick(nil)
        return true
    }

    func triggerLongTextAITranslationForTesting() -> Bool {
        guard !aiTranslationButton.isHidden, aiTranslationButton.isEnabled else {
            return false
        }
        aiTranslationButton.performClick(nil)
        return true
    }

    func triggerLongTextAIAnalysisForTesting() -> Bool {
        guard !aiActionButton.isHidden, aiActionButton.isEnabled,
              currentLongTextResult != nil else { return false }
        aiActionButton.performClick(nil)
        return true
    }

    func clearCurrentAICacheForTesting() {
        clearCurrentAICache()
    }

    func injectWordAIPresentationForTesting(_ presentation: AIExplanationPresentation) {
        currentAIPresentation = presentation
        if isNativeLanguageLookup(currentQuery) {
            aiIncludeCheckbox.state = .on
            aiIncludeCheckbox.isHidden = true
        } else {
            aiIncludeCheckbox.state = .off
            aiIncludeCheckbox.isHidden = false
        }
        refreshStarState()
    }

    func injectLongTextAIForTesting(deepTranslation: String,
                                    sentenceTranslation: String,
                                    provider: String,
                                    model: String) {
        guard let result = currentLongTextResult else { return }
        currentLongTextTranslation = AITextTranslationPresentation(
            result: AITextTranslation(
                sourceText: result.sourceText,
                translation: deepTranslation
            ),
            providerDisplayName: provider,
            model: model,
            fromCache: false
        )
        currentLongTextTranslationStatus = nil
        applyAIStudyTranslation(deepTranslation, to: result)
        guard let updated = currentLongTextResult,
              let first = updated.sentences.first,
              let studyText = first.studyText else { return }
        currentLongTextAI[first.id] = AISentenceAnalysisPresentation(
            analysis: AISentenceAnalysis(
                sourceText: studyText.text,
                translationZH: sentenceTranslation,
                learningNoteZH: "测试学习提示"
            ),
            providerDisplayName: provider,
            model: model,
            fromCache: false
        )
        currentLongTextAIStates[first.id] = .success
        aiIncludeCheckbox.state = .on
        renderLongTextResult(updated)
    }

    func saveCurrentNoteForTesting(to url: URL) -> Bool {
        guard let content = currentNoteSaveContent() else { return false }
        do {
            switch content {
            case .vocabulary(let value):
                _ = try noteStore.createOrSave(value, at: url)
            case .sentence(let value):
                _ = try noteStore.createOrSave(value, at: url)
            }
            try noteStore.rememberTarget(url)
            refreshStarState()
            return true
        } catch {
            return false
        }
    }
    #endif

    func showSelectionTooLongMessage(
        globalSelectionContext: GlobalSelectionContext? = nil,
        generation: UInt64? = nil
    ) {
        updateGlobalSelectionContext(
            globalSelectionContext, generation: generation, expectedText: nil
        )
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
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        currentLongTextAIStudyTextTask?.cancel()
        currentLongTextAIStudyTextTask = nil
        aiRequestLifecycle.invalidate()
        _ = queryGeneration.beginQuery()
        currentAIPresentation = nil
        currentSentencePresentation = nil
        currentSentenceStudyText = nil
        currentLongTextAIStudyText = nil
        currentSentenceStatus = nil
        currentLongTextTranslation = nil
        currentLongTextTranslationStatus = nil
        currentLongTextAIStates = currentLongTextAIStates.mapValues { _ in .idle }
        aiSectionCharacterLocation = nil
        aiIncludeCheckbox.state = .off
        aiIncludeCheckbox.isHidden = true
        aiStatusLabel.stringValue = ""
        aiClearCacheButton.isHidden = true
        if currentIntent == .sentence {
            if let result = currentLongTextResult {
                renderLongTextResult(result)
            } else {
                renderSentenceContent()
            }
        } else if isNativeLanguageLookup(currentQuery) {
            renderShortNativeLookup()
        } else if let localResultContent {
            displayAttributedText(localResultContent)
        }
        if currentIntent == .sentence, currentLongTextResult != nil {
            configureLongTextAIAction()
        } else if currentIntent == .sentence, currentSentencePresentation == nil {
            configureSentenceAction(for: currentQuery)
        } else if currentIntent != .sentence {
            configureAIAction(hasLocalResult: currentEntry?.isValid == true,
                              hasChinese: localResultHasChinese)
        }
    }

    func show() {
        guard let panel = window as? DictionaryPanel, !animating else { return }
        animating = true
        let selectionContext = pendingGlobalSelectionContext
        let finalFrame: NSRect
        if let selectionContext {
            pendingGlobalSelectionFrame = nil
            let active = activeScreen()
            let displays = SelectionDisplayGeometry.liveScreens()
            guard globalSelectionPlacement.present(
                selectionContext,
                displays: displays,
                fallbackDisplayID: Self.displayID(for: active),
                host: self
            ), let placementFrame = pendingGlobalSelectionFrame,
               globalSelectionPlacement.selectedText(
                   for: selectionContext.generation
               ) == selectionContext.selectedText else {
                animating = false
                panel.orderOut(nil)
                return
            }
            finalFrame = placementFrame
        } else {
            finalFrame = shownFrame(for: activeScreen(), panelSize: panel.frame.size)
        }
        var startFrame = finalFrame
        if selectionContext == nil { startFrame.origin.x += 24 }
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if selectionContext == nil {
            // A non-activating panel can accept typing without moving a full-screen source app
            // to another Space. `orderFrontRegardless` plus fullScreenAuxiliary keeps it visible
            // above Zotero/PDF/browser plug-ins that own the current full-screen Space.
            panel.makeKey()
            panel.makeFirstResponder(searchField)
        }
        ManualEvidenceRecorder.shared.record(
            "globalPanelPresented",
            strings: [
                "presentationMode": selectionContext == nil
                    ? "currentSpaceSearch" : "anchoredSelection",
                "windowLevel": "floating"
            ],
            booleans: [
                "nonactivatingPanel": panel.styleMask.contains(.nonactivatingPanel),
                "canJoinAllSpaces": panel.collectionBehavior.contains(.canJoinAllSpaces),
                "fullScreenAuxiliary": panel.collectionBehavior.contains(.fullScreenAuxiliary)
            ]
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.animating = false }
        }
    }

    func hide() {
        guard let panel = window as? DictionaryPanel, panel.isVisible, !animating else { return }
        aiTask?.cancel()
        aiTask = nil
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        currentLongTextAIStudyTextTask?.cancel()
        currentLongTextAIStudyTextTask = nil
        aiRequestLifecycle.invalidate()
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        managedQueryTask?.cancel()
        managedQueryTask = nil
        directionTasks.values.forEach { $0.cancel() }
        directionTasks.removeAll()
        directionGenerationGate.invalidateAll()
        cancelAllLongTextSentenceAI(reason: .userQueryChanged)
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
            Task { @MainActor in
                panel?.orderOut(nil)
                panel?.alphaValue = 1
                self?.animating = false
                self?.pendingGlobalSelectionContext = nil
                self?.pendingGlobalSelectionFrame = nil
            }
        }
    }

    func invalidateGlobalSelection(generation: UInt64) {
        pendingGlobalSelectionContext = nil
        pendingGlobalSelectionFrame = nil
        globalSelectionPlacement.invalidate(generation: generation, host: self)
    }

    func isPresentingGlobalSelection(generation: UInt64) -> Bool {
        pendingGlobalSelectionContext?.generation == generation &&
            globalSelectionPlacement.currentGeneration == generation &&
            window?.isVisible == true
    }

    func refreshGlobalSelection(_ context: GlobalSelectionContext) -> Bool {
        guard pendingGlobalSelectionContext?.generation == context.generation,
              globalSelectionPlacement.refresh(context) else { return false }
        pendingGlobalSelectionContext = context
        return true
    }

    func repositionGlobalSelection(_ context: GlobalSelectionContext) {
        guard SentenceTextNormalizer.normalize(context.selectedText) == currentQuery,
              let panel = window as? DictionaryPanel, panel.isVisible else {
            invalidateGlobalSelection(generation: context.generation)
            return
        }
        pendingGlobalSelectionContext = context
        pendingGlobalSelectionFrame = nil
        let active = activeScreen()
        guard globalSelectionPlacement.present(
            context,
            displays: SelectionDisplayGeometry.liveScreens(),
            fallbackDisplayID: Self.displayID(for: active),
            host: self
        ), pendingGlobalSelectionFrame != nil else {
            hide()
            invalidateGlobalSelection(generation: context.generation)
            return
        }
    }

    var globalSelectionWindowSize: CGSize {
        window?.frame.size ?? CGSize(width: 420, height: 620)
    }

    func applyGlobalSelectionWindowFrame(_ frame: CGRect, generation: UInt64) {
        guard pendingGlobalSelectionContext?.generation == generation else { return }
        pendingGlobalSelectionFrame = frame
        if window?.isVisible == true {
            window?.setFrame(frame, display: true, animate: false)
        }
    }

    func hideGlobalSelectionWindow() {
        pendingGlobalSelectionFrame = nil
        window?.orderOut(nil)
    }

    private func updateGlobalSelectionContext(_ context: GlobalSelectionContext?,
                                              generation: UInt64?,
                                              expectedText: String?) {
        guard let context,
              expectedText.map({
                  SentenceTextNormalizer.normalize(context.selectedText) ==
                    SentenceTextNormalizer.normalize($0)
              }) ?? true else {
            if let generation {
                invalidateGlobalSelection(generation: generation)
            } else {
                pendingGlobalSelectionContext = nil
                pendingGlobalSelectionFrame = nil
            }
            return
        }
        pendingGlobalSelectionContext = context
    }

    private func configure(_ panel: DictionaryPanel) {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = DictionaryPanelInteractionPolicy.collectionBehavior
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.escapeHandler = { [weak self] in self?.hide() }

        let material = DictionaryAppearanceView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        panel.contentView = material
        material.appearanceDidChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.renderInlinePage()
                self.textView.needsDisplay = true
            }
        }

        searchField.placeholderString = ui("输入英文、中文或段落", "Enter English, Chinese, or a passage")
        DictionaryPanelInteractionPolicy.configureSearchField(searchField)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(performSearch)

        starButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "保存词条")
        starButton.target = self
        starButton.action = #selector(showNoteMenu)
        starButton.isBordered = false
        starButton.bezelStyle = .accessoryBarAction
        starButton.toolTip = ui("当前没有可以保存的词条", "There is nothing to save yet")
        starButton.setAccessibilityLabel(ui("保存到 Obsidian 笔记", "Save to Obsidian Note"))
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
        aiIncludeCheckbox.title = ui("收藏时加入 AI 内容", "Include AI Content When Saving")
        aiIncludeCheckbox.font = .systemFont(ofSize: 11)
        aiIncludeCheckbox.target = self
        aiIncludeCheckbox.action = #selector(aiInclusionDidChange)
        aiIncludeCheckbox.toolTip = "勾选后，点击星号会把当前已生成的 AI 解释一并写入 Markdown 笔记。"
        aiIncludeCheckbox.setAccessibilityLabel(aiIncludeCheckbox.title)
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
        displayText(hasReadyDictionary
            ? ui("输入英文单词并按回车查询", "Enter an English word and press Return")
            : oxfordCore.lastError)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languagePreferencesDidChange),
            name: .localDictionaryLanguagePreferencesDidChange,
            object: LanguagePreferencesStore.shared
        )

        aiStatusLabel.font = .systemFont(ofSize: 11)
        aiStatusLabel.textColor = .secondaryLabelColor
        aiStatusLabel.maximumNumberOfLines = 2
        aiActionButton.bezelStyle = .rounded
        aiActionButton.controlSize = .small
        aiActionButton.target = self
        aiActionButton.action = #selector(performAIAction)
        aiActionButton.toolTip = ui(
            "逐句 AI 深度分析：始终以 English 为学习对象，解释以简体中文为主",
            "Sentence AI analysis always studies English and explains primarily in Simplified Chinese"
        )
        aiTranslationButton.title = ui("AI 深度翻译", "AI Deep Translation")
        aiTranslationButton.bezelStyle = .rounded
        aiTranslationButton.controlSize = .small
        aiTranslationButton.target = self
        aiTranslationButton.action = #selector(requestLongTextAITranslation)
        aiTranslationButton.toolTip = ui(
            "AI 深度翻译：English 译为简体中文，简体中文译为 English",
            "AI deep translation: English to Simplified Chinese, or Simplified Chinese to English"
        )
        aiTranslationButton.isHidden = true
        aiSettingsButton.title = ui("打开 AI 设置…", "Open AI Settings…")
        aiSettingsButton.bezelStyle = .inline
        aiSettingsButton.isBordered = false
        aiSettingsButton.controlSize = .small
        aiSettingsButton.target = self
        aiSettingsButton.action = #selector(openAISettingsWindow)
        aiClearCacheButton.title = ui("清除此条 AI 缓存", "Clear AI Cache for This Query")
        aiClearCacheButton.bezelStyle = .rounded
        aiClearCacheButton.isBordered = true
        aiClearCacheButton.controlSize = .small
        aiClearCacheButton.target = self
        aiClearCacheButton.action = #selector(clearCurrentAICache)
        aiClearCacheButton.isHidden = true
        offlineActionButton.bezelStyle = .rounded
        offlineActionButton.controlSize = .small
        offlineActionButton.target = self
        offlineActionButton.action = #selector(performOfflineAction)
        offlineActionButton.isHidden = true
        reverseIndexButton.title = ui("建立中文反向索引…", "Build Native Reverse Index…")
        reverseIndexButton.bezelStyle = .rounded
        reverseIndexButton.controlSize = .small
        reverseIndexButton.target = self
        reverseIndexButton.action = #selector(buildReverseIndexes)
        reverseIndexButton.isHidden = true
        let localHeading = NSTextField(labelWithString: ui("本地功能", "Local Features"))
        localHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        localHeading.textColor = .secondaryLabelColor
        localActionGroup.addArrangedSubview(localHeading)
        localActionGroup.addArrangedSubview(reverseIndexButton)
        localActionGroup.addArrangedSubview(offlineActionButton)
        localActionGroup.orientation = .vertical
        localActionGroup.alignment = .leading
        localActionGroup.spacing = 4

        let aiHeading = NSTextField(labelWithString: ui(
            "AI 功能（仅点击后联网）", "AI Features (network only after clicking)"
        ))
        aiHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        aiHeading.textColor = .secondaryLabelColor
        remoteAIActionGroup.addArrangedSubview(aiHeading)
        remoteAIActionGroup.addArrangedSubview(aiTranslationButton)
        remoteAIActionGroup.addArrangedSubview(aiActionButton)
        remoteAIActionGroup.addArrangedSubview(aiSettingsButton)
        remoteAIActionGroup.addArrangedSubview(aiClearCacheButton)
        remoteAIActionGroup.orientation = .vertical
        remoteAIActionGroup.alignment = .leading
        remoteAIActionGroup.spacing = 4
        let translationHostView = systemTranslationHost.view
        DictionaryPanelFooterLayout.assemble(
            footer: aiFooter,
            localGroup: localActionGroup,
            translationHostView: translationHostView,
            statusLabel: aiStatusLabel,
            aiGroup: remoteAIActionGroup
        )
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
            aiFooter.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -22),
            aiFooter.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -8),
            footerHeight
        ])
    }

    private func ui(_ chinese: String, _ english: String) -> String {
        AppLocalization.text(chinese, english)
    }

    private func languageEvidenceStrings(
        classification: QueryIntentClassification,
        preferences: LanguagePreferences
    ) -> [String: String] {
        let context = LanguageContext.make(
            classification: classification, preferences: preferences
        )
        return [
            "queryRelation": context.queryRelation.rawValue,
            "dominantLanguage": context.dominantLanguage?.rawValue ?? "undetermined",
            "explanationLanguage": context.explanationLanguage.rawValue,
            "nativeCoverageBucket": context.nativeCoverageBucket.rawValue,
            "learningCoverageBucket": context.learningCoverageBucket.rawValue,
            "classifierConfidenceBucket": context.classifierConfidenceBucket.rawValue
        ]
    }

    private func languageEvidenceIntegers(
        classification: QueryIntentClassification,
        preferences: LanguagePreferences
    ) -> [String: Int64] {
        let context = LanguageContext.make(
            classification: classification, preferences: preferences
        )
        return [
            "hanCharacterCount": Int64(context.hanCharacterCount),
            "latinTokenCount": Int64(context.latinTokenCount)
        ]
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
        pendingGlobalSelectionContext = nil
        pendingGlobalSelectionFrame = nil
        let submitted = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else {
            tripleReturnAITrigger.reset()
            resetAIState(query: "", intent: .textTooLong)
            setCurrentEntry(nil)
            displayText("")
            return
        }
        let gesture = tripleReturnAITrigger.register(
            query: submitted, at: Date.timeIntervalSinceReferenceDate
        )
        switch gesture {
        case .firstReturn:
            _ = processQuery(submitted)
        case .secondReturn:
            ManualEvidenceRecorder.shared.record(
                "tripleReturnAIProgress",
                strings: ["controlType": "searchField"],
                integers: [
                    "queryGeneration": Int64(clamping: queryGeneration.generation),
                    "returnCount": 2
                ]
            )
        case .triggerAI:
            requestDefaultAIFromTripleReturn(query: submitted)
        }
    }

    private func requestDefaultAIFromTripleReturn(query: String) {
        pendingTripleReturnAITask?.cancel()
        let expected = SentenceTextNormalizer.normalize(query)
        let generation = queryGeneration.generation
        ManualEvidenceRecorder.shared.record(
            "tripleReturnAITriggered",
            strings: [
                "controlType": "searchField",
                "queryKind": String(describing: currentIntent)
            ],
            integers: ["queryGeneration": Int64(clamping: generation)]
        )
        pendingTripleReturnAITask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                guard self.queryGeneration.accepts(generation),
                      SentenceTextNormalizer.normalize(self.currentQuery) == expected else {
                    return
                }
                if self.triggerDefaultAIControlIfReady() { return }
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            self.aiStatusLabel.stringValue = self.ui(
                "AI 功能尚未就绪，请稍后重试", "AI is not ready yet. Please try again."
            )
        }
    }

    private func triggerDefaultAIControlIfReady() -> Bool {
        if currentIntent == .sentence {
            guard !aiTranslationButton.isHidden, aiTranslationButton.isEnabled else {
                return currentLongTextTranslation != nil
            }
            aiTranslationButton.performClick(nil)
            return true
        }
        if currentAIPresentation != nil { return true }
        guard aiAction != .none, !aiActionButton.isHidden, aiActionButton.isEnabled else {
            return false
        }
        performAIAction()
        return true
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
            let languageContext = LanguageContext.make(
                classification: classification,
                preferences: LanguagePreferencesStore.shared.load()
            )
            if languageContext.isMixed,
               languageContext.hanCharacterCount >= 2,
               languageContext.latinTokenCount >= 1 {
                searchField.stringValue = classification.normalizedText
                prepareOfflineTextMode(classification.normalizedText)
                return false
            }
            if classification.language == .simplifiedChinese {
                searchField.stringValue = classification.normalizedText
                prepareChineseReverseLookup(classification.normalizedText)
                return false
            }
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
            let text = classification.normalizedText
            searchField.stringValue = text
            prepareOfflineTextMode(text)
            return false
        }
    }

    private func lookup(_ query: String, intent: QueryIntent) -> Bool {
        resetAIState(query: query, intent: intent)
        setCurrentEntry(nil)
        configureAutomaticShortOfflineLookup(query, intent: intent)
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
        let newlyUnavailable = failures.filter {
            !reportedUnavailableDictionaryIDs.contains($0.id)
        }
        reportedUnavailableDictionaryIDs.formUnion(newlyUnavailable.map { $0.id })

        guard !preferredResults.isEmpty else {
            startManagedDictionaryLookup(
                query: query,
                intent: intent,
                generation: queryGeneration.generation,
                unavailablePreferredNames: newlyUnavailable.map(\.name),
                preferredResults: []
            )
            return false
        }
        displayCombinedDictionaryHits(
            preferred: preferredResults, managed: [], query: query,
            unavailablePreferredNames: newlyUnavailable.map(\.name)
        )
        startManagedDictionaryLookup(
            query: query, intent: intent, generation: queryGeneration.generation,
            unavailablePreferredNames: newlyUnavailable.map(\.name),
            preferredResults: preferredResults
        )
        return true
    }

    private func isPreferredDictionaryEnabled(_ dictionaryID: String) -> Bool {
        guard let descriptor = preferredCatalogDescriptors[dictionaryID] else { return true }
        return descriptor.enabled
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
        unavailablePreferredNames: [String],
        preferredResults: [PreferredDictionaryPresentation]
    ) {
        if preferredResults.isEmpty {
            if isNativeLanguageLookup(query) {
                shortNativeLocalDisplay = shortLookupMessage("正在查询已启用词典…")
                renderShortNativeLookup()
            } else {
                displayText("正在查询已启用词典…")
            }
        }
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
                    if !preferredResults.isEmpty { return }
                    var message = "未找到词条：\(query)"
                    if !unavailablePreferredNames.isEmpty {
                        message += "\n部分词典暂不可用：" +
                            unavailablePreferredNames.joined(separator: "、")
                    }
                    if !batch.unavailableDictionaryIDs.isEmpty {
                        message += "\n部分本地导入词典暂不可用"
                    }
                    message += "\n保持文本不变并连续按三次 Return，可启动 AI 辅助查询。"
                    let attributed = self.shortLookupMessage(message)
                    if self.isNativeLanguageLookup(query) {
                        self.shortNativeLocalDisplay = attributed
                        self.renderShortNativeLookup()
                    } else if self.isLearningLanguageLookup(query), self.offlineActionPair != nil {
                        self.shortLearningLocalDisplay = attributed
                        self.renderShortLearningLookup()
                    } else {
                        self.displayAttributedText(attributed)
                    }
                    self.localResultContent = nil
                    self.configureAIAction(hasLocalResult: false, hasChinese: false)
                    return
                }
                self.displayCombinedDictionaryHits(
                    preferred: preferredResults, managed: batch.hits, query: query,
                    unavailablePreferredNames: unavailablePreferredNames
                )
            }
        }
    }

    private func displayCombinedDictionaryHits(
        preferred: [PreferredDictionaryPresentation],
        managed: [ManagedDictionaryQueryHit],
        query: String,
        unavailablePreferredNames: [String]
    ) {
        var values = preferred.map { value in
            CombinedDictionaryPresentation(
                dictionaryID: value.dictionaryID,
                order: preferredSortKey(value.dictionaryID).position,
                attributedString: value.attributedString,
                structuredSource: value.structuredSource,
                headword: value.headword
            )
        }
        values.append(contentsOf: managed.map { hit in
            CombinedDictionaryPresentation(
                dictionaryID: hit.dictionaryID,
                order: hit.dictionaryOrder,
                attributedString: genericManagedPresenter.attributedString(for: hit),
                structuredSource: StructuredDictionarySource(
                    phonetics: [], partsOfSpeech: [], definitions: hit.noteDefinitions,
                    examples: [], source: hit.displayName, dictionaryID: hit.dictionaryID
                ),
                headword: hit.matchedHeadword
            )
        })
        values.sort {
            $0.order == $1.order ? $0.dictionaryID < $1.dictionaryID : $0.order < $1.order
        }
        let combined = NSMutableAttributedString(string: "")
        for value in values {
            if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
            combined.append(value.attributedString)
        }
        if !unavailablePreferredNames.isEmpty {
            appendAvailabilityNotice(unavailablePreferredNames, to: combined)
        }
        guard !values.isEmpty else { return }
        let headword = values.lazy.map(\.headword).first { !$0.isEmpty } ?? query
        let entry = StructuredDictionaryEntry(
            headword: headword, sources: values.map(\.structuredSource)
        )
        if entry.isValid { setCurrentEntry(entry) }
        localResultContent = combined.copy() as? NSAttributedString
        if isNativeLanguageLookup(query) {
            shortNativeLocalDisplay = localResultContent
            renderShortNativeLookup()
        } else if isLearningLanguageLookup(query), offlineActionPair != nil {
            shortLearningLocalDisplay = localResultContent
            renderShortLearningLookup()
        } else {
            displayAttributedText(combined)
        }
        localResultHasChinese = containsChineseContent(entry)
        configureAIAction(hasLocalResult: true, hasChinese: localResultHasChinese)
        textView.scrollToBeginningOfDocument(nil)
    }

    private func resetAIState(query: String, intent: QueryIntent) {
        let priorQuery = currentQuery
        cancelAllLongTextSentenceAI(reason: .userQueryChanged)
        aiTask?.cancel()
        aiTask = nil
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        currentLongTextAIStudyTextTask?.cancel()
        currentLongTextAIStudyTextTask = nil
        aiRequestLifecycle.invalidate()
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        managedQueryTask?.cancel()
        managedQueryTask = nil
        longTextTask?.cancel()
        longTextTask = nil
        reverseLookupTask?.cancel()
        reverseLookupTask = nil
        let newGeneration = queryGeneration.beginQuery()
        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentIntent = intent
        let preferences = LanguagePreferencesStore.shared.load()
        let classification = QueryIntentClassifier.classify(currentQuery)
        if !priorQuery.isEmpty, priorQuery != currentQuery {
            ManualEvidenceRecorder.shared.recordQuery(
                "queryReplaced", query: currentQuery,
                queryGeneration: newGeneration,
                queryKind: String(describing: intent),
                queryLanguage: classification.language.rawValue,
                nativeLanguage: preferences.nativeLanguage.rawValue,
                learningLanguage: preferences.learningLanguage.rawValue,
                diagnosticStrings: self.languageEvidenceStrings(
                    classification: classification, preferences: preferences
                ),
                diagnosticIntegers: self.languageEvidenceIntegers(
                    classification: classification, preferences: preferences
                )
            )
        } else if !currentQuery.isEmpty {
            ManualEvidenceRecorder.shared.recordQuery(
                "querySubmitted", query: currentQuery,
                queryGeneration: newGeneration,
                queryKind: String(describing: intent),
                queryLanguage: classification.language.rawValue,
                nativeLanguage: preferences.nativeLanguage.rawValue,
                learningLanguage: preferences.learningLanguage.rawValue,
                diagnosticStrings: self.languageEvidenceStrings(
                    classification: classification, preferences: preferences
                ),
                diagnosticIntegers: self.languageEvidenceIntegers(
                    classification: classification, preferences: preferences
                )
            )
        }
        localResultContent = nil
        localResultHasChinese = false
        aiAction = .none
        currentAIPresentation = nil
        currentSentencePresentation = nil
        currentSentenceStudyText = nil
        currentLocalGlossary = nil
        currentSentenceStatus = nil
        currentLongTextResult = nil
        currentOfflineStudyTexts.removeAll()
        currentLongTextAI.removeAll()
        currentLongTextAIStates.removeAll()
        currentLongTextTranslation = nil
        currentLongTextAIStudyText = nil
        currentLongTextTranslationStatus = nil
        directionTasks.values.forEach { $0.cancel() }
        directionTasks.removeAll()
        directionGenerationGate.invalidateAll()
        longTextResultRevision &+= 1
        offlineActionPair = nil
        offlineActionSource = ""
        offlineActionAutoStart = false
        shortNativeOfflineResult = nil
        shortNativeLocalDisplay = nil
        shortNativeOfflineStatus = ""
        shortLearningOfflineResult = nil
        shortLearningLocalDisplay = nil
        shortLearningOfflineStatus = ""
        aiSectionCharacterLocation = nil
        aiIncludeCheckbox.state = .off
        aiIncludeCheckbox.isHidden = true
        aiClearCacheButton.isHidden = true
        offlineActionButton.isHidden = true
        reverseIndexButton.isHidden = true
        aiSettingsButton.title = ui("打开 AI 设置…", "Open AI Settings…")
        aiTranslationButton.isHidden = true
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
                let isNativeLookup = self.isNativeLanguageLookup(query)
                if (!hasLocalResult || isNativeLookup) &&
                    (!availability.isEnabled || !availability.isConfigured) {
                    self.aiAction = .configure
                    self.aiStatusLabel.stringValue = "未配置可用的 AI 服务"
                    self.aiActionButton.title = self.ui("配置 AI 服务…", "Configure AI Service…")
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
                    self.aiActionButton.title = self.ui("AI 双语解释", "AI Bilingual Explanation")
                } else if !hasChinese {
                    self.aiActionButton.title = self.ui("AI 中文解读", "AI Native-Language Explanation")
                } else {
                    self.aiActionButton.title = self.ui("AI 双语补充", "AI Bilingual Supplement")
                }
                self.aiActionButton.isEnabled = true
                self.aiSettingsButton.isHidden = true
                self.updateAIFooter(visible: true)
            }
        }
    }

    @objc private func performAIAction() {
        guard validateGlobalSelectionActionContext() else { return }
        ManualEvidenceRecorder.shared.record(
            currentIntent == .sentence
                ? "aiSentenceAnalysisClicked" : "aiExplanationClicked",
            integers: ["queryGeneration": Int64(clamping: queryGeneration.generation)]
        )
        switch aiAction {
        case .none:
            return
        case .configure:
            openAISettings()
        case .explain(let domain, let bypassCache):
            requestAIExplanation(domain: domain, bypassCache: bypassCache)
        case .analyzeSentence(let bypassCache):
            requestSentenceAnalysis(bypassCache: bypassCache)
        case .analyzeLongText:
            requestLongTextAIAnalysis()
        case .cancelSentence:
            cancelSentenceAnalysis()
        }
    }

    @objc private func openAISettingsWindow() {
        openAISettings()
    }

    @objc private func clearCurrentAICache() {
        let query = currentQuery
        let intent: QueryIntent = currentLongTextResult == nil ? currentIntent : .textTooLong
        let providerID = currentAIProviderID(for: intent)
        let studyTexts = currentAIStudyTexts(for: intent)
        let generation = queryGeneration.generation
        guard !query.isEmpty else { return }
        ManualEvidenceRecorder.shared.record("aiCacheClearClicked", strings: [
            "queryHash": ManualEvidenceRecorder.identityHash(query)
        ], integers: [
            "queryGeneration": Int64(clamping: generation),
            "aiArtifactCountBefore": Int64(currentAIArtifactCount(intent: intent))
        ])
        // Do not let a late provider callback recreate the artifact after the user clears it.
        aiTask?.cancel()
        aiTask = nil
        cancelAllLongTextSentenceAI(reason: .userCacheClear)
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        currentLongTextAIStudyTextTask?.cancel()
        currentLongTextAIStudyTextTask = nil
        aiRequestLifecycle.invalidate()
        aiClearCacheButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await aiService.clearCurrentCache(for: query, intent: intent,
                                                      providerID: providerID,
                                                      studyTexts: studyTexts)
                await MainActor.run {
                    guard self.currentQuery == query,
                          self.queryGeneration.accepts(generation) else { return }
                    self.aiClearCacheButton.isHidden = true
                    self.aiClearCacheButton.isEnabled = true
                    self.clearCurrentAIResultState(intent: intent)
                    self.aiStatusLabel.stringValue = "本条 AI 缓存已清除。"
                    ManualEvidenceRecorder.shared.record("aiCacheCleared", strings: [
                        "queryHash": ManualEvidenceRecorder.identityHash(query),
                        "resultKind": "success"
                    ], integers: [
                        "queryGeneration": Int64(clamping: generation),
                        "aiArtifactCountAfter": 0
                    ])
                    if intent == .textTooLong,
                       self.currentLongTextResult != nil {
                        self.configureLongTextAIAction()
                    }
                    self.updateAIFooter(visible: true, compact: self.aiAction == .none)
                }
            } catch {
                await MainActor.run {
                    guard self.currentQuery == query,
                          self.queryGeneration.accepts(generation) else { return }
                    self.aiClearCacheButton.isEnabled = true
                    self.aiStatusLabel.stringValue = "无法清除本条缓存，请稍后重试。"
                    self.updateAIFooter(visible: true)
                }
            }
        }
    }

    private func refreshCurrentAICacheControl(query: String) {
        let intent: QueryIntent = currentLongTextResult == nil ? currentIntent : .textTooLong
        let providerID = currentAIProviderID(for: intent)
        let studyTexts = currentAIStudyTexts(for: intent)
        let generation = queryGeneration.generation
        Task { [weak self] in
            guard let self else { return }
            let exists = await aiService.hasCurrentCache(for: query, intent: intent,
                                                         providerID: providerID,
                                                         studyTexts: studyTexts)
            await MainActor.run {
                guard self.currentQuery == query,
                      self.queryGeneration.accepts(generation) else { return }
                let shouldPresent = exists || self.currentAIArtifactCount(intent: intent) > 0
                let wasHidden = self.aiClearCacheButton.isHidden
                self.aiClearCacheButton.isHidden = !shouldPresent
                self.aiClearCacheButton.isEnabled = true
                if shouldPresent, wasHidden {
                    ManualEvidenceRecorder.shared.record(
                        "aiCacheClearPresented",
                        strings: [
                            "queryHash": ManualEvidenceRecorder.identityHash(query),
                            "controlType": "NSButton"
                        ], integers: [
                            "queryGeneration": Int64(clamping: generation),
                            "aiArtifactCountBefore": Int64(
                                self.currentAIArtifactCount(intent: intent)
                            )
                        ], booleans: ["controlEnabled": true]
                    )
                }
                if !self.aiFooter.isHidden {
                    // A long-text cache control must not collapse the other independent AI
                    // action. In particular, deep translation cannot hide sentence analysis.
                    self.updateAIFooter(
                        visible: true, compact: intent != .textTooLong
                    )
                }
            }
        }
    }

    private func currentAIProviderID(for intent: QueryIntent) -> UUID? {
        if intent == .textTooLong {
            return currentLongTextTranslation?.providerID ??
                currentLongTextAIStudyText?.providerID ??
                currentLongTextAI.values.compactMap(\.providerID).first
        }
        return intent == .sentence
            ? currentSentencePresentation?.providerID : currentAIPresentation?.providerID
    }

    private func currentAIArtifactCount(intent: QueryIntent) -> Int {
        switch intent {
        case .word, .phrase:
            return currentAIPresentation == nil ? 0 : 1
        case .sentence:
            return (currentSentencePresentation == nil ? 0 : 1) +
                (currentSentenceStatus == nil ? 0 : 1)
        case .textTooLong:
            let sentenceStates = currentLongTextAIStates.values.filter {
                if case .idle = $0 { return false }
                return true
            }.count
            return (currentLongTextAIStudyText == nil ? 0 : 1) +
                (currentLongTextTranslation == nil ? 0 : 1) +
                currentLongTextAI.count + sentenceStates +
                (currentLongTextTranslationStatus == nil ? 0 : 1)
        }
    }

    private func currentAIStudyTexts(for intent: QueryIntent) -> [String] {
        guard intent == .textTooLong else { return [] }
        var values = currentLongTextResult?.sentences.compactMap { sentence in
            sentence.studyText?.origin == .aiTranslation ? sentence.studyText?.text : nil
        } ?? []
        if let canonical = currentLongTextAIStudyText?.studyText.text {
            values.append(canonical)
        }
        return Array(Set(values))
    }

    private func clearCurrentAIResultState(intent: QueryIntent) {
        switch intent {
        case .word, .phrase:
            currentAIPresentation = nil
        case .sentence:
            currentSentencePresentation = nil
            currentSentenceStatus = nil
        case .textTooLong:
            currentLongTextAIStudyText = nil
            currentLongTextTranslation = nil
            currentLongTextTranslationStatus = nil
            currentLongTextAI.removeAll()
            currentLongTextAIStates.removeAll()
            if let result = currentLongTextResult {
                var restored = result
                for sentence in result.sentences {
                    var replacement = sentence
                    if let offline = currentOfflineStudyTexts[sentence.id] {
                        replacement.studyText = offline.studyText
                        replacement.basicAnalysis = BasicSentenceAnalyzer().analyze(
                            sentence: offline.studyText.text,
                            language: offline.studyText.language.queryLanguage
                        )
                    } else if LanguageContext.make(query: sentence.sourceText)
                        .isLearningDominant,
                              let original = StudyText(
                                text: sentence.sourceText,
                                language: LanguagePreferencesStore.shared.load().learningLanguage,
                                origin: .originalQuery
                              ) {
                        replacement.studyText = original
                        replacement.basicAnalysis = BasicSentenceAnalyzer().analyze(
                            sentence: original.text, language: original.language.queryLanguage
                        )
                    } else {
                        replacement.studyText = nil
                        replacement.basicAnalysis = .waitingForStudyText
                    }
                    restored = restored.replacingSentence(replacement)
                }
                currentLongTextResult = restored
                renderLongTextResult(restored)
            }
        }
        refreshStarState()
    }

    private func requestAIExplanation(domain: String, bypassCache: Bool = false) {
        guard !currentQuery.isEmpty else { return }
        let query = currentQuery
        let generation = queryGeneration.generation
        aiActionButton.isEnabled = false
        aiActionButton.title = ui("正在生成…", "Generating…")
        aiSettingsButton.isHidden = true
        aiStatusLabel.stringValue = "正在请求所配置的第三方 AI 服务"
        updateAIFooter(visible: true)
        aiTask?.cancel()
        let requestToken = aiRequestLifecycle.begin()
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let presentation = try await aiService.explain(query: query, domain: domain,
                                                                bypassCache: bypassCache)
                let formatted = aiEntryFormatter.format(presentation)
                await MainActor.run {
                    guard self.currentQuery == query,
                          self.currentIntent != .sentence,
                          self.queryGeneration.accepts(generation),
                          self.aiRequestLifecycle.finish(requestToken) else { return }
                    self.aiTask = nil
                    let output = NSMutableAttributedString()
                    if self.isNativeLanguageLookup(query) {
                        if let offline = self.shortNativeOfflineResult {
                            output.append(NSAttributedString(
                                string: "Apple 系统离线翻译\n",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                                    .foregroundColor: NSColor.systemPurple
                                ]
                            ))
                            output.append(self.shortLookupMessage(offline.translatedText))
                        }
                        if let local = self.localResultContent {
                            if output.length > 0 {
                                output.append(NSAttributedString(string: "\n\n"))
                            }
                            output.append(NSAttributedString(
                                string: "本地词典与反向查询\n",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                    .foregroundColor: NSColor.labelColor
                                ]
                            ))
                            output.append(local)
                        }
                    } else {
                        if let offline = self.shortLearningOfflineResult {
                            output.append(NSAttributedString(
                                string: "Apple 系统离线翻译\n",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                                    .foregroundColor: NSColor.systemPurple
                                ]
                            ))
                            output.append(self.shortLookupMessage(offline.translatedText))
                        }
                        if let local = self.localResultContent {
                            if output.length > 0 {
                                output.append(NSAttributedString(string: "\n\n"))
                            }
                            output.append(local)
                        }
                    }
                    if output.length > 0 {
                        output.append(NSAttributedString(string: "\n\n"))
                    }
                    self.aiSectionCharacterLocation = output.length
                    output.append(formatted)
                    self.displayAttributedText(output)
                    self.currentAIPresentation = presentation
                    ManualEvidenceRecorder.shared.record("aiResultPresented", strings: [
                        "provider": presentation.providerDisplayName,
                        "model": presentation.model,
                        "responseKind": presentation.explanation.responseParseMode.resultLevel.rawValue,
                        "resultKind": "success"
                    ], integers: [
                        "queryGeneration": Int64(clamping: generation),
                        "responseLength": Int64(formatted.length)
                    ], booleans: [
                        "safeVisibleContent": formatted.length > 0,
                        "cacheHit": presentation.fromCache
                    ])
                    if self.isNativeLanguageLookup(query) {
                        self.aiIncludeCheckbox.state = .on
                        self.aiIncludeCheckbox.isHidden = true
                    } else {
                        self.aiIncludeCheckbox.state = .off
                        self.aiIncludeCheckbox.isHidden = false
                        self.positionAIIncludeCheckbox()
                    }
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
                await MainActor.run {
                    guard self.currentQuery == query,
                          self.currentIntent != .sentence,
                          self.queryGeneration.accepts(generation),
                          self.aiRequestLifecycle.finish(requestToken) else { return }
                    self.aiTask = nil
                    self.aiAction = .explain(domain: domain, bypassCache: true)
                    self.aiStatusLabel.stringValue = AIRequestUserMessage.message(for: error)
                    self.aiActionButton.title = self.ui("重新查询", "Try Again")
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = false
                    self.aiSettingsButton.title = self.ui("更换 AI 服务…", "Change AI Service…")
                    self.refreshCurrentAICacheControl(query: query)
                    self.updateAIFooter(visible: true)
                }
            }
        }
    }

    private func prepareChineseReverseLookup(_ query: String) {
        resetAIState(query: query, intent: .phrase)
        setCurrentEntry(nil)
        let context = LanguageContext.make(query: query)
        let isNative = context.isPureNative
        let initial = shortLookupMessage("正在查询本地中文反向索引…")
        if isNative {
            shortNativeLocalDisplay = initial
            renderShortNativeLookup()
        } else {
            displayAttributedText(initial)
        }
        if let plan = OfflineTranslationPlan.make(context: context),
           let operation = plan.operations.first(where: {
               $0.outputRole == plan.primaryOutputRole
           }) {
            configureOfflineAction(
                source: query, pair: operation.pair,
                automaticallyTranslateWhenInstalled: isNative
            )
        }
        configureAIAction(hasLocalResult: false, hasChinese: true)
        updateAIFooter(visible: true)
        let generation = queryGeneration.generation
        reverseLookupTask?.cancel()
        reverseLookupTask = Task { [weak self] in
            guard let self else { return }
            async let reverseOutcome = reverseLookupService.lookupOutcome(query)
            async let managedBatch = managedDictionaryQueryService.lookupChinese(query)
            let (outcome, batch) = await (reverseOutcome, managedBatch)
            let aggregate = LocalChineseQueryPlanner.merge(
                query: query,
                reverse: outcome,
                directHits: batch.hits.map {
                    LocalChineseQueryPlanner.DirectHit(
                        dictionaryID: $0.dictionaryID,
                        displayName: $0.displayName,
                        definitions: $0.noteDefinitions,
                        sourcePriority: $0.sourcePriority,
                        dictionaryOrder: $0.dictionaryOrder
                    )
                }
            )
            let results = aggregate.results
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentQuery == query,
                      self.queryGeneration.accepts(generation) else { return }
                if !results.isEmpty {
                    let local = ReverseLookupResultFormatter.attributedResults(
                        results, query: query
                    )
                    self.localResultContent = local
                    if self.isNativeLanguageLookup(query) {
                        self.shortNativeLocalDisplay = local
                        self.renderShortNativeLookup()
                    } else {
                        self.displayAttributedText(local)
                    }
                    self.reverseIndexButton.isHidden = true
                } else {
                    let message: String
                    switch aggregate.state {
                    case .noAvailableIndexes:
                        message = "尚未建立任何可用的中文反向索引。\n\n请在“词典管理”中为支持中文释义的词典建立反向索引。"
                        self.reverseIndexButton.isHidden = !self.reverseDictionarySources.contains {
                            $0.reverseCapability.isBuildEligible
                        }
                    case .building:
                        message = "中文反向索引正在后台建立。\n\n普通英文查词仍可使用；完成并发布后会自动查询当前词语。"
                        self.reverseIndexButton.isHidden = false
                        self.reverseIndexButton.title = "取消反向索引"
                    case .stale:
                        message = "已有中文反向索引与词典身份不一致，已停止查询。\n\n请在“词典管理”中重建过期的反向索引。"
                        self.reverseIndexButton.isHidden = !self.reverseDictionarySources.contains {
                            $0.reverseCapability.isBuildEligible
                        }
                        self.reverseIndexButton.title = "重建中文反向索引…"
                    case .noMatch:
                        message = "中文反向索引查询成功，但没有匹配“\(query)”的可靠候选。"
                        self.reverseIndexButton.isHidden = true
                    case .failed:
                        message = "中文反向索引查询失败。\n\n索引已停止参与本次结果；请在“词典管理”中查看详情并重试。"
                        self.reverseIndexButton.isHidden = !self.reverseDictionarySources.contains {
                            $0.reverseCapability.isBuildEligible
                        }
                    case .success:
                        message = "中文反向索引没有返回可靠候选。"
                    }
                    let local = self.shortLookupMessage(message)
                    if self.isNativeLanguageLookup(query) {
                        self.shortNativeLocalDisplay = local
                        self.renderShortNativeLookup()
                    } else {
                        self.displayAttributedText(local)
                    }
                }
                self.configureAIAction(
                    hasLocalResult: !results.isEmpty || !batch.hits.isEmpty,
                    hasChinese: true
                )
                self.updateAIFooter(visible: true)
            }
        }
    }

    private func configureAutomaticShortOfflineLookup(_ query: String, intent: QueryIntent) {
        guard let plan = OfflineTranslationPlan.automaticShortLookup(query: query, intent: intent),
              let operation = plan.operations.first(where: {
                  $0.outputRole == plan.primaryOutputRole
              }) else { return }
        configureOfflineAction(
            source: query, pair: operation.pair,
            automaticallyTranslateWhenInstalled: true
        )
    }

    private func shortLookupMessage(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func renderShortNativeLookup() {
        guard isNativeLanguageLookup(currentQuery) else { return }
        let output = NSMutableAttributedString()
        if let pair = offlineActionPair {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 5
            output.append(NSAttributedString(
                string: "Apple 系统离线翻译\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                    .foregroundColor: NSColor.systemPurple,
                    .paragraphStyle: style
                ]
            ))
            if let result = shortNativeOfflineResult {
                output.append(shortLookupMessage(result.translatedText))
            } else {
                let status = shortNativeOfflineStatus.isEmpty
                    ? "正在检查已安装的 \(pair.source.languageIdentifier.chineseName) → " +
                        "\(pair.target.languageIdentifier.chineseName) 语言资源…"
                    : shortNativeOfflineStatus
                output.append(NSAttributedString(
                    string: status,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
        }
        if let local = shortNativeLocalDisplay, local.length > 0 {
            if output.length > 0 { output.append(NSAttributedString(string: "\n\n")) }
            output.append(NSAttributedString(
                string: "本地词典与反向查询\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
            output.append(local)
        }
        if output.length > 0 {
            displayAttributedText(output)
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    private func renderShortLearningLookup() {
        guard isLearningLanguageLookup(currentQuery), offlineActionPair != nil else { return }
        let output = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 5
        output.append(NSAttributedString(
            string: "Apple 系统离线翻译\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.systemPurple,
                .paragraphStyle: style
            ]
        ))
        if let result = shortLearningOfflineResult {
            output.append(shortLookupMessage(result.translatedText))
        } else {
            let status = shortLearningOfflineStatus.isEmpty
                ? "正在检查已安装的 Apple 语言资源…"
                : shortLearningOfflineStatus
            output.append(NSAttributedString(
                string: status,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        if let local = shortLearningLocalDisplay, local.length > 0 {
            output.append(NSAttributedString(string: "\n\n"))
            output.append(NSAttributedString(
                string: "本地词典查询\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
            output.append(local)
        }
        displayAttributedText(output)
        textView.scrollToBeginningOfDocument(nil)
    }

    private func renderAutomaticShortOfflineLookup(_ source: String) {
        if isNativeLanguageLookup(source) {
            renderShortNativeLookup()
        } else if isLearningLanguageLookup(source) {
            renderShortLearningLookup()
        }
    }

    @objc private func languagePreferencesDidChange(_ notification: Notification) {
        let query = currentQuery
        guard !query.isEmpty else { return }
        offlineAvailabilityTask?.cancel()
        offlineAvailabilityTask = nil
        offlineActionGeneration &+= 1
        offlineActionTask?.cancel()
        offlineActionTask = nil
        _ = processQuery(query)
    }

    private func configureOfflineAction(
        source: String,
        pair: OfflineTranslationPair,
        automaticallyTranslateWhenInstalled: Bool = false
    ) {
        offlineActionPair = pair
        offlineActionSource = source
        offlineActionAutoStart = automaticallyTranslateWhenInstalled
        if automaticallyTranslateWhenInstalled {
            if isNativeLanguageLookup(source) {
                shortNativeOfflineStatus = "正在检查已安装的 Apple 语言资源…"
            } else if isLearningLanguageLookup(source) {
                shortLearningOfflineStatus = "正在检查已安装的 Apple 语言资源…"
            }
        }
        offlineActionButton.isHidden = false
        offlineActionButton.isEnabled = false
        offlineActionButton.title = "检查系统离线翻译…"
        offlineAvailabilityTask?.cancel()
        systemTranslationHost.model.setWaitingForUser()
        if automaticallyTranslateWhenInstalled {
            renderAutomaticShortOfflineLookup(source)
        }
        offlineAvailabilityTask = Task { [weak self] in
            guard let self else { return }
            let availability = await offlineTranslation.availability(for: pair)
            await MainActor.run {
                guard !Task.isCancelled, self.currentQuery == source,
                      self.offlineActionPair == pair else { return }
                let presentation = AppleTranslationActionPresentation.make(
                    availability: availability,
                    isLongText: self.currentIntent == .sentence,
                    pair: pair
                )
                self.offlineActionButton.title = presentation.title
                self.offlineActionButton.isEnabled = presentation.isEnabled
                switch availability {
                case .installed:
                    if self.offlineActionAutoStart {
                        if self.isNativeLanguageLookup(source) {
                            self.shortNativeOfflineStatus =
                                "正在进行 Apple 系统离线翻译…"
                        } else if self.isLearningLanguageLookup(source) {
                            self.shortLearningOfflineStatus =
                                "正在进行 Apple 系统离线翻译…"
                        }
                        self.renderAutomaticShortOfflineLookup(source)
                        self.offlineActionAutoStart = false
                        ManualEvidenceRecorder.shared.record(
                            "appleAutomaticTranslationStarted",
                            strings: [
                                "sourceLanguage": pair.source.rawValue,
                                "targetLanguage": pair.target.rawValue
                            ],
                            integers: [
                                "queryGeneration": Int64(clamping:
                                    self.queryGeneration.generation)
                            ]
                        )
                        self.performOfflineAction()
                    }
                case .supportedNeedsDownload:
                    if self.isNativeLanguageLookup(source) {
                        self.shortNativeOfflineStatus =
                            "Apple 语言包尚未安装；可点击下方按钮由 macOS 准备。"
                        self.renderShortNativeLookup()
                    } else if self.isLearningLanguageLookup(source) {
                        self.shortLearningOfflineStatus =
                            "Apple 语言包尚未安装；可点击下方按钮由 macOS 准备。"
                        self.renderShortLearningLookup()
                    }
                    self.aiStatusLabel.stringValue =
                        "由 macOS 管理；首次准备可能联网；安装后可由系统离线翻译；" +
                        "不会调用 AI Provider，也不属于开放资源中心。"
                case .unsupported:
                    if self.isNativeLanguageLookup(source) {
                        self.shortNativeOfflineStatus =
                            "当前系统不支持这个 Apple 翻译方向。"
                    } else if self.isLearningLanguageLookup(source) {
                        self.shortLearningOfflineStatus =
                            "当前系统不支持这个 Apple 翻译方向。"
                    }
                    self.renderAutomaticShortOfflineLookup(source)
                    break
                case .checking:
                    break
                case .temporarilyUnavailable:
                    if self.isNativeLanguageLookup(source) {
                        self.shortNativeOfflineStatus = "Apple 系统翻译目前暂不可用。"
                    } else if self.isLearningLanguageLookup(source) {
                        self.shortLearningOfflineStatus = "Apple 系统翻译目前暂不可用。"
                    }
                    self.renderAutomaticShortOfflineLookup(source)
                    break
                }
                self.updateAIFooter(visible: true)
            }
        }
    }

    @objc private func performOfflineAction() {
        guard validateGlobalSelectionActionContext() else { return }
        if let offlineActionTask {
            ManualEvidenceRecorder.shared.record("appleStopWaitingClicked", integers: [
                "queryGeneration": Int64(clamping: queryGeneration.generation)
            ])
            offlineActionGeneration &+= 1
            offlineActionTask.cancel()
            systemTranslationHost.model.stopWaitingForSystemPreparation()
            self.offlineActionTask = nil
            offlineActionButton.title = "重新检查 Apple 语言资源"
            offlineActionButton.isEnabled = true
            aiStatusLabel.stringValue =
                "本 App 已停止等待；macOS 可能仍在后台准备语言资源。" +
                "再次点击会先重新检查。"
            return
        }
        guard let pair = offlineActionPair, !offlineActionSource.isEmpty else { return }
        let languageContext = LanguageContext.make(query: offlineActionSource)
        ManualEvidenceRecorder.shared.record(
            offlineActionButton.title.localizedCaseInsensitiveContains("重新")
                ? "appleRetryClicked" : "appleTranslationRequested",
            strings: [
                "queryHash": ManualEvidenceRecorder.identityHash(offlineActionSource),
                "queryLanguage": pair.source.rawValue,
                "targetLanguage": pair.target.rawValue,
                "translationSourceLanguage": pair.source.rawValue,
                "translationTargetLanguage": pair.target.rawValue,
                "queryRelation": languageContext.queryRelation.rawValue,
                "dominantLanguage": languageContext.dominantLanguage?.rawValue ?? "undetermined",
                "nativeLanguage": languageContext.nativeLanguage.rawValue,
                "learningLanguage": languageContext.learningLanguage.rawValue,
                "nativeCoverageBucket": languageContext.nativeCoverageBucket.rawValue,
                "learningCoverageBucket": languageContext.learningCoverageBucket.rawValue,
                "classifierConfidenceBucket": languageContext.classifierConfidenceBucket.rawValue
            ], integers: [
                "queryGeneration": Int64(clamping: queryGeneration.generation),
                "queryLength": Int64(offlineActionSource.count),
                "hanCharacterCount": Int64(languageContext.hanCharacterCount),
                "latinTokenCount": Int64(languageContext.latinTokenCount)
            ]
        )
        let source = offlineActionSource
        offlineActionButton.isEnabled = true
        offlineActionButton.title = "停止等待"
        offlineActionGeneration &+= 1
        let actionGeneration = offlineActionGeneration
        offlineActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.offlineActionGeneration == actionGeneration {
                    self.offlineActionTask = nil
                }
            }
            let availability = await offlineTranslation.availability(for: pair)
            guard self.offlineActionGeneration == actionGeneration,
                  self.currentQuery == source,
                  !Task.isCancelled else { return }
            do {
                switch availability {
                case .supportedNeedsDownload:
                    self.systemTranslationHost.model.setWaitingForSystem()
                    self.offlineActionButton.title = "停止等待"
                    self.aiStatusLabel.stringValue =
                        "正在等待本机后台任务和 macOS；首次准备可能联网。" +
                        "停止等待不会取消 macOS 可能已经开始的后台准备；" +
                        "不会调用用户配置的 AI Provider。"
                    try await offlineTranslation.prepareLanguagePack(for: pair)
                    guard self.offlineActionGeneration == actionGeneration,
                          self.currentQuery == source,
                          !Task.isCancelled else { return }
                    self.offlineActionButton.title = self.currentIntent == .sentence
                        ? "进行基础离线翻译"
                        : "Apple 离线翻译（\(pair.source.languageIdentifier.chineseName) → " +
                            "\(pair.target.languageIdentifier.chineseName)）"
                    self.offlineActionButton.isEnabled = true
                    self.aiStatusLabel.stringValue =
                        "Apple 系统语言资源已安装。再次点击即可离线翻译。"
                case .installed:
                    guard self.offlineActionGeneration == actionGeneration,
                          self.currentQuery == source,
                          !Task.isCancelled else { return }
                    if await MainActor.run(body: { self.currentIntent == .sentence }) {
                        await MainActor.run { self.prepareOfflineTextMode(source) }
                    } else {
                        try await self.appendShortOfflineTranslation(
                            source: source, pair: pair,
                            actionGeneration: actionGeneration
                        )
                    }
                case .unsupported:
                    if self.currentIntent == .sentence {
                        throw OfflineTranslationError.unsupportedLanguagePair
                    }
                    try await self.appendShortOfflineTranslation(
                        source: source, pair: pair,
                        actionGeneration: actionGeneration
                    )
                case .checking, .temporarilyUnavailable:
                    if self.currentIntent == .sentence {
                        throw OfflineTranslationError.systemFailure
                    }
                    try await self.appendShortOfflineTranslation(
                        source: source, pair: pair,
                        actionGeneration: actionGeneration
                    )
                }
            } catch let error as OfflineTranslationError where error == .cancelled {
                guard self.offlineActionGeneration == actionGeneration,
                      self.currentQuery == source else { return }
                self.offlineActionButton.title = "重新检查 Apple 语言资源"
                self.offlineActionButton.isEnabled = true
                self.aiStatusLabel.stringValue =
                    "本 App 已停止等待；macOS 可能仍在后台准备语言资源。" +
                    "再次点击会先重新检查。"
            } catch {
                guard self.offlineActionGeneration == actionGeneration,
                      self.currentQuery == source else { return }
                self.aiStatusLabel.stringValue =
                    (error as? LocalizedError)?.errorDescription ?? "系统翻译暂时失败。"
                self.offlineActionButton.title = "重新检查 Apple 系统翻译"
                self.offlineActionButton.isEnabled = true
                if self.isNativeLanguageLookup(source) {
                    self.shortNativeOfflineStatus =
                        "Apple 系统离线翻译本次未完成；本地词典结果仍可使用。"
                    self.renderShortNativeLookup()
                } else if self.isLearningLanguageLookup(source) {
                    self.shortLearningOfflineStatus =
                        "Apple 系统离线翻译本次未完成；仍可连续按三次 Return 使用 AI 辅助查询。"
                    self.renderShortLearningLookup()
                }
            }
        }
    }

    @MainActor
    private func appendShortOfflineTranslation(
        source: String,
        pair: OfflineTranslationPair,
        actionGeneration: UInt64
    ) async throws {
        let response = try await offlineTranslation.translate([
            OfflineTranslationRequest(sourceText: source, pair: pair)
        ])
        guard offlineActionGeneration == actionGeneration,
              currentQuery == source,
              !Task.isCancelled,
              let value = response.first else { return }
        if isNativeLanguageLookup(source) {
            if value.source == .appleSystem {
                shortNativeOfflineResult = value
                shortNativeOfflineStatus = ""
            } else {
                shortNativeOfflineStatus =
                    "Apple 系统离线翻译本次未完成；本地词典结果仍可使用。"
            }
            renderShortNativeLookup()
            offlineActionButton.isEnabled = true
            offlineActionButton.title = "重新进行 Apple 离线翻译（" +
                "\(pair.source.languageIdentifier.chineseName) → " +
                "\(pair.target.languageIdentifier.chineseName)）"
            aiStatusLabel.stringValue = value.source == .appleSystem
                ? "Apple 系统翻译已完成；未调用 AI Provider。"
                : "Apple 系统翻译本次未完成；已保留本地词典结果。"
            return
        }
        if isLearningLanguageLookup(source) {
            if value.source == .appleSystem {
                shortLearningOfflineResult = value
                shortLearningOfflineStatus = ""
            } else {
                shortLearningOfflineStatus =
                    "Apple 系统离线翻译本次未完成；仍可连续按三次 Return 使用 AI 辅助查询。"
            }
            renderShortLearningLookup()
            offlineActionButton.isEnabled = true
            offlineActionButton.title = "重新进行 Apple 离线翻译（" +
                "\(pair.source.languageIdentifier.chineseName) → " +
                "\(pair.target.languageIdentifier.chineseName)）"
            aiStatusLabel.stringValue = value.source == .appleSystem
                ? "Apple 系统翻译已完成；未调用 AI Provider。"
                : "Apple 系统翻译本次未完成；未调用 AI Provider。"
            return
        }
        let output = NSMutableAttributedString(attributedString: textView.attributedString())
        let heading = value.source == .appleSystem
            ? "Apple 系统离线翻译（\(pair.source.languageIdentifier.chineseName) → " +
                "\(pair.target.languageIdentifier.chineseName)）"
            : "本地词典候选"
        output.append(NSAttributedString(
            string: "\n\n\(heading)\n\(value.translatedText)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        displayAttributedText(output)
        offlineActionButton.isEnabled = true
        aiStatusLabel.stringValue = value.source == .appleSystem
            ? "Apple 系统翻译已完成；未调用 AI Provider。"
            : "Apple 系统翻译未在时限内完成，已显示本地词典候选；未调用 AI Provider。"
    }

    @objc private func buildReverseIndexes() {
        guard validateGlobalSelectionActionContext() else { return }
        if reverseBuildTask != nil || reverseIndexCoordinator.currentTask != nil {
            reverseBuildTask?.cancel()
            reverseIndexCoordinator.cancel()
            reverseIndexButton.title = "正在取消反向索引…"
            reverseIndexButton.isEnabled = false
            return
        }
        let eligible = reverseDictionarySources.filter {
            $0.reverseCapability.isBuildEligible
        }
        guard !eligible.isEmpty else { return }
        startReverseIndexBuild(eligible)
    }

    private func startReverseIndexBuild(_ sources: [ReverseDictionarySource]) {
        reverseIndexButton.isEnabled = true
        reverseIndexButton.title = "取消反向索引"
        let query = currentQuery
        reverseBuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reverseBuildTask = nil }
            do {
                let descriptors = try await reverseIndexCoordinator.build(
                    sources
                ) { [weak self] progress in
                    guard let self, self.currentQuery == query else { return }
                    Task {
                        await self.reverseLookupService.replaceBuildStages(
                            Dictionary(uniqueKeysWithValues:
                                progress.dictionaries.map { ($0.dictionaryID, $0.stage) })
                        )
                    }
                    self.displayAttributedText(self.formatReverseIndexProgress(progress))
                    if let current = progress.currentDictionary {
                        self.aiStatusLabel.stringValue = current.isThermallyThrottled
                            ? "系统温度较高，反向索引已自动降速。"
                            : "同一时间只处理一本词典；普通英文查词不使用此反向索引。"
                    }
                }
                await reverseLookupService.mergeDescriptors(descriptors)
                guard self.currentQuery == query else { return }
                self.reverseIndexButton.isEnabled = true
                self.reverseIndexButton.title = "重建中文反向索引…"
                self.prepareChineseReverseLookup(query)
            } catch {
                self.reverseIndexButton.isEnabled = true
                self.reverseIndexButton.title = "重新建立反向索引…"
                self.aiStatusLabel.stringValue =
                    (error as? LocalizedError)?.errorDescription ?? "反向索引建立失败。"
            }
        }
    }

    private func formatReverseIndexProgress(
        _ progress: ReverseIndexBuildProgress
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        output.append(NSAttributedString(
            string: "中文反向索引：已完成 \(progress.completedDictionaries)/" +
                "\(progress.totalDictionaries) 本\n",
            attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold)]
        ))
        for item in progress.dictionaries {
            let count: String
            if let total = item.totalEntries, let percentage = item.entryPercentage {
                count = "\(item.processedEntries)/\(total) 条（\(percentage)%）"
            } else if item.stage == .validating {
                count = "快速安全验证（可取消，不显示伪造百分比）"
            } else if item.stage == .optimizing {
                count = "正在完成 SQLite 优化"
            } else if item.stage == .publishing {
                count = "正在原子发布"
            } else if item.processedEntries > 0 {
                count = "已处理 \(item.processedEntries) 条（总数未知）"
            } else {
                count = "尚未开始计数"
            }
            output.append(NSAttributedString(
                string: "\n\(item.dictionaryName)\n\(item.stage.displayName) · \(count)\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.labelColor]
            ))
            if item.isThermallyThrottled {
                output.append(NSAttributedString(
                    string: "系统温度较高，已降低处理速率。\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 11.5),
                                 .foregroundColor: NSColor.systemOrange]
                ))
            }
            if let failure = item.failureReason {
                output.append(NSAttributedString(
                    string: failure + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 11.5),
                                 .foregroundColor: NSColor.systemRed]
                ))
            }
            if [.failed, .cancelled, .stale].contains(item.stage),
               let encodedID = item.dictionaryID.addingPercentEncoding(
                   withAllowedCharacters: .urlPathAllowed
               ),
               let url = URL(string: "localdictionary://reverse-index-retry/" + encodedID) {
                output.append(NSAttributedString(
                    string: "重试这本词典\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                 .foregroundColor: NSColor.linkColor,
                                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .link: url]
                ))
            }
        }
        if progress.currentDictionary?.canCancel == true,
           let url = URL(string: "localdictionary://reverse-index-cancel") {
            output.append(NSAttributedString(
                string: "\n取消当前词典并清空等待队列\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                             .foregroundColor: NSColor.linkColor,
                             .underlineStyle: NSUnderlineStyle.single.rawValue,
                             .link: url]
            ))
        }
        return output
    }

    private func prepareOfflineTextMode(_ text: String) {
        resetAIState(query: text, intent: .sentence)
        setCurrentEntry(nil)
        let draft = LongTextAnalysisPipeline.initialResult(for: text)
        currentLongTextResult = draft
        recordOfflineTranslationPlan(for: text)
        captureOfflineStudyTexts(from: draft)
        currentLongTextAIStates = Dictionary(uniqueKeysWithValues:
            draft.sentences.map { ($0.id, LongTextAISentenceState.idle) }
        )
        renderLongTextResult(draft)
        aiStatusLabel.stringValue = "基础离线分析不会调用任何 AI Provider"
        updateAIFooter(visible: true)
        configureLongTextAIAction()
        let generation = queryGeneration.generation
        longTextTask?.cancel()
        longTextTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await longTextPipeline.analyze(text)
                await MainActor.run {
                    guard self.currentQuery == text,
                          self.queryGeneration.accepts(generation) else { return }
                    self.currentLongTextResult = result
                    self.captureOfflineStudyTexts(from: result)
                    self.longTextResultRevision &+= 1
                    self.renderLongTextResult(result)
                    self.textView.scrollToBeginningOfDocument(nil)
                    if let missing = result.sentences.lazy.flatMap(\.offlineVersions).first(where: {
                        $0.translationError == .languagePackRequired
                    }) {
                        let pair = missing.pair
                        self.configureOfflineAction(source: text, pair: pair)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.currentQuery == text,
                          self.queryGeneration.accepts(generation) else { return }
                    let latest = self.currentLongTextResult ?? draft
                    self.renderLongTextResult(latest)
                    if let pair = LanguageContext.make(query: text).offlineTranslationPair {
                        self.configureOfflineAction(source: text, pair: pair)
                    }
                }
            }
        }
    }

    private func recordOfflineTranslationPlan(for source: String) {
        let context = LanguageContext.make(query: source)
        guard let plan = OfflineTranslationPlan.make(context: context) else { return }
        ManualEvidenceRecorder.shared.record(
            "offlineTranslationPlanCreated",
            strings: [
                "queryHash": ManualEvidenceRecorder.identityHash(source),
                "nativeLanguage": context.nativeLanguage.rawValue,
                "learningLanguage": context.learningLanguage.rawValue,
                "explanationLanguage": context.explanationLanguage.rawValue,
                "offlineTranslationPairNative": context.nativeLanguage.rawValue,
                "offlineTranslationPairLearning": context.learningLanguage.rawValue,
                "offlineTranslationPlan": plan.kind.rawValue,
                "queryRelation": context.queryRelation.rawValue,
                "dominantLanguage": context.dominantLanguage?.rawValue ?? "undetermined",
                "classifierConfidenceBucket": context.classifierConfidenceBucket.rawValue
            ], integers: [
                "queryGeneration": Int64(clamping: queryGeneration.generation),
                "hanCharacterCount": Int64(context.hanCharacterCount),
                "latinTokenCount": Int64(context.latinTokenCount),
                "plannedOperationCount": Int64(plan.operations.count)
            ]
        )
        for operation in plan.operations {
            ManualEvidenceRecorder.shared.record(
                "offlineTranslationOperationPlanned",
                strings: [
                    "queryHash": ManualEvidenceRecorder.identityHash(source),
                    "offlineTranslationPlan": plan.kind.rawValue,
                    "offlineOutputRole": operation.outputRole.rawValue,
                    "offlineTargetLanguage": operation.pair.target.rawValue,
                    "translationSourceLanguage": operation.pair.source.rawValue,
                    "translationTargetLanguage": operation.pair.target.rawValue
                ], integers: [
                    "queryGeneration": Int64(clamping: queryGeneration.generation)
                ]
            )
        }
    }

    private func configureLongTextAIAction() {
        let text = currentQuery
        let generation = queryGeneration.generation
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            guard let self else { return }
            let availability = await aiService.availability()
            await MainActor.run {
                guard self.currentQuery == text,
                      self.queryGeneration.accepts(generation) else { return }
                self.aiTranslationButton.title = self.ui("AI 深度翻译", "AI Deep Translation")
                self.aiTranslationButton.isHidden = false
                if availability.isEnabled && availability.isConfigured {
                    self.aiAction = .analyzeLongText
                    self.aiActionButton.title = self.ui(
                        "逐句 AI 深度分析", "Sentence-by-Sentence AI Analysis"
                    )
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiTranslationButton.isEnabled = true
                    self.aiSettingsButton.isHidden = true
                    self.aiStatusLabel.stringValue =
                        "两个 AI 入口相互独立；仅点击对应按钮后才会发送当前文本"
                } else {
                    self.aiAction = .none
                    self.aiActionButton.title = self.ui(
                        "逐句 AI 深度分析", "Sentence-by-Sentence AI Analysis"
                    )
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = false
                    self.aiTranslationButton.isEnabled = false
                    self.aiSettingsButton.isHidden = false
                    self.aiStatusLabel.stringValue = "请先配置并启用 AI 服务"
                }
                self.updateAIFooter(visible: true)
            }
        }
    }

    private func requestLongTextAIAnalysis() {
        guard let result = currentLongTextResult else { return }
        let retryIDs = Set(currentLongTextAIStates.compactMap { id, state in
            switch state {
            case .failed, .cancelled: return id
            default: return nil
            }
        })
        let targets = retryIDs.isEmpty
            ? result.sentences
            : result.sentences.filter { retryIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        for sentence in targets {
            requestLongTextSentenceAI(sentenceID: sentence.id)
        }
        refreshLongTextSentenceAIControls()
    }

    private func refreshLongTextSentenceAIControls() {
        let loading = currentLongTextAIStates.values.filter { $0 == .loading }.count
        let failures = currentLongTextAIStates.values.filter {
            if case .failed = $0 { return true }
            return false
        }.count
        let partials = currentLongTextAIStates.values.filter { $0 == .partial }.count
        aiAction = .analyzeLongText
        if loading > 0 {
            aiActionButton.title = ui("正在逐句分析…", "Analyzing Sentences…")
            aiActionButton.isEnabled = false
            aiStatusLabel.stringValue = "正在分析 \(loading) 句；每句拥有独立请求状态。"
        } else {
            aiActionButton.title = failures == 0
                ? ui("重新逐句 AI 深度分析", "Run Sentence AI Analysis Again")
                : ui("重试逐句分析（\(failures) 句失败）",
                     "Retry Sentence Analysis (\(failures) failed)")
            aiActionButton.isEnabled = true
            aiStatusLabel.stringValue = partials == 0
                ? "逐句 AI 结果已更新；基础离线内容仍保留。"
                : "逐句 AI 结果已更新；\(partials) 句显示了可可靠读取的内容。"
        }
        refreshCurrentAICacheControl(query: currentQuery)
    }

    @objc private func requestLongTextAITranslation() {
        guard let result = currentLongTextResult else { return }
        let text = currentQuery
        let generation = queryGeneration.generation
        ManualEvidenceRecorder.shared.record("aiDeepTranslationClicked", strings: [
            "queryHash": ManualEvidenceRecorder.identityHash(text)
        ], integers: [
            "queryGeneration": Int64(clamping: generation)
        ])
        aiTranslationTask?.cancel()
        currentLongTextTranslationStatus = "AI 深度翻译正在请求…"
        aiTranslationButton.title = ui("正在 AI 深度翻译…", "AI Translation in Progress…")
        aiTranslationButton.isEnabled = false
        renderLongTextResult(result)
        refreshCurrentAICacheControl(query: text)
        aiTranslationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = LanguageContext.make(query: text)
                let presentation: AITextTranslationPresentation
                let targetLanguage = context.translationTargetLanguage ?? context.learningLanguage
                if targetLanguage == context.learningLanguage,
                   context.requiresLearningVersion {
                    let canonical = try await self.resolveCanonicalAIStudyText(for: result)
                    presentation = canonical.translationPresentation
                } else if context.isPureLearning,
                          let identity = await aiService.configuredProviderIdentity(),
                          let canonical = self.nativeTranslationFromSentenceAnalyses(
                            for: result, context: context, providerIdentity: identity
                          ) {
                    presentation = canonical
                } else {
                    presentation = try await aiService.translateText(
                        text, targetLanguage: targetLanguage,
                        languageContext: context
                    )
                }
                await MainActor.run {
                    guard self.currentQuery == text,
                          self.queryGeneration.accepts(generation),
                          let latest = self.currentLongTextResult else { return }
                    self.currentLongTextTranslation = presentation
                    ManualEvidenceRecorder.shared.record("aiResultPresented", strings: [
                        "provider": presentation.providerDisplayName,
                        "model": presentation.model,
                        "responseKind": presentation.result.responseParseMode.resultLevel.rawValue,
                        "resultKind": "success",
                        "aiAction": "deepTranslation",
                        "queryHash": ManualEvidenceRecorder.identityHash(text),
                        "queryRelation": context.queryRelation.rawValue,
                        "aiTranslationTargetLanguage":
                            presentation.targetLanguage?.rawValue ?? targetLanguage.rawValue,
                        "aiStudyLanguage": context.studyTextLanguage.rawValue,
                        "aiExplanationLanguage": context.explanationLanguage.rawValue,
                        "aiCacheIdentityHash": presentation.cacheIdentityHash ?? "unavailable",
                        "promptVersion": String(presentation.promptVersion),
                        "cacheSchemaVersion": String(presentation.cacheSchemaVersion)
                    ], integers: [
                        "queryGeneration": Int64(clamping: generation),
                        "responseLength": Int64(presentation.result.translation.count)
                    ], booleans: [
                        "safeVisibleContent": !presentation.result.translation.isEmpty,
                        "cacheHit": presentation.fromCache
                    ])
                    self.applyAIStudyTranslation(presentation.result.translation,
                                                 to: latest)
                    self.currentLongTextTranslationStatus = nil
                    self.aiTranslationButton.title = self.ui(
                        "重新 AI 深度翻译", "Run AI Deep Translation Again"
                    )
                    self.aiTranslationButton.isEnabled = true
                    self.aiTranslationTask = nil
                    self.renderLongTextResult(self.currentLongTextResult ?? latest)
                    self.refreshCurrentAICacheControl(query: text)
                }
            } catch {
                await MainActor.run {
                    guard self.currentQuery == text,
                          self.queryGeneration.accepts(generation),
                          let latest = self.currentLongTextResult else { return }
                    self.currentLongTextTranslationStatus = Task.isCancelled
                        ? "AI 深度翻译已取消。"
                        : "AI 深度翻译失败：\(AIRequestUserMessage.message(for: error))"
                    self.aiTranslationButton.title = self.ui(
                        "重试 AI 深度翻译", "Retry AI Deep Translation"
                    )
                    self.aiTranslationButton.isEnabled = true
                    self.aiTranslationTask = nil
                    self.renderLongTextResult(latest)
                }
            }
        }
    }

    /// Returns text in the configured learning language. Native-language source is
    /// translated only after the user has explicitly clicked an AI action.
    private func resolveStudyText(sourceText: String,
                                  existing: StudyText?,
                                  languageContext: LanguageContext) async throws -> StudyText {
        if languageContext.isPureLearning,
           let existing, existing.language == languageContext.learningLanguage,
           existing.origin == .originalQuery {
            return existing
        }
        if languageContext.isPureLearning,
           let original = StudyText(
            text: sourceText,
            language: languageContext.learningLanguage,
            origin: .originalQuery
           ) {
            return original
        }
        let translated = try await aiService.translateText(
            sourceText, targetLanguage: languageContext.learningLanguage,
            languageContext: languageContext
        )
        guard TargetLanguageValidator.validate(
            translated.result.translation,
            targetLanguage: languageContext.learningLanguage
        ).isTargetLanguage,
              let studyText = StudyText(
                text: translated.result.translation,
                language: languageContext.learningLanguage,
                origin: .aiTranslation
              ) else {
            throw AIClientError.studyTextUnavailable(expected: languageContext.learningLanguage)
        }
        return studyText
    }

    private func resolveCanonicalAIStudyText(
        for result: LongTextAnalysisResult
    ) async throws -> CanonicalAIStudyTextResolution {
        let context = LanguageContext.make(query: result.sourceText)
        guard context.requiresLearningVersion,
              let identity = await aiService.configuredProviderIdentity() else {
            throw AIConfigurationError.missingAPIKey
        }
        let generation = queryGeneration.generation
        if let artifact = currentLongTextAIStudyText,
           artifact.matches(query: result.sourceText, context: context,
                            providerID: identity.providerID, model: identity.model,
                            generation: generation),
           await aiService.isConfiguredProvider(artifact.providerID, model: artifact.model),
           let presentation = currentLongTextTranslation,
           presentation.providerID == artifact.providerID,
           presentation.model == artifact.model {
            ManualEvidenceRecorder.shared.record("aiStudyTextResolved", strings: [
                "aiStudyTextIdentityHash": ManualEvidenceRecorder.identityHash(
                    artifact.studyText.text
                ),
                "provider": artifact.providerID.uuidString.lowercased(),
                "model": artifact.model,
                "resultKind": "success",
                "cache": "hit"
            ], integers: [
                "queryGeneration": Int64(clamping: generation),
                "resultLength": Int64(artifact.studyText.text.count)
            ])
            return CanonicalAIStudyTextResolution(
                artifact: artifact, translationPresentation: presentation
            )
        }
        if let inFlight = currentLongTextAIStudyTextTask {
            return try await inFlight.value
        }
        let sourceText = result.sourceText
        let service = aiService
        let task = Task<CanonicalAIStudyTextResolution, Error> {
            let presentation = try await service.translateText(
                sourceText, targetLanguage: context.learningLanguage,
                languageContext: context
            )
            guard let providerID = presentation.providerID,
                  TargetLanguageValidator.validate(
                    presentation.result.translation,
                    targetLanguage: context.learningLanguage
                  ).isTargetLanguage,
                  let study = StudyText(text: presentation.result.translation,
                                        language: context.learningLanguage,
                                        origin: .aiTranslation) else {
                throw AIClientError.studyTextUnavailable(expected: context.learningLanguage)
            }
            let artifact = AIStudyText(
                queryIdentity: SentenceTextNormalizer.normalize(sourceText),
                sourceText: SentenceTextNormalizer.normalize(sourceText),
                sourceLanguage: context.queryLanguage,
                nativeLanguage: context.nativeLanguage,
                learningLanguage: context.learningLanguage,
                explanationLanguage: context.explanationLanguage,
                queryRelation: context.queryRelation,
                dominantLanguage: context.dominantLanguage,
                translationTargetLanguage: context.learningLanguage,
                studyText: study,
                providerID: providerID,
                model: presentation.model,
                promptVersion: aiTextTranslationPromptVersion,
                generation: generation
            )
            return CanonicalAIStudyTextResolution(
                artifact: artifact, translationPresentation: presentation
            )
        }
        currentLongTextAIStudyTextTask = task
        do {
            let resolution = try await task.value
            guard queryGeneration.accepts(generation),
                  SentenceTextNormalizer.normalize(currentQuery) ==
                    SentenceTextNormalizer.normalize(sourceText) else {
                throw AIClientError.cancelled
            }
            currentLongTextAIStudyTextTask = nil
            currentLongTextAIStudyText = resolution.artifact
            currentLongTextTranslation = resolution.translationPresentation
            ManualEvidenceRecorder.shared.record("aiStudyTextResolved", strings: [
                "aiStudyTextIdentityHash": ManualEvidenceRecorder.identityHash(
                    resolution.artifact.studyText.text
                ),
                "provider": resolution.artifact.providerID.uuidString.lowercased(),
                "model": resolution.artifact.model,
                "resultKind": "success",
                "cache": "miss"
            ], integers: [
                "queryGeneration": Int64(clamping: generation),
                "resultLength": Int64(resolution.artifact.studyText.text.count)
            ])
            return resolution
        } catch {
            if queryGeneration.accepts(generation) {
                currentLongTextAIStudyTextTask = nil
            }
            throw error
        }
    }

    private struct CanonicalAIStudyTextResolution: Sendable {
        let artifact: AIStudyText
        let translationPresentation: AITextTranslationPresentation
    }

    private func canonicalStudyText(for sentenceID: String, sourceText: String,
                                    languageContext: LanguageContext) throws -> StudyText {
        if languageContext.isPureLearning,
           let original = StudyText(text: sourceText,
                                    language: languageContext.learningLanguage,
                                    origin: .originalQuery) {
            return original
        }
        guard let sentence = currentLongTextResult?.sentences.first(where: {
            $0.id == sentenceID
        }), let study = sentence.studyText,
              study.origin == .aiTranslation,
              study.language == languageContext.learningLanguage else {
            throw AIClientError.studyTextUnavailable(expected: languageContext.learningLanguage)
        }
        return study
    }

    private func publishStudyText(_ studyText: StudyText, for sentenceID: String) {
        guard let result = currentLongTextResult,
              var sentence = result.sentences.first(where: { $0.id == sentenceID }) else { return }
        sentence.studyText = studyText
        sentence.basicAnalysis = BasicSentenceAnalyzer().analyze(
            sentence: studyText.text, language: studyText.language.queryLanguage
        )
        currentLongTextResult = result.replacingSentence(sentence)
    }

    private func applyAIStudyTranslation(_ translation: String,
                                         to result: LongTextAnalysisResult) {
        let languageContext = LanguageContext.make(query: result.sourceText)
        guard languageContext.requiresLearningVersion else { return }
        guard let projected = AIStudyTextProjector.project(
            translation: translation, onto: result.sentences,
            learningLanguage: languageContext.learningLanguage
        ) else { return }
        var updated = result
        for source in updated.sentences {
            guard let studyText = projected[source.id] else { continue }
            var replacement = source
            replacement.studyText = studyText
            replacement.basicAnalysis = BasicSentenceAnalyzer().analyze(
                sentence: studyText.text,
                language: languageContext.learningLanguage.queryLanguage
            )
            updated = updated.replacingSentence(replacement)
        }
        currentLongTextResult = updated
    }

    /// For learning-language source, sentence analysis and deep translation must not
    /// present two competing native-language translations. When every sentence is
    /// already analyzed by the currently configured provider, reuse those translations
    /// as the deep-translation result instead of making a second provider request.
    private func nativeTranslationFromSentenceAnalyses(
        for result: LongTextAnalysisResult,
        context: LanguageContext,
        providerIdentity: AIConfiguredProviderIdentity
    ) -> AITextTranslationPresentation? {
        guard context.isPureLearning,
              let firstSentence = result.sentences.first,
              let first = currentLongTextAI[firstSentence.id],
              first.providerID == providerIdentity.providerID,
              first.model == providerIdentity.model else { return nil }
        var translations: [String: String] = [:]
        var presentations: [AISentenceAnalysisPresentation] = []
        for sentence in result.sentences {
            guard let value = currentLongTextAI[sentence.id],
                  value.providerID == providerIdentity.providerID,
                  value.model == providerIdentity.model else { return nil }
            translations[sentence.id] = value.analysis.translationZH
            presentations.append(value)
        }
        guard let translation = CanonicalNativeAITranslation.compose(
            sourceSentences: result.sentences,
            translationsBySentenceID: translations,
            nativeLanguage: context.nativeLanguage
        ) else { return nil }
        let parseMode: AIResponseParseMode
        if presentations.contains(where: {
            $0.analysis.responseParseMode == .plainTextFallback
        }) {
            parseMode = .plainTextFallback
        } else if presentations.contains(where: {
            $0.analysis.responseParseMode == .compatibleJSON
        }) {
            parseMode = .compatibleJSON
        } else {
            parseMode = .strictJSON
        }
        return AITextTranslationPresentation(
            result: AITextTranslation(
                sourceText: result.sourceText,
                translation: translation,
                responseParseMode: parseMode
            ),
            providerDisplayName: first.providerDisplayName,
            model: first.model,
            fromCache: presentations.allSatisfy(\.fromCache),
            providerID: first.providerID,
            targetLanguage: context.nativeLanguage
        )
    }

    /// Sentence analysis has the richer context for each source sentence. If the user
    /// already requested deep translation, promote the complete set of sentence-level
    /// natural translations into that same visible result so the two sections converge.
    private func promoteSentenceTranslationsToDeepTranslation(
        result: LongTextAnalysisResult,
        context: LanguageContext,
        providerID: UUID?,
        model: String
    ) {
        guard context.isPureLearning,
              currentLongTextTranslation != nil,
              let providerID,
              let canonical = nativeTranslationFromSentenceAnalyses(
                for: result,
                context: context,
                providerIdentity: AIConfiguredProviderIdentity(
                    providerID: providerID, model: model
                )
              ) else { return }
        currentLongTextTranslation = canonical
        currentLongTextTranslationStatus = nil
    }

    private func captureOfflineStudyTexts(from result: LongTextAnalysisResult) {
        for sentence in result.sentences {
            guard let study = sentence.studyText,
                  let offline = OfflineStudyText(study) else { continue }
            currentOfflineStudyTexts[sentence.id] = offline
            let profile = LanguageTextProfile.make(study.text)
            ManualEvidenceRecorder.shared.record("offlineStudyTextCreated", strings: [
                "studyTextDeclaredLanguage": study.language.rawValue,
                "resultLanguage": profile.dominantLanguage?.rawValue ?? "undetermined",
                "studyTextOrigin": study.origin.rawValue,
                "offlineOutputRole": OfflineTranslationOutputRole.learningVersion.rawValue
            ], integers: [
                "queryGeneration": Int64(clamping: queryGeneration.generation),
                "hanCharacterCount": Int64(profile.hanCharacterCount),
                "latinTokenCount": Int64(profile.latinTokenCount)
            ])
        }
    }

    private func formattedStudyAnalysis(_ presentation: AISentenceAnalysisPresentation,
                                        originalSource: String,
                                        studyText: StudyText?) -> NSAttributedString {
        let preferences = LanguagePreferencesStore.shared.load()
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 5
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        output.append(NSAttributedString(
            string: ui("原文\n", "Original Source\n"), attributes: labelAttributes
        ))
        output.append(NSAttributedString(string: originalSource + "\n", attributes: valueAttributes))
        if let studyText {
            output.append(NSAttributedString(
                string: ui("学习文本（\(preferences.learningLanguage.chineseName)）\n",
                           "Study Text (\(preferences.learningLanguage.englishName))\n"),
                attributes: labelAttributes
            ))
            output.append(NSAttributedString(string: studyText.text + "\n", attributes: valueAttributes))
        }
        output.append(NSAttributedString(
            string: ui(
                "学习对象：\(preferences.learningLanguage.chineseName) · 解释语言：" +
                    "\(preferences.nativeLanguage.chineseName)\n\n",
                "Study language: \(preferences.learningLanguage.englishName) · " +
                    "Explanation language: \(preferences.nativeLanguage.englishName)\n\n"
            ),
            attributes: labelAttributes
        ))
        output.append(aiSentenceFormatter.format(presentation))
        return output
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
            displayAttributedText(formattedStudyAnalysis(
                presentation,
                originalSource: currentQuery,
                studyText: currentSentenceStudyText
            ))
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
                    self.aiActionButton.title = self.ui("配置 AI 服务…", "Configure AI Service…")
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = true
                    self.updateAIFooter(visible: true)
                    self.renderSentenceContent()
                    return
                }
                self.aiAction = .analyzeSentence(bypassCache: false)
                self.currentSentenceStatus = "可按需请求 AI；本地词语参考不会联网"
                self.aiStatusLabel.stringValue = "完整句子不会自动发送"
                self.aiActionButton.title = self.ui(
                    "AI 翻译与句子解析", "AI Translation and Sentence Analysis"
                )
                self.aiActionButton.isHidden = false
                self.aiActionButton.isEnabled = true
                self.aiSettingsButton.isHidden = true
                self.updateAIFooter(visible: true)
                self.renderSentenceContent()
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
        let requestToken = aiRequestLifecycle.begin()
        aiAction = .cancelSentence
        currentSentenceStatus = "正在分析句子…"
        aiStatusLabel.stringValue = "正在分析句子…"
        aiActionButton.title = ui("取消", "Cancel")
        aiActionButton.isHidden = false
        aiActionButton.isEnabled = true
        aiSettingsButton.isHidden = true
        updateAIFooter(visible: true)
        renderSentenceContent()
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let languageContext = LanguageContext.make(query: sentence)
                let studyText = try await self.resolveStudyText(
                    sourceText: sentence,
                    existing: nil,
                    languageContext: languageContext
                )
                let presentation = try await aiService.analyzeStudyText(
                    studyText,
                    languageContext: languageContext,
                    bypassCache: bypassCache
                )
                let formatted = self.formattedStudyAnalysis(
                    presentation,
                    originalSource: sentence,
                    studyText: studyText
                )
                await MainActor.run {
                    guard self.currentIntent == .sentence,
                          self.currentQuery == sentence,
                          self.queryGeneration.accepts(generation),
                          self.aiRequestLifecycle.finish(requestToken) else { return }
                    self.aiTask = nil
                    self.currentSentencePresentation = presentation
                    self.currentSentenceStudyText = studyText
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
                await MainActor.run {
                    guard self.currentIntent == .sentence,
                          self.currentQuery == sentence,
                          self.queryGeneration.accepts(generation),
                          self.aiRequestLifecycle.finish(requestToken) else { return }
                    self.aiTask = nil
                    self.currentSentencePresentation = nil
                    self.currentSentenceStudyText = nil
                    let message = AIRequestUserMessage.message(for: error)
                    self.currentSentenceStatus = message
                    self.renderSentenceContent()
                    self.aiAction = .analyzeSentence(bypassCache: true)
                    self.aiStatusLabel.stringValue = message
                    self.aiActionButton.title = self.ui("重新查询", "Try Again")
                    self.aiActionButton.isHidden = false
                    self.aiActionButton.isEnabled = true
                    self.aiSettingsButton.isHidden = false
                    self.aiSettingsButton.title = self.ui("更换 AI 服务…", "Change AI Service…")
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
        aiRequestLifecycle.invalidate()
        _ = queryGeneration.beginQuery()
        currentSentencePresentation = nil
        currentSentenceStudyText = nil
        currentSentenceStatus = "句子分析已取消"
        localGlossaryTask?.cancel()
        localGlossaryTask = nil
        renderSentenceContent()
        startLocalGlossaryAnalysis(for: currentQuery)
        aiAction = .analyzeSentence(bypassCache: true)
        aiStatusLabel.stringValue = "句子分析已取消"
        aiActionButton.title = ui("重新查询", "Try Again")
        aiActionButton.isHidden = false
        aiActionButton.isEnabled = true
        aiSettingsButton.isHidden = false
        updateAIFooter(visible: true)
        refreshStarState()
    }

    private func updateAIFooter(visible: Bool, compact: Bool = false) {
        let shouldShow = visible || !offlineActionButton.isHidden || !reverseIndexButton.isHidden
        aiFooter.isHidden = !shouldShow
        if visible, compact { aiActionButton.isHidden = true }
        localActionGroup.isHidden = offlineActionButton.isHidden && reverseIndexButton.isHidden
        remoteAIActionGroup.isHidden = !visible && aiTranslationButton.isHidden &&
            aiActionButton.isHidden &&
            aiSettingsButton.isHidden && aiClearCacheButton.isHidden
        if shouldShow {
            aiFooterHeightConstraint?.isActive = false
        } else {
            aiFooterHeightConstraint?.constant = 0
            aiFooterHeightConstraint?.isActive = true
        }
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
        if clear {
            for supplement in inlineSupplements {
                ManualEvidenceRecorder.shared.record("inlineCardRemoved", strings: [
                    "selectionID": supplement.supplementID.uuidString.lowercased(),
                    "typedReason": "pageOrQueryChanged"
                ], integers: [
                    "selectionGeneration": Int64(clamping: supplement.generation)
                ])
            }
            inlineSupplements.removeAll()
        }
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
        let appearance = window?.contentView?.effectiveAppearance ?? NSApp.effectiveAppearance
        let adapted = DictionaryAppearanceTextAdapter.attributedString(
            byAdapting: output, for: appearance
        )
        textView.textStorage?.setAttributedString(adapted)
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

    func textView(_ textView: NSTextView, clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        guard validateGlobalSelectionActionContext() else { return true }
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url, url.scheme == "localdictionary" else { return false }
        if url.host == "reverse-index-cancel" {
            reverseBuildTask?.cancel()
            reverseIndexCoordinator.cancel()
            reverseIndexButton.title = "正在取消反向索引…"
            reverseIndexButton.isEnabled = false
            return true
        }
        if url.host == "reverse-index-retry",
           let dictionaryID = url.pathComponents.last,
           let source = reverseDictionarySources.first(where: {
               $0.dictionaryID == dictionaryID
           }), reverseBuildTask == nil, reverseIndexCoordinator.currentTask == nil {
            startReverseIndexBuild([source])
            return true
        }
        if url.host == "ai-sentence",
           let sentenceID = url.pathComponents.last,
           sentenceID.hasPrefix("sentence-"),
           currentLongTextResult?.sentences.contains(where: {
               $0.id == sentenceID
           }) == true {
            requestLongTextSentenceAI(sentenceID: sentenceID)
            return true
        }
        guard let result = currentLongTextResult,
              let action = LongTextActionRouter.parse(
                  url,
                  expectedGeneration: queryGeneration.generation,
                  validSentenceIDs: Set(result.sentences.map(\.id))
              ) else { return false }
        performLongTextNativeAction(action)
        return true
    }

    private func performLongTextNativeAction(_ action: LongTextNativeAction) {
        switch action {
        case .translate(let sentenceID, let pair, let generation):
            startDirectionTranslation(
                sentenceID: sentenceID, pair: pair,
                queryGenerationValue: generation, prepareLanguagePack: false
            )
        case .prepareLanguagePack(let sentenceID, let pair, let generation):
            startDirectionTranslation(
                sentenceID: sentenceID, pair: pair,
                queryGenerationValue: generation, prepareLanguagePack: true
            )
        }
    }

    private func startDirectionTranslation(
        sentenceID: String,
        pair: OfflineTranslationPair,
        queryGenerationValue: UInt64,
        prepareLanguagePack: Bool
    ) {
        guard queryGeneration.accepts(queryGenerationValue),
              var result = currentLongTextResult,
              var sentence = result.sentences.first(where: { $0.id == sentenceID }),
              LongTextSegmenter.containsTranslatableLanguage(sentence.sourceText) else {
            return
        }
        directionTasks[sentenceID]?.cancel()
        let sentenceGeneration = directionGenerationGate.begin(sentenceID: sentenceID)
        sentence.translatedText = nil
        sentence.translationError = nil
        sentence.translationState = .translating(pair)
        result = result.replacingSentence(sentence)
        currentLongTextResult = result
        longTextResultRevision &+= 1
        renderLongTextResult(result)
        let query = currentQuery

        directionTasks[sentenceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var availability = await self.longTextPipeline.availability(for: pair)
                if prepareLanguagePack {
                    switch availability {
                    case .supportedNeedsDownload:
                        try await self.longTextPipeline.prepareLanguagePack(for: pair)
                        availability = .installed
                    case .installed:
                        break
                    case .unsupported:
                        throw OfflineTranslationError.unsupportedLanguagePair
                    case .checking, .temporarilyUnavailable:
                        throw OfflineTranslationError.systemFailure
                    }
                }
                switch availability {
                case .installed:
                    break
                case .supportedNeedsDownload:
                    self.applyDirectionState(
                        .languagePackRequired(pair), error: .languagePackRequired,
                        sentenceID: sentenceID, sentenceGeneration: sentenceGeneration,
                        query: query, queryGenerationValue: queryGenerationValue
                    )
                    return
                case .unsupported:
                    throw OfflineTranslationError.unsupportedLanguagePair
                case .checking, .temporarilyUnavailable:
                    throw OfflineTranslationError.systemFailure
                }
                let translated = try await self.longTextPipeline.translateSingleSentence(
                    sentence, pair: pair
                )
                guard self.acceptsDirectionResult(
                    sentenceID: sentenceID,
                    sentenceGeneration: sentenceGeneration,
                    query: query,
                    queryGenerationValue: queryGenerationValue
                ), let latest = self.currentLongTextResult else { return }
                let merged = latest.replacingSentence(translated)
                self.currentLongTextResult = merged
                self.captureOfflineStudyTexts(from: merged)
                self.longTextResultRevision &+= 1
                let vocabularyRevision = self.longTextResultRevision
                self.renderLongTextResult(merged)
                let vocabulary = await self.longTextPipeline.selectVocabulary(
                    from: merged.sentences
                )
                guard self.acceptsDirectionResult(
                    sentenceID: sentenceID,
                    sentenceGeneration: sentenceGeneration,
                    query: query,
                    queryGenerationValue: queryGenerationValue
                ), self.longTextResultRevision == vocabularyRevision,
                   let newest = self.currentLongTextResult else { return }
                let refreshed = newest.replacingVocabulary(vocabulary)
                self.currentLongTextResult = refreshed
                self.renderLongTextResult(refreshed)
                self.aiStatusLabel.stringValue =
                    "第 \(translated.order + 1) 句系统离线翻译已更新。"
            } catch is CancellationError {
                self.applyDirectionState(
                    .cancelled(pair), error: .cancelled,
                    sentenceID: sentenceID, sentenceGeneration: sentenceGeneration,
                    query: query, queryGenerationValue: queryGenerationValue
                )
            } catch let error as OfflineTranslationError {
                self.applyDirectionState(
                    LongTextAnalysisPipeline.state(for: error, pair: pair), error: error,
                    sentenceID: sentenceID, sentenceGeneration: sentenceGeneration,
                    query: query, queryGenerationValue: queryGenerationValue
                )
            } catch {
                self.applyDirectionState(
                    .failed(pair), error: .systemFailure,
                    sentenceID: sentenceID, sentenceGeneration: sentenceGeneration,
                    query: query, queryGenerationValue: queryGenerationValue
                )
            }
            if self.directionGenerationGate.accepts(
                sentenceID: sentenceID, generation: sentenceGeneration
            ) {
                self.directionTasks[sentenceID] = nil
            }
        }
    }

    private func applyDirectionState(
        _ state: LongTextSentenceTranslationState,
        error: OfflineTranslationError,
        sentenceID: String,
        sentenceGeneration: UInt64,
        query: String,
        queryGenerationValue: UInt64
    ) {
        guard acceptsDirectionResult(
            sentenceID: sentenceID,
            sentenceGeneration: sentenceGeneration,
            query: query,
            queryGenerationValue: queryGenerationValue
        ), var result = currentLongTextResult,
           var sentence = result.sentences.first(where: { $0.id == sentenceID }) else {
            return
        }
        sentence.translatedText = nil
        sentence.translationError = error
        sentence.translationState = state
        result = result.replacingSentence(sentence)
        currentLongTextResult = result
        longTextResultRevision &+= 1
        renderLongTextResult(result)
    }

    private func acceptsDirectionResult(sentenceID: String,
                                        sentenceGeneration: UInt64,
                                        query: String,
                                        queryGenerationValue: UInt64) -> Bool {
        currentQuery == query &&
            queryGeneration.accepts(queryGenerationValue) &&
            directionGenerationGate.accepts(
                sentenceID: sentenceID, generation: sentenceGeneration
            ) &&
            !Task.isCancelled
    }

    private func renderLongTextResult(_ result: LongTextAnalysisResult) {
        let formatted = longTextFormatter.format(
            result,
            aiBySentence: currentLongTextAI.mapValues {
                aiSentenceFormatter.format($0)
            },
            aiSentenceStates: currentLongTextAIStates,
            deepTranslation: currentLongTextTranslationDisplay,
            deepTranslationStatus: currentLongTextTranslationStatus,
            queryGeneration: queryGeneration.generation
        )
        displayAttributedText(formatted)
        let heading = "四、AI 深度翻译"
        let range = (formatted.string as NSString).range(of: heading)
        aiSectionCharacterLocation = range.location == NSNotFound ? nil : range.location
        aiIncludeCheckbox.isHidden = aiSectionCharacterLocation == nil
        if !aiIncludeCheckbox.isHidden { positionAIIncludeCheckbox() }
        refreshStarState()
    }

    private func validateGlobalSelectionActionContext() -> Bool {
        guard let context = pendingGlobalSelectionContext else { return true }
        guard globalSelectionPlacement.selectedText(for: context.generation).map({
            SentenceTextNormalizer.normalize($0)
        }) == currentQuery else {
            hide()
            invalidateGlobalSelection(generation: context.generation)
            return false
        }
        return true
    }

    private func requestLongTextSentenceAI(sentenceID: String) {
        guard let result = currentLongTextResult,
              let sentence = result.sentences.first(where: { $0.id == sentenceID })
        else { return }
        let text = currentQuery
        let generation = queryGeneration.generation
        ManualEvidenceRecorder.shared.record("aiSentenceAnalysisClicked", strings: [
            "queryHash": ManualEvidenceRecorder.identityHash(text),
            "sentenceID": sentenceID
        ], integers: [
            "queryGeneration": Int64(clamping: generation)
        ])
        aiStatusLabel.stringValue = "正在分析第 \(sentence.order + 1) 句…"
        if longTextSentenceAITasks[sentenceID] != nil {
            cancelLongTextSentenceAI(sentenceID: sentenceID, reason: .userRetry)
        }
        let operationToken = longTextSentenceAIGate.begin(sentenceID: sentenceID)
        let operationID = operationToken.operationID
        let priorState = currentLongTextAIStates[sentenceID]
        let bypassCache: Bool
        switch priorState {
        case .some(.failed), .some(.cancelled): bypassCache = true
        default: bypassCache = false
        }
        currentLongTextAI.removeValue(forKey: sentenceID)
        currentLongTextAIStates[sentenceID] = .loading
        refreshLongTextSentenceAIControls()
        renderLongTextResult(result)
        refreshCurrentAICacheControl(query: text)
        let task = Task { [weak self] in
            guard let self else { return }
            let availability = await aiService.availability()
            guard availability.isEnabled, availability.isConfigured else {
                await MainActor.run {
                    self.longTextSentenceAICancellationReasons.removeValue(
                        forKey: operationID
                    )
                    guard self.currentQuery == text,
                          self.longTextSentenceAIGate.accepts(operationToken),
                          let latest = self.currentLongTextResult else { return }
                    self.currentLongTextAIStates[sentenceID] = .failed("请先配置并启用 AI 服务。")
                    self.refreshLongTextSentenceAIControls()
                    self.renderLongTextResult(latest)
                    self.recordSentenceOrchestrationTerminal(
                        operationID: operationID, sentenceID: sentenceID,
                        generation: generation, resultKind: "failure",
                        reason: "providerNotConfigured"
                    )
                    self.longTextSentenceAITasks[sentenceID] = nil
                    _ = self.longTextSentenceAIGate.finish(operationToken)
                    self.openAISettings()
                }
                return
            }
            do {
                let context = LanguageContext.make(query: sentence.sourceText)
                let study: StudyText
                if context.requiresLearningVersion,
                   let fullResult = self.currentLongTextResult {
                    let canonical = try await self.resolveCanonicalAIStudyText(for: fullResult)
                    self.applyAIStudyTranslation(
                        canonical.artifact.studyText.text, to: fullResult
                    )
                    study = try self.canonicalStudyText(
                        for: sentence.id, sourceText: sentence.sourceText,
                        languageContext: context
                    )
                } else {
                    study = try await self.resolveStudyText(
                        sourceText: sentence.sourceText,
                        existing: sentence.studyText,
                        languageContext: context
                    )
                }
                self.publishStudyText(study, for: sentence.id)
                let diagnostic = AIProviderDiagnosticContext(
                    action: "sentenceAnalysis",
                    operationID: operationID.uuidString.lowercased(),
                    queryGeneration: generation,
                    aiStudyTextIdentityHash: ManualEvidenceRecorder.identityHash(study.text),
                    sentenceID: sentenceID
                )
                let presentation = try await aiService.analyzeStudyText(
                    study, languageContext: context, bypassCache: bypassCache,
                    diagnosticContext: diagnostic
                )
                await MainActor.run {
                    self.longTextSentenceAICancellationReasons.removeValue(
                        forKey: operationID
                    )
                    guard self.currentQuery == text,
                          self.queryGeneration.accepts(generation),
                          self.longTextSentenceAIGate.accepts(operationToken),
                          let latest = self.currentLongTextResult else { return }
                    self.currentLongTextAI[sentenceID] = presentation
                    self.currentLongTextAIStates[sentenceID] =
                        presentation.analysis.responseParseMode.isPartial
                            ? .partial : .success
                    self.promoteSentenceTranslationsToDeepTranslation(
                        result: latest,
                        context: context,
                        providerID: presentation.providerID,
                        model: presentation.model
                    )
                    ManualEvidenceRecorder.shared.record("aiResultPresented", strings: [
                        "provider": presentation.providerDisplayName,
                        "model": presentation.model,
                        "responseKind": presentation.analysis.responseParseMode
                            .resultLevel.rawValue,
                        "resultKind": "success",
                        "aiAction": "sentenceAnalysis",
                        "sentenceID": sentenceID,
                        "aiStudyTextIdentityHash": ManualEvidenceRecorder.identityHash(study.text)
                    ], integers: [
                        "queryGeneration": Int64(clamping: generation)
                    ], booleans: [
                        "safeVisibleContent": true,
                        "cacheHit": presentation.fromCache
                    ])
                    self.renderLongTextResult(self.currentLongTextResult ?? latest)
                    self.recordSentenceOrchestrationTerminal(
                        operationID: operationID, sentenceID: sentenceID,
                        generation: generation, resultKind: "success",
                        reason: "visibleContent"
                    )
                    self.longTextSentenceAITasks[sentenceID] = nil
                    _ = self.longTextSentenceAIGate.finish(operationToken)
                    self.refreshLongTextSentenceAIControls()
                }
            } catch {
                await MainActor.run {
                    let cancellationReason =
                        self.longTextSentenceAICancellationReasons.removeValue(
                            forKey: operationID
                        ) ?? ((Task.isCancelled || self.isAICancellation(error))
                              ? .providerAbort : nil)
                    self.recordSentenceOrchestrationTerminal(
                        operationID: operationID, sentenceID: sentenceID,
                        generation: generation,
                        resultKind: cancellationReason == nil ? "failure" : "cancelled",
                        reason: cancellationReason?.rawValue ?? self.typedAIErrorReason(error)
                    )
                    guard self.currentQuery == text,
                          self.queryGeneration.accepts(generation),
                          self.longTextSentenceAIGate.accepts(operationToken),
                          let latest = self.currentLongTextResult else { return }
                    let reason = AIRequestUserMessage.message(for: error)
                    self.currentLongTextAIStates[sentenceID] = cancellationReason != nil
                        ? .cancelled : .failed(reason)
                    self.renderLongTextResult(latest)
                    self.longTextSentenceAITasks[sentenceID] = nil
                    _ = self.longTextSentenceAIGate.finish(operationToken)
                    self.refreshLongTextSentenceAIControls()
                }
            }
        }
        longTextSentenceAITasks[sentenceID] = task
    }

    private func cancelLongTextSentenceAI(
        sentenceID: String, reason: AIRequestCancellationReason
    ) {
        guard let task = longTextSentenceAITasks[sentenceID],
              let operationID = longTextSentenceAIGate.activeOperationID(
                for: sentenceID
              ) else { return }
        longTextSentenceAICancellationReasons[operationID] = reason
        ManualEvidenceRecorder.shared.record("aiSentenceCancellationRequested", strings: [
            "sentenceAnalysisOperationID": operationID.uuidString.lowercased(),
            "sentenceID": sentenceID,
            "typedReason": reason.rawValue
        ], integers: [
            "queryGeneration": Int64(clamping: queryGeneration.generation)
        ])
        task.cancel()
    }

    private func cancelAllLongTextSentenceAI(reason: AIRequestCancellationReason) {
        for sentenceID in Array(longTextSentenceAITasks.keys) {
            cancelLongTextSentenceAI(sentenceID: sentenceID, reason: reason)
        }
        longTextSentenceAITasks.removeAll()
        longTextSentenceAIGate.invalidateAll()
    }

    private func recordSentenceOrchestrationTerminal(
        operationID: UUID, sentenceID: String, generation: UInt64,
        resultKind: String, reason: String
    ) {
        ManualEvidenceRecorder.shared.record("aiSentenceOrchestrationTerminal", strings: [
            "sentenceAnalysisOperationID": operationID.uuidString.lowercased(),
            "sentenceID": sentenceID,
            "resultKind": resultKind,
            "terminalReason": reason
        ], integers: ["queryGeneration": Int64(clamping: generation)])
    }

    private func typedAIErrorReason(_ error: Error) -> String {
        let underlying = (error as? AIProviderRequestFailure)?.underlying ?? error
        guard let client = underlying as? AIClientError else {
            return "unknownFailure"
        }
        switch client {
        case .providerEmptyResponse, .emptyResponse: return "providerEmptyResponse"
        case .providerReasoningOnly: return "providerReasoningOnly"
        case .normalizationDroppedVisibleContent:
            return "normalizationDroppedVisibleContent"
        case .malformedProviderEnvelope: return "malformedProviderEnvelope"
        case .cancelled: return AIRequestCancellationReason.providerAbort.rawValue
        default: return String(describing: client)
        }
    }

    private func isAICancellation(_ error: Error) -> Bool {
        let underlying = (error as? AIProviderRequestFailure)?.underlying ?? error
        if underlying is CancellationError { return true }
        return (underlying as? AIClientError) == .cancelled
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
        // Keep the auxiliary panel above the current full-screen Space. Dropping to `.normal`
        // here made it appear to vanish behind Zotero/browser full-screen windows.
        window?.level = .floating
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
        for index in inlineSupplements.indices.reversed() {
            guard case .compactFailure = inlineSupplements[index].state else { continue }
            let stale = inlineSupplements[index]
            inlineTasks[stale.supplementID]?.cancel()
            inlineTasks[stale.supplementID] = nil
            ManualEvidenceRecorder.shared.record("inlineCardRemoved", strings: [
                "selectionID": stale.supplementID.uuidString.lowercased(),
                "typedReason": "newSelectionAfterFailure"
            ], integers: [
                "selectionGeneration": Int64(clamping: stale.generation &+ 1)
            ])
            inlineSupplements.remove(at: index)
        }
        if let existing = inlineSupplements.first(where: {
            $0.duplicateKey == snapshot.duplicateKey
        }) {
            scrollInlineSupplementToVisible(existing.supplementID)
            return
        }
        let id = UUID()
        let pageID = inlinePageID
        let plannedOfflineOperation = inlineOfflineTranslationOperation(
            for: snapshot.selectedText
        )
        let preferences = LanguagePreferencesStore.shared.load()
        let deferAppleUntilLocalMiss = snapshot.selectionKind == .word &&
            plannedOfflineOperation?.pair.source.languageIdentifier ==
                preferences.learningLanguage
        let offlineOperation = deferAppleUntilLocalMiss ? nil : plannedOfflineOperation
        ManualEvidenceRecorder.shared.record("inlineSelectionCreated", strings: [
            "selectionID": id.uuidString.lowercased(),
            "inlineSelectionKind": snapshot.selectionKind.rawValue,
            "selectionHash": ManualEvidenceRecorder.identityHash(snapshot.normalizedText)
        ], integers: [
            "selectionGeneration": 1,
            "selectionLength": Int64(snapshot.selectedText.count),
            "queryGeneration": Int64(clamping: queryGeneration.generation)
        ])
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
            offlineTranslationState: offlineOperation.map {
                .checking($0.pair)
            } ?? .notRequested,
            state: offlineOperation != nil
                ? .loadingOffline
                : (snapshot.selectionKind == .word
                    ? .loadingQuick : .aiActionAvailable(localMiss: false)),
            generation: 1
        ))
        ManualEvidenceRecorder.shared.record("inlineCardPresented", strings: [
            "selectionID": id.uuidString.lowercased(),
            "inlineSelectionKind": snapshot.selectionKind.rawValue
        ], integers: ["selectionGeneration": 1])
        renderInlinePage()
        if let offlineOperation {
            ManualEvidenceRecorder.shared.record(
                "inlineOfflineTranslationPlanned",
                strings: [
                    "selectionID": id.uuidString.lowercased(),
                    "inlineSelectionKind": snapshot.selectionKind.rawValue,
                    "offlineOutputRole": offlineOperation.outputRole.rawValue,
                    "translationSourceLanguage": offlineOperation.pair.source.rawValue,
                    "translationTargetLanguage": offlineOperation.pair.target.rawValue
                ],
                integers: ["selectionGeneration": 1]
            )
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performInlineOfflineTranslation(
                    id: id,
                    pageID: pageID,
                    text: snapshot.selectedText,
                    normalizedText: snapshot.normalizedText,
                    kind: snapshot.selectionKind,
                    operation: offlineOperation,
                    generation: 1
                )
            }
            inlineTasks[id] = task
            return
        }
        if snapshot.selectionKind != .word {
            ManualEvidenceRecorder.shared.record("inlineAIActionPresented", strings: [
                "selectionID": id.uuidString.lowercased(),
                "inlineSelectionKind": snapshot.selectionKind.rawValue
            ], integers: ["selectionGeneration": 1])
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performInlineWordLocalLookup(
                id: id, pageID: pageID, text: snapshot.selectedText,
                normalizedText: snapshot.normalizedText, generation: 1
            )
        }
        inlineTasks[id] = task
    }

    private func inlineOfflineTranslationOperation(
        for text: String
    ) -> PlannedOfflineTranslation? {
        InlineOfflineTranslationPlanner.operation(
            for: text,
            preferences: LanguagePreferencesStore.shared.load()
        )
    }

    private func performInlineOfflineTranslation(
        id: UUID,
        pageID: UUID,
        text: String,
        normalizedText: String,
        kind: InlineLookupSelectionKind,
        operation: PlannedOfflineTranslation,
        generation: UInt64
    ) async {
        let pair = operation.pair
        let availability = await offlineTranslation.availability(for: pair)
        guard !Task.isCancelled else { return }
        ManualEvidenceRecorder.shared.record(
            "inlineOfflineAvailability",
            strings: [
                "selectionID": id.uuidString.lowercased(),
                "inlineSelectionKind": kind.rawValue,
                "translationSourceLanguage": pair.source.rawValue,
                "translationTargetLanguage": pair.target.rawValue,
                "systemAvailability": inlineAvailabilityEvidence(availability)
            ],
            integers: ["selectionGeneration": Int64(clamping: generation)]
        )
        switch availability {
        case .installed where InlineOfflineTranslationPlanner.automaticallyTranslates(
            availability: availability
        ):
            await MainActor.run {
                self.updateInlineSupplement(
                    id: id,
                    pageID: pageID,
                    generation: generation,
                    expectedNormalizedText: normalizedText,
                    clearTask: false
                ) {
                    $0.offlineTranslationState = .translating(pair)
                    $0.state = .loadingOffline
                }
            }
            guard !Task.isCancelled else { return }
            ManualEvidenceRecorder.shared.record(
                "inlineOfflineTranslationStarted",
                strings: [
                    "selectionID": id.uuidString.lowercased(),
                    "translationSourceLanguage": pair.source.rawValue,
                    "translationTargetLanguage": pair.target.rawValue
                ],
                integers: ["selectionGeneration": Int64(clamping: generation)]
            )
            do {
                let responses = try await offlineTranslation.translate([
                    OfflineTranslationRequest(
                        sourceText: text,
                        pair: pair,
                        outputRole: operation.outputRole
                    )
                ])
                guard !Task.isCancelled, let translated = responses.first else { return }
                await MainActor.run {
                    self.updateInlineSupplement(
                        id: id,
                        pageID: pageID,
                        generation: generation,
                        expectedNormalizedText: normalizedText
                    ) {
                        $0.offlineTranslationState = .translated(
                            text: translated.translatedText,
                            pair: pair
                        )
                        $0.state = .aiActionAvailable(localMiss: false)
                    }
                    self.recordInlineAIActionPresented(
                        id: id, kind: kind, generation: generation
                    )
                    ManualEvidenceRecorder.shared.record(
                        "inlineOfflineTranslationSucceeded",
                        strings: [
                            "selectionID": id.uuidString.lowercased(),
                            "translationSourceLanguage": pair.source.rawValue,
                            "translationTargetLanguage": pair.target.rawValue,
                            "translationSource": translated.source.rawValue
                        ],
                        integers: [
                            "selectionGeneration": Int64(clamping: generation),
                            "resultLength": Int64(translated.translatedText.count)
                        ]
                    )
                }
            } catch is CancellationError {
                return
            } catch let error as OfflineTranslationError where error == .cancelled {
                return
            } catch {
                await MainActor.run {
                    self.finishInlineOfflineWithoutTranslation(
                        id: id,
                        pageID: pageID,
                        normalizedText: normalizedText,
                        kind: kind,
                        generation: generation,
                        state: .failed(pair),
                        typedReason: String(describing: error)
                    )
                }
            }
        case .installed:
            // Kept exhaustive if the planner's installed-only policy changes in the future.
            await MainActor.run {
                self.finishInlineOfflineWithoutTranslation(
                    id: id,
                    pageID: pageID,
                    normalizedText: normalizedText,
                    kind: kind,
                    generation: generation,
                    state: .unavailable(pair),
                    typedReason: "automaticTranslationPolicyDenied"
                )
            }
        case .supportedNeedsDownload:
            await MainActor.run {
                self.finishInlineOfflineWithoutTranslation(
                    id: id,
                    pageID: pageID,
                    normalizedText: normalizedText,
                    kind: kind,
                    generation: generation,
                    state: .languagePackRequired(pair),
                    typedReason: "languagePackRequired"
                )
            }
        case .unsupported, .checking, .temporarilyUnavailable:
            await MainActor.run {
                self.finishInlineOfflineWithoutTranslation(
                    id: id,
                    pageID: pageID,
                    normalizedText: normalizedText,
                    kind: kind,
                    generation: generation,
                    state: .unavailable(pair),
                    typedReason: inlineAvailabilityEvidence(availability)
                )
            }
        }
    }

    private func finishInlineOfflineWithoutTranslation(
        id: UUID,
        pageID: UUID,
        normalizedText: String,
        kind: InlineLookupSelectionKind,
        generation: UInt64,
        state: InlineOfflineTranslationState,
        typedReason: String
    ) {
        updateInlineSupplement(
            id: id,
            pageID: pageID,
            generation: generation,
            expectedNormalizedText: normalizedText
        ) {
            $0.offlineTranslationState = state
            $0.state = .aiActionAvailable(localMiss: false)
        }
        recordInlineAIActionPresented(id: id, kind: kind, generation: generation)
        ManualEvidenceRecorder.shared.record(
            "inlineOfflineTranslationUnavailable",
            strings: [
                "selectionID": id.uuidString.lowercased(),
                "typedReason": typedReason
            ],
            integers: ["selectionGeneration": Int64(clamping: generation)]
        )
    }

    private func recordInlineAIActionPresented(
        id: UUID,
        kind: InlineLookupSelectionKind,
        generation: UInt64
    ) {
        ManualEvidenceRecorder.shared.record("inlineAIActionPresented", strings: [
            "selectionID": id.uuidString.lowercased(),
            "inlineSelectionKind": kind.rawValue
        ], integers: ["selectionGeneration": Int64(clamping: generation)])
    }

    private func inlineAvailabilityEvidence(
        _ availability: OfflineTranslationAvailability
    ) -> String {
        switch availability {
        case .installed: return "installed"
        case .supportedNeedsDownload: return "downloadable"
        case .unsupported: return "unsupported"
        case .checking: return "checking"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        }
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

    private func performInlineWordLocalLookup(id: UUID, pageID: UUID, text: String,
                                              normalizedText: String,
                                              generation: UInt64) async {
        ManualEvidenceRecorder.shared.record("localInlineLookupStarted", strings: [
            "selectionID": id.uuidString.lowercased(),
            "inlineSelectionKind": InlineLookupSelectionKind.word.rawValue
        ], integers: ["selectionGeneration": Int64(clamping: generation)])
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
                ManualEvidenceRecorder.shared.record("localInlineLookupHit", strings: [
                    "selectionID": id.uuidString.lowercased(),
                    "inlineSelectionKind": InlineLookupSelectionKind.word.rawValue
                ], integers: ["selectionGeneration": Int64(clamping: generation)])
            }
            return
        }
        if let operation = inlineOfflineTranslationOperation(for: text) {
            await MainActor.run {
                self.updateInlineSupplement(
                    id: id, pageID: pageID, generation: generation,
                    expectedNormalizedText: normalizedText, clearTask: false
                ) {
                    $0.offlineTranslationState = .checking(operation.pair)
                    $0.state = .loadingOffline
                }
                ManualEvidenceRecorder.shared.record(
                    "inlineOfflineTranslationPlanned",
                    strings: [
                        "selectionID": id.uuidString.lowercased(),
                        "inlineSelectionKind": InlineLookupSelectionKind.word.rawValue,
                        "offlineOutputRole": operation.outputRole.rawValue,
                        "translationSourceLanguage": operation.pair.source.rawValue,
                        "translationTargetLanguage": operation.pair.target.rawValue,
                        "trigger": "localWordMiss"
                    ],
                    integers: ["selectionGeneration": Int64(clamping: generation)]
                )
            }
            await performInlineOfflineTranslation(
                id: id, pageID: pageID, text: text,
                normalizedText: normalizedText, kind: .word,
                operation: operation, generation: generation
            )
            return
        }
        await MainActor.run {
            self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                        expectedNormalizedText: normalizedText) {
                $0.preparedLocalExpansion = local.expansion
                $0.state = .aiActionAvailable(localMiss: true)
            }
            ManualEvidenceRecorder.shared.record("localInlineLookupMiss", strings: [
                "selectionID": id.uuidString.lowercased(),
                "inlineSelectionKind": InlineLookupSelectionKind.word.rawValue
            ], integers: ["selectionGeneration": Int64(clamping: generation)])
            ManualEvidenceRecorder.shared.record("inlineAIActionPresented", strings: [
                "selectionID": id.uuidString.lowercased(),
                "inlineSelectionKind": InlineLookupSelectionKind.word.rawValue
            ], integers: ["selectionGeneration": Int64(clamping: generation)])
        }
    }

    private func performInlineAI(id: UUID, pageID: UUID, text: String,
                                 normalizedText: String,
                                 kind: InlineLookupSelectionKind,
                                 generation: UInt64) async {
        let mayRequestAI = await MainActor.run {
            self.inlineQueryStillValid(id: id, pageID: pageID, generation: generation,
                                       expectedNormalizedText: normalizedText)
        }
        guard mayRequestAI, !Task.isCancelled else { return }
        do {
            let diagnostic = AIProviderDiagnosticContext(
                action: "inlineAI", queryGeneration: queryGeneration.generation,
                selectionID: id.uuidString.lowercased(),
                selectionGeneration: generation
            )
            let result: InlineLookupQuickResult
            switch kind {
            case .sentence:
                result = .sentence(try await aiService.inlineSentenceQuick(
                    text, diagnosticContext: diagnostic
                ))
            case .word, .phrase:
                result = .word(try await aiService.inlineWordQuick(
                    text, diagnosticContext: diagnostic
                ))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                            expectedNormalizedText: normalizedText) {
                    $0.quickResult = result
                    switch result {
                    case .sentence(let value):
                        $0.aiProvider = value.providerDisplayName
                        $0.aiModel = value.model
                    case .word(let value):
                        $0.aiProvider = value.providerDisplayName
                        $0.aiModel = value.model
                    }
                    $0.state = .success
                }
                ManualEvidenceRecorder.shared.record("inlineAISuccess", strings: [
                    "selectionID": id.uuidString.lowercased(),
                    "inlineSelectionKind": kind.rawValue
                ], integers: ["selectionGeneration": Int64(clamping: generation)])
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.updateInlineSupplement(id: id, pageID: pageID, generation: generation,
                                            expectedNormalizedText: normalizedText) {
                    $0.state = .compactFailure(
                        "AI 本次未返回可显示内容"
                    )
                }
                ManualEvidenceRecorder.shared.record("inlineAIFailure", strings: [
                    "selectionID": id.uuidString.lowercased(),
                    "inlineSelectionKind": kind.rawValue,
                    "typedReason": self.typedAIErrorReason(error)
                ], integers: ["selectionGeneration": Int64(clamping: generation)])
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
                                        clearTask: Bool = true,
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
        ManualEvidenceRecorder.shared.record("inlineCardReused", strings: [
            "selectionID": id.uuidString.lowercased(),
            "inlineSelectionKind": inlineSupplements[index].selectionKind.rawValue
        ], integers: ["selectionGeneration": Int64(clamping: generation)])
        if clearTask { inlineTasks[id] = nil }
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
                        $0.state = .compactFailure("AI 本次未返回可显示内容")
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
        ManualEvidenceRecorder.shared.record("inlineCardRemoved", strings: [
            "selectionID": id.uuidString.lowercased(),
            "typedReason": "userClose"
        ], integers: [
            "selectionGeneration": Int64(clamping: inlineSupplements[index].generation)
        ])
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
            switch supplement.state {
            case .aiActionAvailable:
                let ai = inlineControlButton(
                    title: "AI 双语解释", id: supplement.supplementID,
                    action: #selector(requestInlineAI(_:))
                )
                ai.isBordered = true
                ai.bezelStyle = .rounded
                ai.frame.origin = NSPoint(x: x, y: rect.minY)
                x += ai.frame.width + 8
            case .loadingAI:
                let loading = inlineControlButton(
                    title: "正在请求…", id: supplement.supplementID,
                    action: #selector(requestInlineAI(_:))
                )
                loading.isEnabled = false
                loading.frame.origin = NSPoint(x: x, y: rect.minY)
                x += loading.frame.width + 8
            case .compactFailure:
                let retry = inlineControlButton(
                    title: "重试", id: supplement.supplementID,
                    action: #selector(requestInlineAI(_:))
                )
                retry.isBordered = true
                retry.bezelStyle = .rounded
                retry.frame.origin = NSPoint(x: x, y: rect.minY)
                x += retry.frame.width + 8
            case .loadingQuick, .loadingOffline, .loadingExpansion, .success:
                break
            }
            if supplement.quickResult != nil && supplement.expandedResult == nil,
               supplement.state == .success {
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

    @objc private func requestInlineAI(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let index = inlineSupplements.firstIndex(where: { $0.supplementID == id }) else {
            return
        }
        let previousState = inlineSupplements[index].state
        switch previousState {
        case .aiActionAvailable, .compactFailure:
            break
        default:
            return
        }
        inlineTasks[id]?.cancel()
        inlineSupplements[index].generation &+= 1
        let generation = inlineSupplements[index].generation
        let pageID = inlinePageID
        let text = inlineSupplements[index].selectedText
        let normalizedText = inlineSupplements[index].normalizedText
        let kind = inlineSupplements[index].selectionKind
        inlineSupplements[index].state = .loadingAI
        ManualEvidenceRecorder.shared.record("inlineAIActionClicked", strings: [
            "selectionID": id.uuidString.lowercased(),
            "inlineSelectionKind": kind.rawValue
        ], integers: [
            "selectionGeneration": Int64(clamping: generation),
            "queryGeneration": Int64(clamping: queryGeneration.generation)
        ])
        if case .compactFailure = previousState {
            ManualEvidenceRecorder.shared.record("inlineAIRetryClicked", strings: [
                "selectionID": id.uuidString.lowercased()
            ], integers: ["selectionGeneration": Int64(clamping: generation)])
        }
        renderInlinePage()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performInlineAI(
                id: id, pageID: pageID, text: text, normalizedText: normalizedText,
                kind: kind, generation: generation
            )
        }
        inlineTasks[id] = task
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
        window?.makeKey()
        if let fieldEditor = searchField.currentEditor() as? NSTextView {
            fieldEditor.allowsUndo = true
            fieldEditor.menu = editingContextMenu(includeModificationCommands: true)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              field === searchField else { return }
        let edited = SentenceTextNormalizer.normalize(searchField.stringValue)
        if edited != tripleReturnAITrigger.queryIdentity {
            tripleReturnAITrigger.reset()
            pendingTripleReturnAITask?.cancel()
            pendingTripleReturnAITask = nil
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
        guard notePicker.ensureObsidianAvailable() else { return }
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
            if let result = currentLongTextResult {
                return longTextNoteContent(
                    result, inlineSupplements: inlineItems
                ).map(NoteSaveContent.sentence)
            }
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
                inlineSupplements: inlineItems,
                languageMetadata: favoriteLanguageMetadata(
                    source: currentQuery,
                    studyLanguage: currentSentenceStudyText?.language
                )
            )
            return .sentence(content)
        }
        if isNativeLanguageLookup(currentQuery) {
            guard let presentation = currentAIPresentation else { return nil }
            let aiSection = aiMarkdownFormatter.section(
                for: presentation, headword: currentQuery
            )
            let content = VocabularyNoteSaveContent(
                headword: currentQuery, localEntry: nil,
                aiSection: aiSection, inlineSupplements: [],
                languageMetadata: favoriteLanguageMetadata(source: currentQuery)
            )
            return content.isValid ? .vocabulary(content) : nil
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
                                                inlineSupplements: inlineItems,
                                                languageMetadata:
                                                    favoriteLanguageMetadata(source: currentQuery))
        return content.isValid ? .vocabulary(content) : nil
    }

    private func isNativeLanguageLookup(_ query: String) -> Bool {
        let classification = QueryIntentClassifier.classify(query)
        guard classification.intent == .word || classification.intent == .phrase else {
            return false
        }
        let context = LanguageContext.make(
            classification: classification,
            preferences: LanguagePreferencesStore.shared.load()
        )
        return context.isNativeDominant &&
            LanguageCapabilityRegistry.shared.isProductionPair(
                native: context.nativeLanguage, learning: context.learningLanguage
            )
    }

    private func isLearningLanguageLookup(_ query: String) -> Bool {
        let classification = QueryIntentClassifier.classify(query)
        guard classification.intent == .word || classification.intent == .phrase else {
            return false
        }
        let context = LanguageContext.make(
            classification: classification,
            preferences: LanguagePreferencesStore.shared.load()
        )
        return context.isPureLearning &&
            LanguageCapabilityRegistry.shared.isProductionPair(
                native: context.nativeLanguage, learning: context.learningLanguage
            )
    }

    private func longTextNoteContent(
        _ result: LongTextAnalysisResult,
        inlineSupplements: [InlineLookupNoteItem]
    ) -> SentenceNoteSaveContent? {
        let source = SentenceTextNormalizer.normalize(result.sourceText)
        guard !source.isEmpty else { return nil }
        var local = ["### 本地词语参考", ""]
        let appleTranslations = result.sentences.compactMap { sentence -> String? in
            guard sentence.translationSource == .appleSystem,
                  let value = sentence.translatedText,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "- \(sentence.order + 1). \(noteInline(value))"
        }
        if !appleTranslations.isEmpty {
            local += ["#### Apple 系统离线翻译", ""] + appleTranslations + [""]
        }
        if !result.vocabulary.isEmpty {
            local += ["#### 重点词汇", ""]
            for item in result.vocabulary.prefix(OfflineVocabularySelector.maximumItems) {
                local.append("- **\(noteInline(item.term))**：" +
                    "\(noteInline(item.meaningOrSuggestion))（来源：\(noteInline(item.source))）")
            }
            local.append("")
        }
        local += ["#### 基础结构分析", ""]
        for sentence in result.sentences {
            let analysis = sentence.basicAnalysis
            local.append("- **第 \(sentence.order + 1) 句**：\(noteInline(sentence.sourceText))")
            local.append("  - 主语/话题：\(noteInline(analysis.subjectOrTopic))")
            local.append("  - 主要谓语：\(noteInline(analysis.predicate))")
            local.append("  - 宾语/补语：\(noteInline(analysis.objectOrComplement))")
            for hint in analysis.structureHints.prefix(8) {
                local.append("  - \(noteInline(hint))")
            }
        }
        while local.last == "" { local.removeLast() }

        var aiLines: [String] = []
        if aiIncludeCheckbox.state == .on,
           currentLongTextTranslationDisplay != nil || !currentLongTextAI.isEmpty {
            aiLines = ["### AI 解析", ""]
            if let deep = currentLongTextTranslationDisplay {
                aiLines += [
                    "#### AI 深度翻译", "",
                    "> 由 \(safeNoteProvider(deep.providerDisplayName)) · " +
                        "\(noteInline(deep.model)) 生成", "",
                    noteInline(deep.translation), ""
                ]
            }
            for sentence in result.sentences {
                guard let presentation = currentLongTextAI[sentence.id] else { continue }
                var section = sentenceMarkdownFormatter.aiMarkdownSection(presentation)
                    .components(separatedBy: "\n")
                if section.first == "### AI 解析" { section.removeFirst() }
                while section.first == "" { section.removeFirst() }
                aiLines += ["#### 第 \(sentence.order + 1) 句 AI 深度分析", ""] +
                    section + [""]
            }
            while aiLines.last == "" { aiLines.removeLast() }
        }
        var preview = source.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "|", with: "｜")
        if preview.count > 48 { preview = String(preview.prefix(47)) + "…" }
        let content = SentenceNoteSaveContent(
            sourceText: source,
            title: "长文本分析｜" + preview,
            aiSectionMarkdown: aiLines.isEmpty ? nil : aiLines.joined(separator: "\n"),
            glossarySectionMarkdown: local.joined(separator: "\n"),
            inlineSupplements: inlineSupplements,
            languageMetadata: favoriteLanguageMetadata(
                source: source,
                studyLanguage: result.sentences.compactMap(\.studyText?.language).first
            )
        )
        return content.isValid ? content : nil
    }

    private func favoriteLanguageMetadata(
        source: String,
        studyLanguage: LanguageIdentifier? = nil
    ) -> FavoriteLanguageMetadata {
        let context = LanguageContext.make(query: source)
        return FavoriteLanguageMetadata(
            sourceLanguage: context.queryLanguage,
            nativeLanguage: context.nativeLanguage,
            learningLanguage: context.learningLanguage,
            studyLanguage: studyLanguage
        )
    }

    private func safeNoteProvider(_ value: String) -> String {
        let clean = noteInline(value)
        let lower = clean.lowercased()
        return clean.isEmpty || clean.contains("牛津") || lower.contains("oxford")
            ? "自定义 AI 服务" : clean
    }

    private func noteInline(_ value: String) -> String {
        var clean = SentenceTextNormalizer.normalize(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "[", "]", "<", ">", "#"] {
            clean = clean.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return clean
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
                starButton.toolTip = ui(
                    "当前没有可以保存的句子学习内容", "There is no sentence study content to save"
                )
            } else {
                starButton.toolTip = currentAIPresentation != nil && currentEntry == nil
                    ? ui("勾选“收藏时加入 AI 内容”后可保存",
                         "Enable “Include AI Content When Saving” to save")
                    : ui("当前没有可以保存的词条", "There is no entry to save")
            }
            return
        }

        starButton.isEnabled = true
        let isSaved = isSaved(content)
        setStarFilled(isSaved)
        starButton.toolTip = isSaved
            ? ui("已保存到 Obsidian 笔记", "Saved to Obsidian Note")
            : ui("保存到 Obsidian 笔记", "Save to Obsidian Note")
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

    private static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
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
