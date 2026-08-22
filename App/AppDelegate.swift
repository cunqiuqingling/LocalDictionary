import AppKit

@MainActor
final class LocalDictionaryApplication: NSApplication {
    override func terminate(_ sender: Any?) {
        if let appDelegate = delegate as? AppDelegate,
           appDelegate.interceptSystemTerminationIfNeeded(sender: sender) {
            return
        }
        super.terminate(sender)
    }
}

#if REVERSE_INDEX_CONTROLLER_TESTING
private final class ReverseControllerTestDefaults: AIConfigurationPersisting,
    @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
}

private final class ReverseControllerTestKeychain: AIKeychainStoring,
    @unchecked Sendable {
    private let accounts: Set<String>

    init(accounts: [String] = []) { self.accounts = Set(accounts) }

    func readKey(account: String) async throws -> String? {
        accounts.contains(account) ? "fixture-key" : nil
    }
    func storeKey(_ key: String, account: String) async throws {}
    func deleteKey(account: String) async throws {}
    func listAccounts() async throws -> [String] { Array(accounts) }
}

private actor ReverseControllerTestAIClient: AIProviderClient {
    private var explanationCalls = 0
    private var translationCalls = 0

    func explain(query: String, domain: String,
                 configuration: AIProviderConfiguration,
                 apiKey: String) async throws -> AIExplanation {
        explanationCalls += 1
        return AIExplanation(
            headword: query, partsOfSpeech: [], rawFallbackText: "合成 AI 解释",
            responseParseMode: .plainTextFallback
        )
    }

    func analyzeSentence(_ sentence: String,
                         configuration: AIProviderConfiguration,
                         apiKey: String) async throws -> AISentenceAnalysis {
        AISentenceAnalysis(
            sourceText: sentence,
            translationZH: "合成中文解释。",
            learningNoteZH: "围绕 English StudyText 分析。"
        )
    }

    func translateText(_ text: String,
                       configuration: AIProviderConfiguration,
                       apiKey: String) async throws -> AITextTranslation {
        translationCalls += 1
        let translation: String
        if QueryIntentClassifier.classify(text).language == .english {
            translation = "较粗略的中文翻译。"
        } else if text.contains("第二组") {
            translation = "After writing, verify that the second run finishes quickly; " +
                "Do not let verification hang for five minutes; " +
                "English queries remain available while indexing; " +
                "Cancellation and quitting work normally."
        } else {
            translation = "After writing, verify that it finishes quickly; " +
                "Do not let verification hang for five minutes; " +
                "English queries remain available while indexing; " +
                "Cancellation and quitting work normally."
        }
        return AITextTranslation(sourceText: text, translation: translation)
    }

    func testConnection(configuration: AIProviderConfiguration,
                        apiKey: String) async throws {}

    func translationCallCount() -> Int { translationCalls }
    func explanationCallCount() -> Int { explanationCalls }
}

private actor ReverseControllerTestTranslationEngine: OfflineTranslationEngine {
    enum Behavior: Equatable, Sendable { case installed, neverReturns }
    let behavior: Behavior
    private var observedPairs: [OfflineTranslationPair] = []

    init(_ behavior: Behavior) { self.behavior = behavior }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        if behavior == .neverReturns {
            try await Task.sleep(for: .seconds(3_600))
            throw OfflineTranslationError.systemFailure
        }
        observedPairs.append(contentsOf: requests.map(\.pair))
        return requests.map { request in
            let translation: String
            if request.sourceText == "苹果", request.pair.target == .english {
                translation = "apple"
            } else if request.pair.target == .english {
                translation = "This is a valid English translation for production routing."
            } else {
                translation = "这是用于生产路由验证的有效中文译文。"
            }
            return OfflineTranslationResponse(
                id: request.id,
                sourceText: request.sourceText,
                translatedText: translation,
                pair: request.pair,
                source: .appleSystem,
                outputRole: request.outputRole
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}

    func requestedPairs() -> [OfflineTranslationPair] { observedPairs }
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationSource: String {
        case commandQ
        case menu
        case system
    }

    private var statusItem: NSStatusItem?
    private var panelController: DictionaryPanelController?
    private var dictionaryManagerController: DictionaryManagerWindowController?
    private var dictionaryCatalog = DictionaryCatalog.empty()
    private let dictionaryCatalogStore = DictionaryCatalogStore()
    private let managedDictionaryLifecycleCoordinator =
        ManagedDictionaryLifecycleCoordinator()
    private lazy var openResourceInstallationCoordinator = OpenResourceInstallationCoordinator(
        lifecycleCoordinator: managedDictionaryLifecycleCoordinator
    )
    private lazy var ownedDictionaryLifecycleReconciler =
        OwnedDictionaryLifecycleReconciler(
            catalogStore: dictionaryCatalogStore,
            verifyPublishedIndex: livePublishedIndexVerifier
        )
    private let backgroundWorkCoordinator = LocalHeavyWorkCoordinator()
    private var managedDictionaryQueryService: ManagedDictionaryQueryService?
    private var dictionaryRemovalCoordinator: ManagedDictionaryRemovalCoordinator?
    private lazy var dictionaryIndexCoordinator = ManagedDictionaryIndexCoordinator(
        catalogStore: dictionaryCatalogStore,
        buildIndex: liveDictionaryIndexBuilder,
        expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion),
        lifecycleCoordinator: managedDictionaryLifecycleCoordinator
    )
    private lazy var resourceCenterController = ResourceCenterController(
        catalog: dictionaryCatalog,
        catalogStore: dictionaryCatalogStore,
        installationCoordinator: openResourceInstallationCoordinator,
        indexCoordinator: dictionaryIndexCoordinator,
        backgroundWorkCoordinator: backgroundWorkCoordinator,
        nativeLanguageCode: LanguagePreferencesStore.shared.load().nativeLanguage.rawValue,
        learningLanguageCode: LanguagePreferencesStore.shared.load().learningLanguage.rawValue,
        onCatalogChanged: { [weak self] catalog in
            self?.applyCatalogChange(catalog)
        }
    )
    private var hotKey: GlobalHotKey?
    private var globalSelectionGeneration: UInt64 = 0
    private var selectionValidationTimer: Timer?
    private var terminationStarted = false
    private var pendingTerminationSource: TerminationSource?
    private var pendingTerminationActivity: (
        resourceCenterOpen: Bool,
        activeDownloadCount: Int,
        activeConversionCount: Int,
        reverseIndexActive: Bool,
        translationWaitActive: Bool
    )?
    private var resourceCenterSheetEndedBeforeTermination = false
    private let selectionReader = AccessibilitySelectionReader()
    private let clipboardFallback = ClipboardSelectionFallback()
    private let permissionPrompter = AccessibilityPermissionPrompter()
    private let noteStore = ObsidianNoteStore()
    private let notePicker = ObsidianNotePicker()
    private let aiConfigurationStore = AIConfigurationStore()
    private let aiKeychainStore = AIKeychainStore()
    private let aiCache = AIExplanationCache()
    private let reverseLookupService = ReverseLookupService()
    private var reverseCatalogGeneration: UInt64 = 0
    private var reverseCapabilityProbeTasks: [String: Task<Void, Never>] = [:]
    private lazy var reverseIndexCoordinator = ReverseIndexCoordinator(
        heavyWorkCoordinator: backgroundWorkCoordinator
    )
    private var legacyReverseDictionarySources: [ReverseDictionarySource] = []
    private lazy var aiProfileManager = AIProviderProfileManager(
        store: aiConfigurationStore,
        keychain: aiKeychainStore
    )
    private lazy var aiService = AIExplanationService(
        configurationStore: aiConfigurationStore,
        keychain: aiKeychainStore,
        cache: aiCache,
        profileManager: aiProfileManager
    )
    private lazy var aiSettingsController = AISettingsWindowController(
        profileManager: aiProfileManager,
        service: aiService,
        onConfigurationChanged: { [weak self] in
            self?.panelController?.aiConfigurationDidChange()
        }
    )
    private lazy var languageSettingsController = LanguageSettingsWindowController()
    private lazy var helpAndAboutController = HelpAndAboutWindowController(
        uiEnglish: AppLocalization.language == .english
    )

    #if TERMINATION_INTEGRATION_TESTING
    private var terminationTestParentWindow: NSWindow?
    private var terminationTestSheet: ResourceCenterSheetWindow?
    private var terminationTestTask: Task<Void, Never>?
    private var terminationTestReport: [String: Any] = [:]
    private var terminationTestResultURL: URL?
    private var terminationTestReverseIndexActive = false
    private var terminationTestTranslationWaitActive = false
    private var terminationTestResourceController: ResourceCenterController?
    private var terminationTestMode = ""
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLocalization.configureAtLaunch()
        ManualEvidenceRecorder.shared.record("appLaunched", strings: [
            "resultKind": "success"
        ])
        NSApp.setActivationPolicy(.accessory)
        #if TERMINATION_INTEGRATION_TESTING
        if ProcessInfo.processInfo.environment["LOCALDICTIONARY_TERMINATION_TEST_MODE"] != nil ||
            ProcessInfo.processInfo.arguments.contains("--termination-test-mode") {
            configureMainMenu()
            DispatchQueue.main.async { [weak self] in
                self?.runTerminationProcessIntegration()
            }
            return
        }
        #endif
        #if REVERSE_INDEX_CONTROLLER_TESTING
        if ProcessInfo.processInfo.environment["LOCALDICTIONARY_REVERSE_TEST_MODE"] != nil {
            Task { @MainActor [weak self] in
                await self?.runReverseControllerProcessIntegration()
            }
            return
        }
        #endif
        configureMainMenu()
        configureStatusItem()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await configureDictionary()
            hotKey = GlobalHotKey { [weak self] in self?.handleGlobalHotKey() }
            if hotKey?.isRegistered != true {
                DispatchQueue.main.async { [weak self] in
                    self?.showHotKeyRegistrationFailure()
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply {
        let source = pendingTerminationSource ?? .system
        pendingTerminationSource = nil
        let activity = pendingTerminationActivity ?? terminationActivitySnapshot()
        pendingTerminationActivity = nil
        terminationLog(
            "terminationRequested=true terminationSource=\(source.rawValue) " +
            "resourceCenterOpen=\(activity.resourceCenterOpen) " +
            "activeDownloadCount=\(activity.activeDownloadCount) " +
            "activeConversionCount=\(activity.activeConversionCount) " +
            "reverseIndexActive=\(activity.reverseIndexActive) " +
            "translationWaitActive=\(activity.translationWaitActive)"
        )
        ManualEvidenceRecorder.shared.record("appQuitRequested", strings: [
            "typedReason": source.rawValue,
            "operationState": "terminating"
        ], integers: [
            "activeDownloadCount": Int64(activity.activeDownloadCount),
            "activeConversionCount": Int64(activity.activeConversionCount)
        ], booleans: [
            "resourceCenterOpen": activity.resourceCenterOpen,
            "reverseIndexActive": activity.reverseIndexActive,
            "translationWaitActive": activity.translationWaitActive
        ])
        ManualEvidenceRecorder.shared.flush()
        #if TERMINATION_INTEGRATION_TESTING
        terminationTestReport["terminationRequested"] = true
        terminationTestReport["terminationSource"] = source.rawValue
        terminationTestReport["resourceCenterOpen"] = activity.resourceCenterOpen
        terminationTestReport["activeDownloadCount"] = activity.activeDownloadCount
        terminationTestReport["activeConversionCount"] = activity.activeConversionCount
        terminationTestReport["reverseIndexActive"] = activity.reverseIndexActive
        terminationTestReport["translationWaitActive"] = activity.translationWaitActive
        #endif
        beginTermination()
        terminationLog("terminationDecision=terminateNow")
        #if TERMINATION_INTEGRATION_TESTING
        terminationTestReport["terminationDecision"] = "terminateNow"
        writeTerminationTestReport()
        #endif
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        beginTermination()
        terminationLog("terminationCompleted=true")
        ManualEvidenceRecorder.shared.record("appTerminationCompleted", strings: [
            "operationState": "terminated"
        ])
        ManualEvidenceRecorder.shared.flush()
        #if TERMINATION_INTEGRATION_TESTING
        terminationTestReport["terminationCompleted"] = true
        writeTerminationTestReport()
        #endif
    }

    private func beginTermination() {
        guard !terminationStarted else { return }
        terminationStarted = true
        selectionValidationTimer?.invalidate()
        selectionValidationTimer = nil
        panelController?.prepareForTermination()
        var sheetEnded = resourceCenterSheetEndedBeforeTermination
        resourceCenterSheetEndedBeforeTermination = false
        sheetEnded = dictionaryManagerController?.prepareForTermination() == true || sheetEnded
        #if TERMINATION_INTEGRATION_TESTING
        if let sheet = terminationTestSheet {
            if let parent = sheet.sheetParent {
                parent.endSheet(sheet)
            } else {
                sheet.orderOut(nil)
            }
            terminationTestSheet = nil
            sheetEnded = true
        }
        terminationTestTask?.cancel()
        terminationTestTask = nil
        #endif
        #if TERMINATION_INTEGRATION_TESTING
        if let terminationTestResourceController {
            terminationTestResourceController.prepareForTermination()
        } else {
            resourceCenterController.prepareForTermination()
        }
        #else
        resourceCenterController.prepareForTermination()
        #endif
        reverseIndexCoordinator.cancel()
        reverseCapabilityProbeTasks.values.forEach { $0.cancel() }
        reverseCapabilityProbeTasks.removeAll()
        dictionaryIndexCoordinator.cancelCurrentTask()
        Task { [backgroundWorkCoordinator, managedDictionaryLifecycleCoordinator] in
            await backgroundWorkCoordinator.cancelAllWaiting()
            await managedDictionaryLifecycleCoordinator.shutdown()
        }
        terminationLog(
            "terminationCancellationIssued=true sheetEnded=\(sheetEnded)"
        )
        #if TERMINATION_INTEGRATION_TESTING
        terminationTestReport["terminationCancellationIssued"] = true
        terminationTestReport["sheetEnded"] = sheetEnded
        terminationTestReport["resourceReadyState"] = false
        #endif
    }

    private func terminationActivitySnapshot() -> (
        resourceCenterOpen: Bool,
        activeDownloadCount: Int,
        activeConversionCount: Int,
        reverseIndexActive: Bool,
        translationWaitActive: Bool
    ) {
        #if TERMINATION_INTEGRATION_TESTING
        let resourceActivity = (terminationTestResourceController ?? resourceCenterController)
            .terminationActivity
        #else
        let resourceActivity = resourceCenterController.terminationActivity
        #endif
        let panelActivity = panelController?.terminationActivity
        #if TERMINATION_INTEGRATION_TESTING
        let testSheetOpen = terminationTestSheet != nil
        let testReverseActive = terminationTestReverseIndexActive
        let testTranslationActive = terminationTestTranslationWaitActive
        #else
        let testSheetOpen = false
        let testReverseActive = false
        let testTranslationActive = false
        #endif
        return (
            dictionaryManagerController?.isResourceCenterPresented == true || testSheetOpen,
            resourceActivity.activeDownloadCount,
            resourceActivity.activeConversionCount,
            panelActivity?.reverseIndexActive == true ||
                dictionaryManagerController?.reverseIndexActiveForTermination == true ||
                reverseIndexCoordinator.currentTask != nil || testReverseActive,
            panelActivity?.translationWaitActive == true || testTranslationActive
        )
    }

    private func terminationLog(_ message: String) {
        NSLog("LocalDictionary termination %@", message)
    }

    @objc private func requestApplicationTermination(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isCommandQ = event?.type == .keyDown &&
            event?.modifierFlags.contains(.command) == true &&
            event?.charactersIgnoringModifiers?.lowercased() == "q"
        let source: TerminationSource = isCommandQ ||
            ResourceCenterTerminationKeyEquivalentState.isForwardingCommandQ
            ? .commandQ : .menu
        requestApplicationTermination(source: source, sender: sender)
    }

    private func requestApplicationTermination(source: TerminationSource, sender: Any?) {
        pendingTerminationSource = source
        pendingTerminationActivity = terminationActivitySnapshot()
        var endedSheet = dictionaryManagerController?
            .endResourceCenterBeforeApplicationTermination() ?? false
        #if TERMINATION_INTEGRATION_TESTING
        if let sheet = terminationTestSheet {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) }
            sheet.orderOut(nil)
            terminationTestSheet = nil
            endedSheet = true
        }
        #endif
        resourceCenterSheetEndedBeforeTermination = endedSheet
        if endedSheet {
            DispatchQueue.main.async {
                NSApp.terminate(sender)
            }
        } else {
            NSApp.terminate(sender)
        }
    }

    func interceptSystemTerminationIfNeeded(sender: Any?) -> Bool {
        guard pendingTerminationSource == nil, !terminationStarted else { return false }
        requestApplicationTermination(source: .system, sender: sender)
        return true
    }

    #if TERMINATION_INTEGRATION_TESTING
    private func runTerminationProcessIntegration() {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = terminationTestArgument(after: "--termination-test-mode") ??
                environment["LOCALDICTIONARY_TERMINATION_TEST_MODE"],
              let resultPath = terminationTestArgument(after: "--termination-test-result") ??
                environment["LOCALDICTIONARY_TERMINATION_TEST_RESULT"],
              let rootPath = terminationTestArgument(after: "--termination-test-root") ??
                environment["LOCALDICTIONARY_TERMINATION_TEST_ROOT"] else {
            NSApp.terminate(nil)
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let resultURL = URL(fileURLWithPath: resultPath).standardizedFileURL
        guard resultURL.path.hasPrefix(root.path + "/") else {
            NSApp.terminate(nil)
            return
        }
        terminationTestResultURL = resultURL
        terminationTestMode = mode
        let testController = makeTerminationTestResourceController(root: root)
        terminationTestResourceController = testController
        terminationTestReport = [
            "mode": mode,
            "process": ProcessInfo.processInfo.processIdentifier,
            "mainMenuConfigured": NSApp.mainMenu != nil,
            "applicationSubclassActive": NSApp is LocalDictionaryApplication,
            "commandQKeyEquivalent": NSApp.mainMenu?.items.first?.submenu?.items
                .contains(where: {
                    $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask.contains(.command)
                }) == true,
            "terminationRequested": false,
            "terminationCompleted": false
        ]

        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let content = ResourceCenterViewController(
            controller: testController,
            onClose: {}
        )
        let sheet = ResourceCenterSheetWindow(contentViewController: content)
        sheet.styleMask = [.titled, .closable, .resizable]
        sheet.setContentSize(NSSize(width: 900, height: 620))
        NSApp.activate(ignoringOtherApps: true)
        parent.makeKeyAndOrderFront(nil)
        parent.beginSheet(sheet)
        terminationTestParentWindow = parent
        terminationTestSheet = sheet
        terminationTestReport["sheetPresented"] = sheet.sheetParent === parent

        switch mode {
        case "download-command-q":
            testController.installSyntheticTerminationOperation("download")
        case "conversion-command-q":
            testController.installSyntheticTerminationOperation("conversion")
        case "heavy-wait-command-q":
            testController.installSyntheticTerminationOperation("heavy-wait")
        case "reverse-index-command-q":
            terminationTestReverseIndexActive = true
            terminationTestTask = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        case "translation-wait-command-q":
            terminationTestTranslationWaitActive = true
            terminationTestTask = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        default:
            break
        }
        writeTerminationTestReport()
        perform(#selector(triggerTerminationProcessIntegration),
                with: nil, afterDelay: 1.0)
    }

    @objc private func triggerTerminationProcessIntegration() {
        terminationTestReport["triggerStarted"] = true
        writeTerminationTestReport()
        if terminationTestMode == "menu-quit" {
            guard let applicationMenu = NSApp.mainMenu?.items.first?.submenu,
                  let index = applicationMenu.items.firstIndex(where: {
                      $0.action == #selector(requestApplicationTermination(_:))
                  }) else {
                terminationTestReport["triggerFailure"] = "quitMenuMissing"
                writeTerminationTestReport()
                NSApp.terminate(nil)
                return
            }
            let quit = applicationMenu.items[index]
            guard let action = quit.action,
                  NSApp.sendAction(action, to: quit.target, from: quit) else {
                terminationTestReport["triggerFailure"] = "quitMenuActionRejected"
                writeTerminationTestReport()
                NSApp.terminate(nil)
                return
            }
        } else if terminationTestMode == "system-terminate" {
            NSApp.terminate(nil)
        } else {
            guard let sheet = terminationTestSheet,
                  let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: sheet.windowNumber,
                    context: nil,
                    characters: "q",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                  ) else {
                terminationTestReport["triggerFailure"] = "commandQEventCreation"
                writeTerminationTestReport()
                NSApp.terminate(nil)
                return
            }
            let handled = sheet.performKeyEquivalent(with: event)
            terminationTestReport["commandQHandledBySheet"] = handled
            if !handled {
                terminationTestReport["triggerFailure"] = "commandQNotHandled"
                writeTerminationTestReport()
                NSApp.terminate(nil)
            }
        }
    }

    private func writeTerminationTestReport() {
        guard let terminationTestResultURL,
              JSONSerialization.isValidJSONObject(terminationTestReport),
              let data = try? JSONSerialization.data(
                withJSONObject: terminationTestReport, options: [.prettyPrinted, .sortedKeys]
              ) else { return }
        try? data.write(to: terminationTestResultURL, options: .atomic)
    }

    private func terminationTestArgument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func makeTerminationTestResourceController(root: URL)
        -> ResourceCenterController {
        let catalog = DictionaryCatalog.empty()
        let catalogStore = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("Catalog", isDirectory: true)
        )
        let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog)
        let indexCoordinator = ManagedDictionaryIndexCoordinator(
            catalog: catalog,
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            openSource: { _, _, size, digest, _ in
                DictionaryIndexSourceCapability(
                    sourceFileSize: size,
                    sourceSHA256: digest,
                    validation: { true }
                )
            },
            buildIndex: { _, _, _ in .failure("unused synthetic termination build") },
            createCandidate: { _ in throw DictionaryIndexError.candidateCreationFailed },
            expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion),
            lifecycleCoordinator: lifecycle
        )
        return ResourceCenterController(
            catalog: catalog,
            catalogStore: catalogStore,
            installationCoordinator: OpenResourceInstallationCoordinator(
                lifecycleCoordinator: lifecycle
            ),
            indexCoordinator: indexCoordinator,
            backgroundWorkCoordinator: backgroundWorkCoordinator,
            applicationSupportRoot: root,
            manifestStateStore: VerifiedManifestStateStore(
                directoryURL: root.appendingPathComponent("ManifestState", isDirectory: true)
            )
        )
    }
    #endif

    #if REVERSE_INDEX_CONTROLLER_TESTING
    private func runReverseControllerProcessIntegration() async {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["LOCALDICTIONARY_REVERSE_TEST_MODE"],
              let rootPath = environment["LOCALDICTIONARY_REVERSE_TEST_ROOT"],
              let sourcePath = environment["LOCALDICTIONARY_REVERSE_TEST_SOURCE"],
              let indexPath = environment["LOCALDICTIONARY_REVERSE_TEST_INDEX"],
              let resultPath = environment["LOCALDICTIONARY_REVERSE_TEST_RESULT"] else {
            NSApp.terminate(nil)
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let forwardIndex = URL(fileURLWithPath: indexPath).standardizedFileURL
        let resultURL = URL(fileURLWithPath: resultPath).standardizedFileURL
        var report: [String: Any] = [
            "mode": mode,
            "process": ProcessInfo.processInfo.processIdentifier,
            "controllerAction": false,
            "ready": false,
            "lookupApple": false,
            "cleanTerminationRequested": false
        ]
        func finishIntegration() {
            if let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: resultURL, options: .atomic)
            }
            NSApp.terminate(nil)
        }
        do {
            guard source.path.hasPrefix(root.path + "/"),
                  forwardIndex.path.hasPrefix(root.path + "/"),
                  resultURL.path.hasPrefix(root.path + "/") else {
                throw ReverseIndexError.invalidIdentity
            }
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            if mode == "managed-probe-boundaries" {
                guard let noGlossSourcePath =
                        environment["LOCALDICTIONARY_REVERSE_TEST_NO_GLOSS_SOURCE"],
                      let noGlossIndexPath =
                        environment["LOCALDICTIONARY_REVERSE_TEST_NO_GLOSS_INDEX"] else {
                    throw ReverseIndexError.invalidIdentity
                }
                let noGlossSource = URL(
                    fileURLWithPath: noGlossSourcePath
                ).standardizedFileURL
                let noGlossIndex = URL(
                    fileURLWithPath: noGlossIndexPath
                ).standardizedFileURL
                guard noGlossSource.path.hasPrefix(root.path + "/"),
                      noGlossIndex.path.hasPrefix(root.path + "/") else {
                    throw ReverseIndexError.invalidIdentity
                }
                for pair in [(source, forwardIndex), (noGlossSource, noGlossIndex)] {
                    let build = LocalDictionaryBuildIndex(
                        pair.0.path, pair.1.path, { false }
                    )
                    guard (build["success"] as? Bool) == true else {
                        throw ReverseIndexError.unavailable
                    }
                }
                let boundaryReport = try await
                    runManagedReverseCapabilityProbeBoundaryIntegration(
                        root: root,
                        lateChineseSource: source,
                        lateChineseIndex: forwardIndex,
                        noGlossSource: noGlossSource,
                        noGlossIndex: noGlossIndex
                    )
                report.merge(boundaryReport) { _, new in new }
                report["cleanTerminationRequested"] = true
                finishIntegration()
                return
            }
            if mode == "first-launch" {
                let build = LocalDictionaryBuildIndex(source.path, forwardIndex.path, { false })
                guard (build["success"] as? Bool) == true else {
                    throw ReverseIndexError.unavailable
                }
            }
            guard FileManager.default.fileExists(atPath: source.path),
                  FileManager.default.fileExists(atPath: forwardIndex.path) else {
                throw ReverseIndexError.unavailable
            }
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let indexAttributes = try FileManager.default.attributesOfItem(atPath: forwardIndex.path)
            let now = Date()
            let dictionaryID = "legacy-controller-fixture"
            func fixtureDescriptor(
                id: String,
                name: String,
                sortPosition: Int64,
                formatterIdentifier: String =
                    DictionaryFormatterIdentifier.legacyGenericMDictV1
            ) -> DictionaryDescriptor {
                DictionaryDescriptor(
                    dictionaryID: id,
                    displayName: name,
                    sourceKind: .legacyReference,
                    queryLevel: .preferred,
                    sortPosition: sortPosition,
                    enabled: true,
                    state: .ready,
                    indexMetadata: DictionaryIndexMetadata(
                        schemaVersion: Int(liveDictionaryIndexSchemaVersion),
                        entryCount: 5,
                        indexFileSize: (indexAttributes[.size] as? NSNumber)?.uint64Value,
                        sourceFileSize: (sourceAttributes[.size] as? NSNumber)?.uint64Value,
                        sourceModifiedAt: sourceAttributes[.modificationDate] as? Date,
                        sourceSHA256: nil,
                        indexedAt: now
                    ),
                    formatterIdentifier: formatterIdentifier,
                    capabilities: .unknown,
                    relativePaths: .empty,
                    createdAt: now,
                    updatedAt: now,
                    storageOwnership: .externalReference
                )
            }
            var openResourceCapabilityLabels: [String: String] = [:]
            for resource in BundledOpenResourceCatalog.resources {
                let identity = try OpenResourceInstallationIdentity(
                    starter: resource,
                    dictionaryID: UUID().uuidString.lowercased(),
                    installedAt: now
                )
                let capabilityDescriptor = DictionaryDescriptor(
                    dictionaryID: identity.dictionaryID,
                    displayName: resource.title,
                    sourceKind: .openResource,
                    queryLevel: .fallback,
                    sortPosition: 100,
                    enabled: true,
                    state: .ready,
                    indexMetadata: DictionaryIndexMetadata(
                        schemaVersion: resource.outputSchemaVersion,
                        entryCount: resource.minimumConvertedEntryCount,
                        indexFileSize: 1,
                        sourceFileSize: resource.downloadBytes,
                        sourceModifiedAt: now,
                        sourceSHA256: resource.sha256,
                        indexedAt: now
                    ),
                    formatterIdentifier: resource.transformerIdentifier,
                    capabilities: resource.capabilities,
                    relativePaths: .empty,
                    createdAt: now,
                    updatedAt: now,
                    storageOwnership: .appManagedOpenResource,
                    openResourceMetadata: identity.catalogMetadata
                )
                openResourceCapabilityLabels[resource.resourceID] =
                    ReverseDictionarySource(managed: capabilityDescriptor)
                        .reverseCapability.displayName
            }
            report["openResourceCapabilityLabels"] = openResourceCapabilityLabels
            report["capabilityFreeDict"] = openResourceCapabilityLabels[
                BundledOpenResourceCatalog.freeDictEnglishChinese.resourceID
            ] ?? ""
            report["capabilityCEDICT"] = openResourceCapabilityLabels[
                BundledOpenResourceCatalog.ccCedictChineseEnglish.resourceID
            ] ?? ""
            report["capabilityWordNet"] = openResourceCapabilityLabels[
                BundledOpenResourceCatalog.wordNetEnglish.resourceID
            ] ?? ""
            report["capabilityGCIDE"] = openResourceCapabilityLabels[
                BundledOpenResourceCatalog.gcideEnglish.resourceID
            ] ?? ""
            report["capabilityKaikki"] = openResourceCapabilityLabels[
                BundledOpenResourceCatalog.kaikkiChineseWiktionaryEnglish.resourceID
            ] ?? ""
            report["hiddenStarterCCCEDICT"] =
                BundledOpenResourceCatalog.hiddenStarterResourceIDs.contains(
                    BundledOpenResourceCatalog.ccCedictChineseEnglish.resourceID
                )
            report["hiddenStarterKaikki"] =
                BundledOpenResourceCatalog.hiddenStarterResourceIDs.contains(
                    BundledOpenResourceCatalog.kaikkiChineseWiktionaryEnglish.resourceID
                )
            let descriptor = fixtureDescriptor(
                id: dictionaryID,
                name: "Legacy bilingual controller fixture",
                sortPosition: 0
            )
            var testDescriptors = [descriptor]
            if mode == "mixed-build-all" {
                testDescriptors += [
                    fixtureDescriptor(id: "mixed-valid-1", name: "Mixed valid 1",
                                      sortPosition: 1),
                    fixtureDescriptor(id: "mixed-unsupported", name: "Mixed unsupported",
                                      sortPosition: 2,
                                      formatterIdentifier: "unsupported-fixture-v1"),
                    fixtureDescriptor(id: "mixed-valid-2", name: "Mixed valid 2",
                                      sortPosition: 3),
                    fixtureDescriptor(id: "mixed-valid-3", name: "Mixed valid 3",
                                      sortPosition: 4)
                ]
            } else if mode == "preferred-formatters" {
                testDescriptors += [
                    fixtureDescriptor(
                        id: DictionarySourceID.oxfordOALD8.rawValue,
                        name: "Oxford synthetic", sortPosition: 10,
                        formatterIdentifier: DictionaryFormatterIdentifier.oxfordOALD8V1
                    ),
                    fixtureDescriptor(
                        id: DictionarySourceID.century21.rawValue,
                        name: "Century21 synthetic", sortPosition: 11,
                        formatterIdentifier: DictionaryFormatterIdentifier.century21V1
                    ),
                    fixtureDescriptor(
                        id: DictionarySourceID.newOxford.rawValue,
                        name: "New Oxford synthetic", sortPosition: 12,
                        formatterIdentifier: DictionaryFormatterIdentifier.newOxfordV1
                    ),
                    fixtureDescriptor(
                        id: DictionarySourceID.medicalEnglishChinese.rawValue,
                        name: "Medical synthetic", sortPosition: 13,
                        formatterIdentifier:
                            DictionaryFormatterIdentifier.medicalEnglishChineseV1
                    ),
                    fixtureDescriptor(
                        id: DictionarySourceID.affixRootA.rawValue,
                        name: "Affix synthetic", sortPosition: 14,
                        formatterIdentifier: DictionaryFormatterIdentifier.affixRootAV1
                    )
                ]
            } else if mode == "affix-failure-state" {
                testDescriptors += [
                    fixtureDescriptor(
                        id: DictionarySourceID.affixRootA.rawValue,
                        name: "Affix failure-state synthetic", sortPosition: 14,
                        formatterIdentifier: DictionaryFormatterIdentifier.affixRootAV1
                    )
                ]
            }
            var catalog = DictionaryCatalog.empty(now: now)
            catalog.dictionaries = testDescriptors
            let catalogStore = DictionaryCatalogStore(
                directoryURL: root.appendingPathComponent("Catalog", isDirectory: true)
            )
            let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: catalog)
            let queryService = ManagedDictionaryQueryService(
                catalog: catalog,
                runtime: LiveManagedDictionaryQueryRuntime(
                    applicationSupportRootURL: root
                ),
                lifecycleCoordinator: lifecycle
            )
            let indexCoordinator = ManagedDictionaryIndexCoordinator(
                catalog: catalog,
                catalogStore: catalogStore,
                applicationSupportRootURL: root,
                openSource: { _, _, size, digest, _ in
                    DictionaryIndexSourceCapability(
                        sourceFileSize: size,
                        sourceSHA256: digest,
                        validation: { true }
                    )
                },
                buildIndex: { _, _, _ in .failure("not used") },
                createCandidate: { _ in
                    throw DictionaryIndexError.candidateCreationFailed
                },
                expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion),
                lifecycleCoordinator: lifecycle
            )
            let removal = ManagedDictionaryRemovalCoordinator(
                catalog: catalog,
                catalogStore: catalogStore,
                applicationSupportRootURL: root,
                queryService: queryService,
                lifecycleCoordinator: lifecycle,
                isIndexing: { _ in false }
            )
            let installation = OpenResourceInstallationCoordinator(
                lifecycleCoordinator: lifecycle
            )
            let resourceCenter = ResourceCenterController(
                catalog: catalog,
                catalogStore: catalogStore,
                installationCoordinator: installation,
                indexCoordinator: indexCoordinator,
                removalCoordinator: removal,
                applicationSupportRoot: root,
                manifestStateStore: VerifiedManifestStateStore(
                    directoryURL: root.appendingPathComponent(
                        "ManifestState", isDirectory: true
                    )
                )
            )
            let reverseRoot = root.appendingPathComponent(
                "ReverseIndexes", isDirectory: true
            )
            let sourceValues = testDescriptors.map { value in
                ReverseDictionarySource(
                    dictionaryID: value.dictionaryID,
                    dictionaryName: value.displayName,
                    dictionaryURL: source,
                    indexURL: mode == "affix-failure-state" &&
                        value.dictionaryID == DictionarySourceID.affixRootA.rawValue
                        ? root.appendingPathComponent("missing-affix-forward-index.sqlite")
                        : forwardIndex,
                    queryPriority: 0,
                    sortPosition: value.sortPosition,
                    expectedEntryCount: 5,
                    formatterIdentifier: value.formatterIdentifier
                )
            }
            let reverseCoordinator = ReverseIndexCoordinator(rootURL: reverseRoot)
            let lookupService = ReverseLookupService()
            if mode == "panel-flow" {
                let restored = ReverseIndexInventory.inspect(
                    sources: sourceValues, rootURL: reverseRoot
                )
                await lookupService.replaceDescriptors(restored.compactMap(\.descriptor))
                let panelReport = try await runPanelControllerIntegration(
                    root: root, source: source, forwardIndex: forwardIndex,
                    queryService: queryService,
                    reverseCoordinator: reverseCoordinator,
                    lookupService: lookupService,
                    reverseSources: sourceValues
                )
                report.merge(panelReport) { _, new in new }
            } else {
              let manager = DictionaryManagerWindowController(
                catalog: catalog,
                catalogStore: catalogStore,
                importService: DictionaryImportService(
                    dictionariesRootURL: root.appendingPathComponent(
                        "Dictionaries", isDirectory: true
                    ),
                    catalogStore: catalogStore
                ),
                indexCoordinator: indexCoordinator,
                removalCoordinator: removal,
                resourceCenterController: resourceCenter,
                reverseIndexCoordinator: reverseCoordinator,
                reverseLookupService: lookupService,
                reverseSources: sourceValues,
                reverseInventoryRootURL: reverseRoot
            )
            dictionaryManagerController = manager
            manager.show()
            if mode == "first-launch" {
                report["controllerAction"] = manager
                    .triggerReverseIndexRowActionForTesting(dictionaryID: dictionaryID)
                await manager.waitForReverseIndexActionForTesting()
            } else if mode == "mixed-build-all" || mode == "preferred-formatters" ||
                        mode == "affix-failure-state" {
                report["controllerAction"] = await manager
                    .triggerReverseBuildAllForTesting()
                await manager.waitForReverseIndexActionForTesting()
                if mode == "affix-failure-state" {
                    let affixID = DictionarySourceID.affixRootA.rawValue
                    let affixSource = sourceValues.first {
                        $0.dictionaryID == affixID
                    }
                    report["affixExcludedFromBuild"] = reverseCoordinator
                        .latestProgress?.dictionaries.contains {
                            $0.dictionaryID == affixID
                        } != true
                    report["affixRetryDisabled"] =
                        affixSource?.reverseCapability.isBuildEligible == false
                    report["affixStableStatus"] =
                        affixSource?.reverseCapability.displayName ?? "missing"
                    report["affixTypedReason"] =
                        affixSource?.reverseCapability.diagnosticDetail ?? "missing"
                }
                if let snapshot = reverseCoordinator.latestProgress {
                    report["batchTotal"] = snapshot.totalDictionaries
                    report["batchReady"] = snapshot.dictionaries.filter {
                        $0.stage == .ready
                    }.count
                    report["batchFailed"] = snapshot.dictionaries.filter {
                        $0.stage == .failed
                    }.count
                    report["skippedReady"] = !snapshot.dictionaries.contains {
                        $0.dictionaryID == dictionaryID
                    }
                    report["excludedUnsupported"] = !snapshot.dictionaries.contains {
                        $0.dictionaryID == "mixed-unsupported"
                    }
                    report["unsupportedCapability"] = sourceValues.first {
                        $0.dictionaryID == "mixed-unsupported"
                    }?.reverseCapability.displayName ?? ""
                    if mode == "preferred-formatters" {
                        report["preferredBatchTotal"] = snapshot.totalDictionaries
                        report["preferredBatchReady"] = snapshot.dictionaries.filter {
                            $0.stage == .ready
                        }.count
                        report["preferredBatchFailed"] = snapshot.dictionaries.filter {
                            $0.stage == .failed
                        }.count
                        report["excludedNewOxford"] = !snapshot.dictionaries.contains {
                            $0.dictionaryID == DictionarySourceID.newOxford.rawValue
                        }
                        report["excludedAffix"] = !snapshot.dictionaries.contains {
                            $0.dictionaryID == DictionarySourceID.affixRootA.rawValue
                        }
                        report["affixCapability"] = sourceValues.first {
                            $0.dictionaryID == DictionarySourceID.affixRootA.rawValue
                        }?.reverseCapability.displayName ?? ""
                        report["minimumChineseEntries"] = snapshot.dictionaries.map {
                            $0.extractionStatistics.entriesWithChinese
                        }.min() ?? 0
                        report["preferredStages"] = Dictionary(uniqueKeysWithValues:
                            snapshot.dictionaries.map {
                                ($0.dictionaryID, $0.stage.rawValue)
                            }
                        )
                        report["preferredReasons"] = Dictionary(uniqueKeysWithValues:
                            snapshot.dictionaries.compactMap { value in
                                value.failureReason.map { (value.dictionaryID, $0) }
                            }
                        )
                    }
                }
            } else {
                let restored = ReverseIndexInventory.inspect(
                    sources: sourceValues, rootURL: reverseRoot
                )
                await lookupService.replaceDescriptors(restored.compactMap(\.descriptor))
            }
            let states = ReverseIndexInventory.inspect(
                sources: sourceValues, rootURL: reverseRoot
            )
            report["ready"] = states.first {
                $0.dictionaryID == dictionaryID
            }?.stage == .ready
            let results = await lookupService.lookup("苹果")
            report["lookupApple"] = results.contains { $0.headword == "apple" }
            report["reverseFileExists"] = states.first?.descriptor.map {
                FileManager.default.fileExists(atPath: $0.fileURL.path)
            } ?? false
            if mode == "preferred-formatters" {
                func contains(_ query: String, headword: String,
                              dictionaryID: String) async -> Bool {
                    guard let descriptor = states.first(where: {
                        $0.dictionaryID == dictionaryID
                    })?.descriptor else { return false }
                    let isolatedLookup = ReverseLookupService(descriptors: [descriptor])
                    return await isolatedLookup.lookup(query, maximumResults: 100).contains {
                        $0.headword == headword && $0.dictionaryID == dictionaryID
                    }
                }
                report["oxfordApple"] = await contains(
                    "苹果", headword: "apple", dictionaryID: DictionarySourceID.oxfordOALD8.rawValue
                )
                report["centuryApple"] = await contains(
                    "苹果", headword: "apple", dictionaryID: DictionarySourceID.century21.rawValue
                )
                report["centuryDownload"] = await contains(
                    "下载", headword: "download", dictionaryID: DictionarySourceID.century21.rawValue
                )
                report["centuryValidation"] = await contains(
                    "验证", headword: "validation", dictionaryID: DictionarySourceID.century21.rawValue
                )
                report["medicalLiver"] = await contains(
                    "肝脏", headword: "liver",
                    dictionaryID: DictionarySourceID.medicalEnglishChinese.rawValue
                )
                report["medicalKidney"] = await contains(
                    "肾脏", headword: "kidney",
                    dictionaryID: DictionarySourceID.medicalEnglishChinese.rawValue
                )
                let newOxfordState = states.first {
                    $0.dictionaryID == DictionarySourceID.newOxford.rawValue
                }
                report["newOxfordSidecarAbsent"] = newOxfordState?.descriptor == nil
                report["newOxfordCapability"] = sourceValues.first {
                    $0.dictionaryID == DictionarySourceID.newOxford.rawValue
                }?.reverseCapability.displayName ?? ""
            }
            }
            report["cleanTerminationRequested"] = true
        } catch {
            report["errorType"] = String(reflecting: type(of: error))
            report["error"] = (error as? LocalizedError)?.errorDescription ??
                String(describing: error)
        }
        finishIntegration()
    }

    private func runPanelControllerIntegration(
        root: URL,
        source: URL,
        forwardIndex: URL,
        queryService: ManagedDictionaryQueryService,
        reverseCoordinator: ReverseIndexCoordinator,
        lookupService: ReverseLookupService,
        reverseSources: [ReverseDictionarySource]
    ) async throws -> [String: Any] {
        let appleLifecycle = try await runAppleLifecycleStressInAppProcess()
        let core = DictionaryCoreBridge(
            legacyReadOnlyWithDictionaryPath: source.path,
            indexPath: forwardIndex.path,
            dictionaryID: "legacy-controller-fixture",
            formatterIdentifier: DictionaryFormatterIdentifier.legacyGenericMDictV1,
            cacheMaximumBytes: 1024 * 1024,
            cacheMaximumEntries: 16
        )
        guard core.isReady else { throw ReverseIndexError.unavailable }
        let managedReverseProbe = try await runManagedReverseCapabilityProbeIntegration(
            root: root, source: source, core: core
        )
        let defaults = ReverseControllerTestDefaults()
        let configurationStore = AIConfigurationStore(defaults: defaults)
        var fixtureConfiguration = AIProviderConfiguration.zhipuPreset
        fixtureConfiguration.enabled = true
        fixtureConfiguration.baseURL = "https://fixture.invalid/v1"
        fixtureConfiguration.model = "fixture-study-model"
        configurationStore.save(fixtureConfiguration)
        let keychain = ReverseControllerTestKeychain(
            accounts: [fixtureConfiguration.keychainAccount]
        )
        let fixtureAIClient = ReverseControllerTestAIClient()
        let aiService = AIExplanationService(
            configurationStore: configurationStore,
            keychain: keychain,
            cache: AIExplanationCache(
                databaseURL: root.appendingPathComponent("panel-ai-cache.sqlite")
            ),
            clientFactory: { fixtureAIClient }
        )
        let noteDefaults = UserDefaults(
            suiteName: "LocalDictionary.ReversePanel.\(UUID().uuidString)"
        ) ?? .standard
        let noteStore = ObsidianNoteStore(defaults: noteDefaults)
        let deadline = OfflineTranslationDeadlinePolicy(
            availability: .milliseconds(80),
            preparation: .milliseconds(80),
            translation: .milliseconds(80),
            fallback: .milliseconds(200)
        )

        func makePanel(
            coordinator: OfflineTranslationCoordinator
        ) -> DictionaryPanelController {
            DictionaryPanelController(
                core: core,
                noteStore: noteStore,
                notePicker: ObsidianNotePicker(),
                aiService: aiService,
                managedDictionaryQueryService: queryService,
                reverseLookupService: lookupService,
                reverseIndexCoordinator: reverseCoordinator,
                backgroundWorkCoordinator: LocalHeavyWorkCoordinator(),
                reverseDictionarySources: reverseSources,
                offlineTranslationOverride: coordinator,
                openAISettings: {}
            )
        }

        func productionOfflineRouting(
            _ query: String
        ) async -> (snapshot: [String: Any], pairs: [OfflineTranslationPair]) {
            let engine = ReverseControllerTestTranslationEngine(.installed)
            let panel = makePanel(coordinator: OfflineTranslationCoordinator(
                deadlinePolicy: deadline, factory: { engine }
            ))
            panelController = panel
            _ = panel.showAndLookup(query)
            await panel.waitForPanelTesting(milliseconds: 500)
            let snapshot = panel.panelTestingSnapshot()
            let pairs = await engine.requestedPairs()
            panel.prepareForTermination()
            return (snapshot, pairs)
        }

        let pureNativeRouting = await productionOfflineRouting("你听说过她的名字吗？")
        let pureLearningRouting = await productionOfflineRouting(
            "Have you heard her name before?"
        )
        let pollutedLearningRouting = await productionOfflineRouting(
            "multiple__organisms__indirectly_"
        )
        let mixedRouting = await productionOfflineRouting(
            "所以如果 Evidence Candidate 的 Resource Center 里还看到 FreeDict " +
                "正常作为可安装资源，那才是 bug"
        )

        // Exercise the real search-field target/action three times. This remains an explicit
        // user gesture and uses only the synthetic test provider/keychain.
        let tripleReturnPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            factory: { ReverseControllerTestTranslationEngine(.installed) }
        ))
        panelController = tripleReturnPanel
        tripleReturnPanel.submitSearchReturnForTesting("joyful")
        tripleReturnPanel.submitSearchReturnForTesting("joyful")
        tripleReturnPanel.submitSearchReturnForTesting("joyful")
        await tripleReturnPanel.waitForPanelTesting(milliseconds: 700)
        let tripleReturnSnapshot = tripleReturnPanel.panelTestingSnapshot()
        let tripleReturnExplanationCalls = await fixtureAIClient.explanationCallCount()
        tripleReturnPanel.prepareForTermination()

        let installedEngine = ReverseControllerTestTranslationEngine(.installed)
        let installedPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            factory: { installedEngine }
        ))
        panelController = installedPanel
        _ = installedPanel.showAndLookup("苹果")
        await installedPanel.waitForPanelTesting()
        let installedBefore = installedPanel.panelTestingSnapshot()
        let installedAction = installedPanel.triggerOfflineActionForTesting()
        await installedPanel.waitForPanelTesting()
        let installedAfter = installedPanel.panelTestingSnapshot()
        installedPanel.injectWordAIPresentationForTesting(AIExplanationPresentation(
            explanation: AIExplanation(
                headword: "苹果",
                recommendedEnglishExpressions: ["apple"],
                partsOfSpeech: [AIExplanationPartOfSpeech(
                    partOfSpeech: "noun",
                    senses: [AIExplanationSense(
                        definitionEN: "The fruit of an apple tree.",
                        definitionZH: "苹果树的果实。"
                    )]
                )]
            ),
            providerDisplayName: "Fixture Provider",
            model: "fixture-word",
            fromCache: false
        ))
        let installedAI = installedPanel.panelTestingSnapshot()
        let chineseWordNoteURL = root.appendingPathComponent("Chinese-AI-Favorite.md")
        let chineseWordSaved = installedPanel.saveCurrentNoteForTesting(
            to: chineseWordNoteURL
        )
        let installedSaved = installedPanel.panelTestingSnapshot()
        let chineseWordMarkdown = (try? String(
            contentsOf: chineseWordNoteURL, encoding: .utf8
        )) ?? ""
        installedPanel.prepareForTermination()

        let neverEngine = ReverseControllerTestTranslationEngine(.neverReturns)
        let fallbackFactory: OfflineTranslationCoordinator.EngineFactory = {
            LocalBasicTranslationEngine(lookup: LocalBasicTranslationLookup(
                englishToChinese: { term in
                    ["team": "团队", "result": "结果", "works": "工作"][term.lowercased()]
                },
                chineseToEnglish: { term in
                    ["下载": "download", "苹果": "apple", "结果": "result"][term]
                }
            ))
        }
        let timeoutPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            fallbackFactory: fallbackFactory,
            factory: { neverEngine }
        ))
        panelController = timeoutPanel
        _ = timeoutPanel.showAndLookup("下载")
        await timeoutPanel.waitForPanelTesting()
        let timeoutBefore = timeoutPanel.panelTestingSnapshot()
        let timeoutAction = timeoutPanel.triggerOfflineActionForTesting()
        await timeoutPanel.waitForPanelTesting(milliseconds: 450)
        let timeoutAfter = timeoutPanel.panelTestingSnapshot()
        timeoutPanel.prepareForTermination()

        let longPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            fallbackFactory: fallbackFactory,
            factory: { neverEngine }
        ))
        panelController = longPanel
        let paragraph = "Although the team works carefully, the result remains useful for local testing."
        _ = longPanel.showAndLookup(paragraph)
        await longPanel.waitForPanelTesting(milliseconds: 20)
        let longBefore = longPanel.panelTestingSnapshot()
        await longPanel.waitForPanelTesting(milliseconds: 450)
        let longAfter = longPanel.panelTestingSnapshot()
        longPanel.injectLongTextAIForTesting(
            deepTranslation: "尽管团队工作认真，结果仍适合本地测试。",
            sentenceTranslation: "尽管团队工作认真，结果仍适合本地测试。",
            provider: "Fixture Provider",
            model: "fixture-long-en"
        )
        let longAI = longPanel.panelTestingSnapshot()
        let longNoteURL = root.appendingPathComponent("English-Long-Favorite.md")
        let longSaved = longPanel.saveCurrentNoteForTesting(to: longNoteURL)
        let longSavedSnapshot = longPanel.panelTestingSnapshot()
        let longMarkdown = (try? String(contentsOf: longNoteURL, encoding: .utf8)) ?? ""
        longPanel.prepareForTermination()

        let chineseLongPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            fallbackFactory: fallbackFactory,
            factory: { neverEngine }
        ))
        panelController = chineseLongPanel
        let chineseParagraph = """
        写入完成后验证是否真正秒级/短时间结束；
        不能再‘验证100%’挂五分钟；
        建立过程中普通英文查询还能用；
        取消、退出都正常
        """
        _ = chineseLongPanel.showAndLookup(chineseParagraph)
        await chineseLongPanel.waitForPanelTesting(milliseconds: 20)
        let chineseLongBefore = chineseLongPanel.panelTestingSnapshot()
        await chineseLongPanel.waitForPanelTesting(milliseconds: 450)
        let chineseLongAfter = chineseLongPanel.panelTestingSnapshot()
        chineseLongPanel.injectLongTextAIForTesting(
            deepTranslation: "After writing, verify that it finishes within seconds or a short time.",
            sentenceTranslation: "写入后，验证它是否能在数秒或很短时间内结束。",
            provider: "Fixture Provider",
            model: "fixture-long-zh"
        )
        let chineseLongAI = chineseLongPanel.panelTestingSnapshot()
        let chineseLongNoteURL = root.appendingPathComponent("Chinese-Long-Favorite.md")
        let chineseLongSaved = chineseLongPanel.saveCurrentNoteForTesting(
            to: chineseLongNoteURL
        )
        let chineseLongSavedSnapshot = chineseLongPanel.panelTestingSnapshot()
        let chineseLongMarkdown = (try? String(
            contentsOf: chineseLongNoteURL, encoding: .utf8
        )) ?? ""
        chineseLongPanel.prepareForTermination()

        // Click-order gate A: sentence analysis creates the canonical AIStudyText; the later
        // deep-translation action must display that exact artifact without a second translation.
        let analysisFirstPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            fallbackFactory: fallbackFactory,
            factory: { neverEngine }
        ))
        panelController = analysisFirstPanel
        _ = analysisFirstPanel.showAndLookup(chineseParagraph)
        await analysisFirstPanel.waitForPanelTesting(milliseconds: 450)
        let analysisFirstAction = analysisFirstPanel.triggerLongTextAIAnalysisForTesting()
        await analysisFirstPanel.waitForPanelTesting(milliseconds: 700)
        let analysisFirstBeforeTranslation = analysisFirstPanel.panelTestingSnapshot()
        let translationAfterAnalysisAction =
            analysisFirstPanel.triggerLongTextAITranslationForTesting()
        await analysisFirstPanel.waitForPanelTesting(milliseconds: 300)
        let analysisFirstAfterTranslation = analysisFirstPanel.panelTestingSnapshot()
        let callsAfterAnalysisFirst = await fixtureAIClient.translationCallCount()
        analysisFirstPanel.clearCurrentAICacheForTesting()
        await analysisFirstPanel.waitForPanelTesting(milliseconds: 300)
        let cacheCleared = analysisFirstPanel.panelTestingSnapshot()
        analysisFirstPanel.prepareForTermination()

        // Click-order gate B uses a distinct query/cache key: deep translation creates the
        // artifact first, and sentence analysis must reuse it.
        let secondChineseParagraph = chineseParagraph.replacingOccurrences(
            of: "写入完成后", with: "第二组：写入完成后"
        )
        let translationFirstPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            fallbackFactory: fallbackFactory,
            factory: { neverEngine }
        ))
        panelController = translationFirstPanel
        _ = translationFirstPanel.showAndLookup(secondChineseParagraph)
        await translationFirstPanel.waitForPanelTesting(milliseconds: 450)
        let translationFirstAction =
            translationFirstPanel.triggerLongTextAITranslationForTesting()
        await translationFirstPanel.waitForPanelTesting(milliseconds: 300)
        let translationFirstBeforeAnalysis = translationFirstPanel.panelTestingSnapshot()
        let analysisAfterTranslationAction =
            translationFirstPanel.triggerLongTextAIAnalysisForTesting()
        await translationFirstPanel.waitForPanelTesting(milliseconds: 700)
        let translationFirstAfterAnalysis = translationFirstPanel.panelTestingSnapshot()
        let callsAfterBothOrders = await fixtureAIClient.translationCallCount()
        translationFirstPanel.prepareForTermination()

        // Deep Translation sees the complete context and is the authoritative translation
        // artifact. Per-sentence analysis must never replace it with independently generated
        // fragments, even when every sentence analysis succeeds.
        let consistencyPanel = makePanel(coordinator: OfflineTranslationCoordinator(
            deadlinePolicy: deadline,
            fallbackFactory: fallbackFactory,
            factory: { neverEngine }
        ))
        panelController = consistencyPanel
        let consistencySentence =
            "Researchers observed that the bees changed their building behaviour."
        _ = consistencyPanel.showAndLookup(consistencySentence)
        await consistencyPanel.waitForPanelTesting(milliseconds: 450)
        let consistencyTranslationAction =
            consistencyPanel.triggerLongTextAITranslationForTesting()
        await consistencyPanel.waitForPanelTesting(milliseconds: 300)
        let consistencyBeforeAnalysis = consistencyPanel.panelTestingSnapshot()
        let consistencyAnalysisAction =
            consistencyPanel.triggerLongTextAIAnalysisForTesting()
        await consistencyPanel.waitForPanelTesting(milliseconds: 700)
        let consistencyAfterAnalysis = consistencyPanel.panelTestingSnapshot()
        consistencyPanel.prepareForTermination()
        panelController = nil

        var report: [String: Any] = [
            "tripleReturnExplanationCalls": tripleReturnExplanationCalls,
            "tripleReturnAIVisible": (tripleReturnSnapshot["content"] as? String)?
                .contains("合成 AI 解释") == true,
            "installedReverseVisible": (installedBefore["content"] as? String)?
                .contains("apple") == true,
            "managedReverseCapabilityProbeSupported":
                managedReverseProbe.result == .supported,
            "managedReverseCapabilityProbeResult": managedReverseProbe.result.rawValue,
            "managedReverseCapabilityProbeDiagnostic": managedReverseProbe.diagnostic,
            "installedOfflineTitle": installedBefore["offlineTitle"] as? String ?? "",
            "installedAIVisible": installedBefore["aiVisible"] as? Bool ?? false,
            "installedAction": installedAction,
            "installedTranslationVisible": (installedAfter["content"] as? String)?
                .contains("Apple 系统离线翻译\napple") == true,
            "chineseAIStarEnabled": installedAI["starEnabled"] as? Bool ?? false,
            "chineseAINoteOnlyAI": installedAI["noteHasAI"] as? Bool == true &&
                installedAI["noteHasLocal"] as? Bool == false,
            "chineseAISaved": chineseWordSaved,
            "chineseAIStarFilledAfterSave":
                (installedSaved["starValue"] as? String) == "已保存",
            "chineseAIMarkdownOnlyAI": chineseWordMarkdown.contains("### AI 双语解释") &&
                !chineseWordMarkdown.contains("本地词典释义") &&
                chineseWordMarkdown.contains("推荐英文：**apple**"),
            "timeoutReverseVisible": (timeoutBefore["content"] as? String)?
                .contains("download") == true,
            "timeoutAIVisibleBefore": timeoutBefore["aiVisible"] as? Bool ?? false,
            "timeoutAction": timeoutAction,
            "timeoutFallbackVisible": (timeoutAfter["content"] as? String)?
                .contains("Apple 系统离线翻译本次未完成") == true &&
                (timeoutAfter["content"] as? String)?
                .contains("本地词典与反向查询") == true &&
                (timeoutAfter["content"] as? String)?.contains("download") == true,
            "timeoutAIVisibleAfter": timeoutAfter["aiVisible"] as? Bool ?? false,
            "longAIVisibleDuringWait": longBefore["aiVisible"] as? Bool ?? false,
            "longAITranslationVisibleDuringWait":
                longBefore["aiTranslationVisible"] as? Bool ?? false,
            "longAITranslationTitle": longBefore["aiTranslationTitle"] as? String ?? "",
            "longAISentenceTitle": longBefore["aiTitle"] as? String ?? "",
            "longSeparateAISections": (longBefore["content"] as? String)?
                .contains("四、AI 深度翻译") == true &&
                (longBefore["content"] as? String)?
                    .contains("五、逐句 AI 深度分析") == true,
            "longBasicVisibleDuringWait": (longBefore["content"] as? String)?
                .contains("一、离线基础翻译") == true,
            "longFallbackVisible": (longAfter["content"] as? String)?
                .contains("Apple 系统离线翻译当前不可用") == true &&
                (longAfter["content"] as? String)?.contains("本地基础翻译") == false,
            "longAIVisibleAfterFallback": longAfter["aiVisible"] as? Bool ?? false,
            "longBaseStarEnabled": longAfter["starEnabled"] as? Bool ?? false,
            "longAINoteHasBoth": longAI["noteHasLocal"] as? Bool == true &&
                longAI["noteHasAI"] as? Bool == true,
            "longSaved": longSaved,
            "longStarFilledAfterSave":
                (longSavedSnapshot["starValue"] as? String) == "已保存",
            "longMarkdownComplete": longMarkdown.contains("#### AI 深度翻译") &&
                longMarkdown.contains("#### 第 1 句 AI 深度分析") &&
                longMarkdown.contains("#### 基础结构分析"),
            "englishLongStudyIsEnglish":
                (longAI["studyLanguageCodes"] as? [String])?.allSatisfy { $0 == "en" } == true,
            "englishLongAnalysisUsesStudyText":
                (longAI["aiAnalysisSourceTexts"] as? [String]) ==
                    (longAI["studyTexts"] as? [String]),
            "chineseLongAIVisibleDuringWait":
                chineseLongBefore["aiVisible"] as? Bool ?? false,
            "chineseLongAITranslationVisibleDuringWait":
                chineseLongBefore["aiTranslationVisible"] as? Bool ?? false,
            "chineseLongFallbackVisible": (chineseLongAfter["content"] as? String)?
                .contains("Apple 系统离线翻译当前不可用") == true &&
                (chineseLongAfter["content"] as? String)?.contains("本地基础翻译") == false,
            "chineseLongAIVisibleAfterFallback":
                chineseLongAfter["aiVisible"] as? Bool ?? false,
            "chineseLongNaturalEnglish": (chineseLongAI["content"] as? String)?
                .contains("After writing, verify that it finishes") == true,
            "chineseLongStudyIsEnglish":
                (chineseLongAI["studyLanguageCodes"] as? [String])?.allSatisfy {
                    $0 == "en"
                } == true,
            "chineseLongAnalysisUsesEnglishStudyText":
                (chineseLongAI["aiAnalysisSourceTexts"] as? [String]) ==
                    (chineseLongAI["studyTexts"] as? [String]) &&
                (chineseLongAI["aiAnalysisSourceTexts"] as? [String])?.allSatisfy {
                    QueryIntentClassifier.classify($0).language == .english
                } == true,
            "chineseLongDoesNotAnalyzeChineseGrammar":
                (chineseLongAI["content"] as? String)?.contains("写入是动词") == false,
            "chineseLongFavoriteLanguageMetadata":
                chineseLongMarkdown.contains(
                    "LocalDictionary-Language source=zh-Hans; native=zh-Hans; " +
                        "learning=en; study=en"
                ),
            "chineseLongSaved": chineseLongSaved,
            "chineseLongStarFilledAfterSave":
                (chineseLongSavedSnapshot["starValue"] as? String) == "已保存",
            "chineseLongMarkdownComplete":
                chineseLongMarkdown.contains("After writing, verify that it finishes") &&
                chineseLongMarkdown.contains("#### 基础结构分析"),
            "analysisFirstAction": analysisFirstAction,
            "analysisOnlyCacheButtonVisible":
                analysisFirstBeforeTranslation["aiCacheControlVisible"] as? Bool ?? false,
            "analysisOnlyCacheButtonIsReal":
                analysisFirstBeforeTranslation["aiCacheControlBordered"] as? Bool == true &&
                analysisFirstBeforeTranslation["aiCacheControlClass"] as? String == "NSButton" &&
                analysisFirstBeforeTranslation["aiCacheControlInstanceCount"] as? Int == 1,
            "translationAfterAnalysisAction": translationAfterAnalysisAction,
            "analysisFirstCanonicalStable":
                (analysisFirstBeforeTranslation["canonicalAIStudyText"] as? String)?.isEmpty == false &&
                analysisFirstBeforeTranslation["canonicalAIStudyText"] as? String ==
                    analysisFirstAfterTranslation["deepAITranslationText"] as? String,
            "analysisFirstSingleTranslationCall": callsAfterAnalysisFirst == 1,
            "cacheClearRemovedAIArtifacts":
                (cacheCleared["canonicalAIStudyText"] as? String)?.isEmpty == true &&
                (cacheCleared["deepAITranslationText"] as? String)?.isEmpty == true &&
                (cacheCleared["sentenceAIResultCount"] as? Int) == 0,
            "cacheClearRetainedLocalResult":
                cacheCleared["hasLongTextResult"] as? Bool == true &&
                (cacheCleared["content"] as? String)?.contains("二、重点词汇") == true,
            "cacheClearButtonHiddenAfterClear":
                cacheCleared["aiCacheControlVisible"] as? Bool == false,
            "translationFirstAction": translationFirstAction,
            "translationOnlyCacheButtonVisible":
                translationFirstBeforeAnalysis["aiCacheControlVisible"] as? Bool ?? false,
            "translationOnlyCacheButtonIsReal":
                translationFirstBeforeAnalysis["aiCacheControlBordered"] as? Bool == true &&
                translationFirstBeforeAnalysis["aiCacheControlClass"] as? String == "NSButton" &&
                translationFirstBeforeAnalysis["aiCacheControlInstanceCount"] as? Int == 1,
            "analysisAfterTranslationAction": analysisAfterTranslationAction,
            "translationFirstCanonicalStable":
                (translationFirstBeforeAnalysis["deepAITranslationText"] as? String)?.isEmpty == false &&
                translationFirstBeforeAnalysis["deepAITranslationText"] as? String ==
                    translationFirstAfterAnalysis["canonicalAIStudyText"] as? String,
            "bothAIUsesOneCacheButton":
                translationFirstAfterAnalysis["aiCacheControlVisible"] as? Bool == true &&
                translationFirstAfterAnalysis["aiCacheControlInstanceCount"] as? Int == 1,
            "bothClickOrdersOneTranslationEach": callsAfterBothOrders == 2,
            "learningDeepTranslationAction": consistencyTranslationAction,
            "learningSentenceAnalysisAction": consistencyAnalysisAction,
            "learningDeepTranslationWasFullContext":
                consistencyBeforeAnalysis["deepAITranslationText"] as? String ==
                    "较粗略的中文翻译。",
            "learningSentenceAnalysisPromotedCanonicalTranslation":
                consistencyAfterAnalysis["deepAITranslationText"] as? String ==
                    "合成中文解释。" &&
                consistencyAfterAnalysis["aiSentenceTranslations"] as? [String] ==
                    ["合成中文解释。"],
            "pureNativeProductionTargetEnglish":
                pureNativeRouting.pairs == [OfflineTranslationPair(
                    source: .simplifiedChinese, target: .english
                )],
            "pureNativeProductionUI":
                (pureNativeRouting.snapshot["content"] as? String)?
                    .contains("翻译方向：简体中文 → English") == true &&
                (pureNativeRouting.snapshot["content"] as? String)?
                    .contains("This is a valid English translation") == true,
            "pureLearningProductionTargetNative":
                pureLearningRouting.pairs == [OfflineTranslationPair(
                    source: .english, target: .simplifiedChinese
                )],
            "pureLearningProductionUI":
                (pureLearningRouting.snapshot["content"] as? String)?
                    .contains("翻译方向：English → 简体中文") == true &&
                (pureLearningRouting.snapshot["content"] as? String)?
                    .contains("这是用于生产路由验证的有效中文译文") == true,
            "pollutedLearningProductionTargetNative":
                pollutedLearningRouting.pairs == [OfflineTranslationPair(
                    source: .english, target: .simplifiedChinese
                )],
            "pollutedLearningProductionNormalizedQuery":
                pollutedLearningRouting.snapshot["currentQuery"] as? String ==
                    "multiple organisms indirectly",
            "pollutedLearningProductionUI":
                (pollutedLearningRouting.snapshot["content"] as? String)?
                    .contains("Apple 系统离线翻译") == true &&
                (pollutedLearningRouting.snapshot["content"] as? String)?
                    .contains("这是用于生产路由验证的有效中文译文") == true,
            "mixedProductionBidirectional": Set(mixedRouting.pairs) == Set([
                OfflineTranslationPair(source: .simplifiedChinese, target: .english),
                OfflineTranslationPair(source: .english, target: .simplifiedChinese)
            ]),
            "mixedProductionIndependentOperations": mixedRouting.pairs.count == 2,
            "mixedProductionUI":
                (mixedRouting.snapshot["content"] as? String)?
                    .contains("检测到中英混合文本，提供双语版本") == true &&
                (mixedRouting.snapshot["content"] as? String)?
                    .contains("This is a valid English translation") == true &&
                (mixedRouting.snapshot["content"] as? String)?
                    .contains("这是用于生产路由验证的有效中文译文") == true,
            "mixedOfflineStudyTextIsLearningOnly":
                (mixedRouting.snapshot["offlineStudyTextCount"] as? Int) == 1
        ]
        for (key, value) in appleLifecycle {
            report[key] = value
        }
        return report
    }

    private func runManagedReverseCapabilityProbeIntegration(
        root: URL, source: URL, core: DictionaryCoreBridge
    ) async throws -> (result: DictionaryReverseCapabilityProbe, diagnostic: String) {
        let reports = try await runManagedReverseCapabilityProbeModesIntegration(
            root: root,
            source: source,
            core: core,
            dictionaryID: "00000000-0000-0000-0000-0000000000a1",
            catalogDirectoryName: "ManagedProbeCatalog"
        )
        return (reports.sample.result, reports.sampleDiagnostic)
    }

    private func runManagedReverseCapabilityProbeModesIntegration(
        root: URL,
        source: URL,
        core: DictionaryCoreBridge,
        dictionaryID: String,
        catalogDirectoryName: String
    ) async throws -> (
        sample: ManagedReverseCapabilityProbeReport,
        full: ManagedReverseCapabilityProbeReport,
        sampleDiagnostic: String,
        fullDiagnostic: String
    ) {
        let sourceRelative = "Dictionaries/\(dictionaryID)/\(source.lastPathComponent)"
        let managedSource = root.appendingPathComponent(sourceRelative)
        try FileManager.default.createDirectory(
            at: managedSource.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: managedSource)
        let sourceSize = UInt64(try managedSource.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0)
        let now = Date()
        let descriptor = DictionaryDescriptor(
            dictionaryID: dictionaryID,
            displayName: "Managed capability probe fixture",
            sourceKind: .managedLocal,
            queryLevel: .normal,
            sortPosition: 1,
            enabled: true,
            state: .pendingIndex,
            indexMetadata: DictionaryIndexMetadata(
                schemaVersion: nil,
                entryCount: nil, indexFileSize: nil,
                sourceFileSize: sourceSize, sourceModifiedAt: now,
                sourceSHA256: core.sourceSHA256, indexedAt: nil
            ),
            formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
            capabilities: .unknown,
            relativePaths: DictionaryRelativePaths(
                dictionary: sourceRelative, resources: [], index: nil
            ),
            createdAt: now,
            updatedAt: now
        )
        let catalogStore = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent(catalogDirectoryName)
        )
        let catalog = DictionaryCatalog(
            schemaVersion: DictionaryCatalog.currentSchemaVersion,
            createdAt: now, updatedAt: now, dictionaries: [descriptor]
        )
        try catalogStore.save(catalog)
        let coordinator = ManagedDictionaryIndexCoordinator(
            catalog: catalog,
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            openSource: liveDictionarySourceOpener,
            buildIndex: liveDictionaryIndexBuilder,
            createCandidate: liveDictionaryIndexCandidateFactory,
            expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion)
        )
        guard coordinator.start(dictionaryID: dictionaryID) == .started else {
            throw ReverseIndexError.unavailable
        }
        for _ in 0..<2_000 where coordinator.activity != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard coordinator.activity == nil,
              let ready = coordinator.catalog.dictionaries.first,
              ready.state == .ready else { throw ReverseIndexError.unavailable }
        var sampleDiagnostic = ""
        let sample = ManagedReverseCapabilityProbe.inspect(
            descriptor: ready,
            mode: .sample,
            applicationSupportRootURL: root,
            diagnostic: { sampleDiagnostic = $0 }
        )
        var fullDiagnostic = ""
        let full = ManagedReverseCapabilityProbe.inspect(
            descriptor: ready,
            mode: .full,
            applicationSupportRootURL: root,
            diagnostic: { fullDiagnostic = $0 }
        )
        return (sample, full, sampleDiagnostic, fullDiagnostic)
    }

    /// Production-chain regression for the import capability flow. Both fixtures are public,
    /// generated in Tests, indexed through the managed publisher, then reopened by the same
    /// read-only validator/bridge used by Dictionary Manager. No source text is reported.
    private func runManagedReverseCapabilityProbeBoundaryIntegration(
        root: URL,
        lateChineseSource: URL,
        lateChineseIndex: URL,
        noGlossSource: URL,
        noGlossIndex: URL
    ) async throws -> [String: Any] {
        func legacyCore(
            source: URL, index: URL, dictionaryID: String
        ) throws -> DictionaryCoreBridge {
            let core = DictionaryCoreBridge(
                legacyReadOnlyWithDictionaryPath: source.path,
                indexPath: index.path,
                dictionaryID: dictionaryID,
                formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
                cacheMaximumBytes: 1024 * 1024,
                cacheMaximumEntries: 16
            )
            guard core.isReady else { throw ReverseIndexError.unavailable }
            return core
        }

        let late = try await runManagedReverseCapabilityProbeModesIntegration(
            root: root,
            source: lateChineseSource,
            core: try legacyCore(
                source: lateChineseSource,
                index: lateChineseIndex,
                dictionaryID: "managed-probe-late-source"
            ),
            dictionaryID: "00000000-0000-0000-0000-0000000000a2",
            catalogDirectoryName: "ManagedProbeLateCatalog"
        )
        let noGloss = try await runManagedReverseCapabilityProbeModesIntegration(
            root: root,
            source: noGlossSource,
            core: try legacyCore(
                source: noGlossSource,
                index: noGlossIndex,
                dictionaryID: "managed-probe-no-gloss-source"
            ),
            dictionaryID: "00000000-0000-0000-0000-0000000000a3",
            catalogDirectoryName: "ManagedProbeNoGlossCatalog"
        )

        return [
            "lateSampleResult": late.sample.result.rawValue,
            "lateSampleReason": late.sample.terminalReason.rawValue,
            "lateSampleProcessed": late.sample.processedEntryCount,
            "lateSampleBounded":
                late.sample.result == .unknown &&
                late.sample.terminalReason == .sampleLimitReached &&
                late.sample.processedEntryCount ==
                    ManagedReverseCapabilityProbe.maximumEntries,
            "lateFullResult": late.full.result.rawValue,
            "lateFullReason": late.full.terminalReason.rawValue,
            "lateFullProcessed": late.full.processedEntryCount,
            "lateFullFoundEntry513":
                late.full.result == .supported &&
                late.full.terminalReason == .usableNativeGlossFound &&
                late.full.processedEntryCount == 513,
            "noGlossSampleResult": noGloss.sample.result.rawValue,
            "noGlossSampleReason": noGloss.sample.terminalReason.rawValue,
            "noGlossSampleProcessed": noGloss.sample.processedEntryCount,
            "noGlossSampleBounded":
                noGloss.sample.result == .unknown &&
                noGloss.sample.terminalReason == .sampleLimitReached &&
                noGloss.sample.processedEntryCount ==
                    ManagedReverseCapabilityProbe.maximumEntries,
            "noGlossFullResult": noGloss.full.result.rawValue,
            "noGlossFullReason": noGloss.full.terminalReason.rawValue,
            "noGlossFullProcessed": noGloss.full.processedEntryCount,
            "noGlossFullReachedEOF":
                noGloss.full.result == .noUsableNativeGloss &&
                noGloss.full.terminalReason == .endOfFileNoUsableNativeGloss &&
                noGloss.full.processedEntryCount == 513,
            "lateSampleDiagnostic": late.sampleDiagnostic,
            "lateFullDiagnostic": late.fullDiagnostic,
            "noGlossSampleDiagnostic": noGloss.sampleDiagnostic,
            "noGlossFullDiagnostic": noGloss.fullDiagnostic
        ]
    }

    /// Runs inside the launched application process and exercises one host through failure,
    /// cancellation, stop-waiting, late callbacks, and immediate recovery. The session callbacks
    /// are deterministic so this gate never downloads an Apple language pack.
    private func runAppleLifecycleStressInAppProcess() async throws -> [String: Any] {
        let pair = OfflineTranslationPair(
            source: .simplifiedChinese, target: .english
        )
        let model = SystemTranslationHostModel()
        model.hostDidAttach()
        var successes = 0
        var injectedFailures = 0
        var recoverySuccesses = 0
        var awaitingRecovery = false
        var staleCallbacksRejected = true

        for index in 0..<50 {
            let operation = Task {
                try await model.enqueueTranslation([
                    OfflineTranslationRequest(
                        id: "app-process-stress-\(index)",
                        sourceText: "同进程合成文本-\(index)", pair: pair
                    )
                ])
            }
            for _ in 0..<200 where !model.hasPendingOperations {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            guard model.hasPendingOperations else {
                throw NSError(
                    domain: "LocalDictionary.AppleLifecycleStress", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "operation did not activate"]
                )
            }
            let generation = model.configurationGeneration
            let injectCancellation = index == 4 || index == 34
            let injectSystemFailure = index == 14 || index == 44
            let injectStopWaiting = index == 24

            if injectStopWaiting {
                model.stopWaitingForSystemPreparation()
            } else {
                await model.runActiveOperation(
                    sessionGeneration: generation,
                    prepare: {},
                    translate: { _ in
                        if injectCancellation { throw CancellationError() }
                        if injectSystemFailure {
                            throw OfflineTranslationError.systemFailure
                        }
                        return "app-process-ok-\(index)"
                    }
                )
            }

            if injectCancellation || injectSystemFailure || injectStopWaiting {
                do {
                    _ = try await operation.value
                    throw NSError(
                        domain: "LocalDictionary.AppleLifecycleStress", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "injected failure completed"]
                    )
                } catch let error as OfflineTranslationError {
                    guard error == .cancelled || error == .systemFailure else { throw error }
                    injectedFailures += 1
                    awaitingRecovery = true
                    model.recoverAfterOperationFailure(error)
                }
                var staleCallbackRan = false
                await model.runActiveOperation(
                    sessionGeneration: generation,
                    prepare: { staleCallbackRan = true },
                    translate: { _ in staleCallbackRan = true; return "stale" }
                )
                staleCallbacksRejected = staleCallbacksRejected && !staleCallbackRan
            } else {
                let response = try await operation.value
                guard response.first?.translatedText == "app-process-ok-\(index)" else {
                    throw OfflineTranslationError.invalidResponse
                }
                successes += 1
                if awaitingRecovery {
                    recoverySuccesses += 1
                    awaitingRecovery = false
                }
            }
        }

        let pendingZero = model.pendingOperationCount == 0
        let healthy = model.health == .healthy && model.visibleStatus == .installed
        model.hostDidDetach()
        return [
            "appleLifecycleSameAppOperations": 50,
            "appleLifecycleSuccesses": successes,
            "appleLifecycleInjectedFailures": injectedFailures,
            "appleLifecycleRecoverySuccesses": recoverySuccesses,
            "appleLifecycleStaleCallbacksRejected": staleCallbacksRejected,
            "appleLifecyclePendingZero": pendingZero,
            "appleLifecycleHealthy": healthy
        ]
    }
    #endif

    private func handleGlobalHotKey() {
        guard let panelController else { return }
        globalSelectionGeneration &+= 1
        let generation = globalSelectionGeneration
        ManualEvidenceRecorder.shared.record(
            "globalHotKeyPressed",
            integers: ["selectionGeneration": Int64(clamping: generation)]
        )
        if panelController.isVisible {
            selectionValidationTimer?.invalidate()
            selectionValidationTimer = nil
            panelController.hide()
            panelController.invalidateGlobalSelection(generation: generation)
            return
        }

        // Capture the source application before showing or activating the panel.
        let sourceApplication = NSWorkspace.shared.frontmostApplication
        debugLog("frontmost_application=\(sourceApplication != nil)")

        switch selectionReader.readSelection(from: sourceApplication) {
        case .text(let capture):
            ManualEvidenceRecorder.shared.record(
                "globalSelectionCaptureCompleted",
                strings: ["resultKind": "accessibilityText"],
                integers: [
                    "selectionGeneration": Int64(clamping: generation),
                    "selectionLength": Int64(capture.text.count),
                    "selectionRectCount": Int64(capture.selectionRects.count)
                ]
            )
            guard capture.isFresh() else {
                panelController.invalidateGlobalSelection(generation: generation)
                panelController.show()
                return
            }
            let context = makeGlobalSelectionContext(
                capture, sourceApplication: sourceApplication, generation: generation
            )
            handleCapturedText(
                capture.text, selectionContext: context, generation: generation,
                with: panelController
            )
        case .permissionDenied:
            recordGlobalSelectionCapture("permissionDenied", generation: generation)
            debugLog("accessibility_trusted=false")
            panelController.invalidateGlobalSelection(generation: generation)
            panelController.show()
            DispatchQueue.main.async { [permissionPrompter] in
                permissionPrompter.showIfNeeded()
            }
        case .secureInput:
            recordGlobalSelectionCapture("secureInput", generation: generation)
            debugLog("secure_input=true selection_read=false")
            panelController.invalidateGlobalSelection(generation: generation)
            panelController.show()
        case .noSelection, .unavailable:
            recordGlobalSelectionCapture("clipboardFallback", generation: generation)
            debugLog("ax_selection_nonempty=false clipboard_fallback=true")
            panelController.invalidateGlobalSelection(generation: generation)
            handleClipboardFallback(
                from: sourceApplication, generation: generation, with: panelController
            )
        }
    }

    private func recordGlobalSelectionCapture(_ result: String, generation: UInt64) {
        ManualEvidenceRecorder.shared.record(
            "globalSelectionCaptureCompleted",
            strings: ["resultKind": result],
            integers: ["selectionGeneration": Int64(clamping: generation)]
        )
    }

    private func handleClipboardFallback(from application: NSRunningApplication?,
                                         generation: UInt64,
                                         with panelController: DictionaryPanelController) {
        switch clipboardFallback.readSelection(from: application) {
        case .text(let rawText):
            debugLog("clipboard_fallback_nonempty=true characters=\(rawText.count)")
            handleCapturedText(
                rawText, selectionContext: nil, generation: generation,
                with: panelController
            )
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
                                    selectionContext: GlobalSelectionContext?,
                                    generation: UInt64,
                                    with panelController: DictionaryPanelController) {
        let classification = QueryIntentClassifier.classify(rawText)
        switch classification.intent {
        case .word, .phrase, .sentence:
            debugLog("selection_nonempty=true characters=\(classification.normalizedText.count)")
            let found = panelController.showAndLookup(
                classification.normalizedText,
                globalSelectionContext: selectionContext,
                generation: generation
            )
            if let selectionContext,
               let processIdentifier = selectionContext.sourceProcessIdentifier {
                beginSelectionValidation(
                    context: selectionContext,
                    sourceProcessIdentifier: processIdentifier,
                    panelController: panelController
                )
            }
            debugLog("lookup_found=\(found)")
        case .textTooLong where classification.rejectionReason == .empty:
            debugLog("selection_nonempty=false")
            panelController.show()
        case .textTooLong:
            debugLog("selection_nonempty=true characters=\(classification.normalizedText.count) too_long=true")
            panelController.showSelectionTooLongMessage(
                globalSelectionContext: selectionContext,
                generation: generation
            )
        }
    }

    private func makeGlobalSelectionContext(
        _ capture: AccessibilitySelectionCapture,
        sourceApplication: NSRunningApplication?,
        generation: UInt64
    ) -> GlobalSelectionContext? {
        let displays = SelectionDisplayGeometry.liveScreens()
        let converted = AXSelectionCoordinateConverter.convert(
            capture.selectionRects, displays: displays
        )
        guard !converted.isEmpty else { return nil }
        return GlobalSelectionContext(
            selectedText: capture.text,
            selectionRects: converted,
            anchorRect: converted.last,
            generation: generation,
            capturedAt: capture.capturedAt,
            preferredDisplayID: AXSelectionCoordinateConverter.preferredDisplayID(
                for: capture.selectionRects, displays: displays
            ),
            rightToLeft: NSApp.userInterfaceLayoutDirection == .rightToLeft,
            sourceProcessIdentifier: sourceApplication?.processIdentifier
        )
    }

    private func beginSelectionValidation(
        context: GlobalSelectionContext,
        sourceProcessIdentifier: Int32,
        panelController: DictionaryPanelController
    ) {
        selectionValidationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self, weak panelController] _ in
            Task { @MainActor in
                guard let self, let panelController else { return }
                self.validateGlobalSelection(
                    original: context,
                    sourceProcessIdentifier: sourceProcessIdentifier,
                    panelController: panelController
                )
            }
        }
        selectionValidationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func validateGlobalSelection(
        original: GlobalSelectionContext,
        sourceProcessIdentifier: Int32,
        panelController: DictionaryPanelController
    ) {
        guard panelController.isVisible,
              original.generation == globalSelectionGeneration,
              panelController.isPresentingGlobalSelection(
                  generation: original.generation
              ),
              let sourceApplication = NSRunningApplication(
                  processIdentifier: sourceProcessIdentifier
              ), !sourceApplication.isTerminated else {
            selectionValidationTimer?.invalidate()
            selectionValidationTimer = nil
            return
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != sourceProcessIdentifier,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            invalidateGlobalSelectionAndHide(panelController)
            return
        }
        guard case .text(let capture) = selectionReader.readSelection(from: sourceApplication),
              capture.isFresh(),
              SentenceTextNormalizer.normalize(capture.text) ==
                SentenceTextNormalizer.normalize(original.selectedText),
              var refreshed = makeGlobalSelectionContext(
                  capture,
                  sourceApplication: sourceApplication,
                  generation: globalSelectionGeneration
              ) else {
            // PDF readers and translation plug-ins commonly clear their AX selection after a
            // global shortcut. The already captured query remains authoritative; stop tracking
            // geometry instead of making the dictionary panel disappear.
            selectionValidationTimer?.invalidate()
            selectionValidationTimer = nil
            ManualEvidenceRecorder.shared.record(
                "globalSelectionValidationStopped",
                strings: ["typedReason": "sourceSelectionNoLongerObservable"],
                integers: [
                    "selectionGeneration": Int64(clamping: original.generation)
                ]
            )
            return
        }
        guard refreshed.selectionRects != original.selectionRects ||
                refreshed.preferredDisplayID != original.preferredDisplayID else {
            if !panelController.refreshGlobalSelection(refreshed) {
                invalidateGlobalSelectionAndHide(panelController)
            }
            return
        }
        globalSelectionGeneration &+= 1
        refreshed = GlobalSelectionContext(
            selectedText: refreshed.selectedText,
            selectionRects: refreshed.selectionRects,
            anchorRect: refreshed.anchorRect,
            generation: globalSelectionGeneration,
            capturedAt: refreshed.capturedAt,
            preferredDisplayID: refreshed.preferredDisplayID,
            rightToLeft: refreshed.rightToLeft,
            sourceProcessIdentifier: refreshed.sourceProcessIdentifier
        )
        panelController.repositionGlobalSelection(refreshed)
        beginSelectionValidation(
            context: refreshed,
            sourceProcessIdentifier: sourceProcessIdentifier,
            panelController: panelController
        )
    }

    private func invalidateGlobalSelectionAndHide(
        _ panelController: DictionaryPanelController
    ) {
        selectionValidationTimer?.invalidate()
        selectionValidationTimer = nil
        globalSelectionGeneration &+= 1
        panelController.hide()
        panelController.invalidateGlobalSelection(generation: globalSelectionGeneration)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        NSLog("LocalDictionary AX: %@", message())
        #endif
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appName = AppLocalization.text("本地词典", "LocalDictionary")
        let applicationItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: appName)
        let about = NSMenuItem(title: AppLocalization.text("关于本地词典", "About LocalDictionary"),
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = NSApp
        applicationMenu.addItem(about)
        let helpAndAbout = NSMenuItem(
            title: AppLocalization.text("使用说明与版权…", "User Guide & Legal…"),
            action: #selector(showHelpAndAbout), keyEquivalent: ""
        )
        helpAndAbout.target = self
        applicationMenu.addItem(helpAndAbout)
        let languageSettings = NSMenuItem(
            title: AppLocalization.text("语言设置…", "Language Settings…"),
            action: #selector(showLanguageSettings), keyEquivalent: ","
        )
        languageSettings.target = self
        applicationMenu.addItem(languageSettings)
        applicationMenu.addItem(.separator())
        let hide = NSMenuItem(title: AppLocalization.text("隐藏本地词典", "Hide LocalDictionary"),
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        hide.target = NSApp
        applicationMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: AppLocalization.text("隐藏其他应用", "Hide Others"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        applicationMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: AppLocalization.text("显示全部", "Show All"),
                                 action: #selector(NSApplication.unhideAllApplications(_:)),
                                 keyEquivalent: "")
        showAll.target = NSApp
        applicationMenu.addItem(showAll)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: AppLocalization.text("退出本地词典", "Quit LocalDictionary"),
                              action: #selector(requestApplicationTermination(_:)),
                              keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editTitle = AppLocalization.text("编辑", "Edit")
        let editItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editTitle)
        editMenu.addItem(responderMenuItem(title: AppLocalization.text("撤销", "Undo"), action: "undo:", key: "z"))
        let redo = responderMenuItem(title: AppLocalization.text("重做", "Redo"), action: "redo:", key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem(title: AppLocalization.text("剪切", "Cut"), action: "cut:", key: "x"))
        editMenu.addItem(responderMenuItem(title: AppLocalization.text("复制", "Copy"), action: "copy:", key: "c"))
        editMenu.addItem(responderMenuItem(title: AppLocalization.text("粘贴", "Paste"), action: "paste:", key: "v"))
        editMenu.addItem(responderMenuItem(title: AppLocalization.text("全选", "Select All"), action: "selectAll:", key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowTitle = AppLocalization.text("窗口", "Window")
        let windowItem = NSMenuItem(title: windowTitle, action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: windowTitle)
        windowMenu.addItem(responderMenuItem(
            title: AppLocalization.text("关闭窗口", "Close Window"), action: "performClose:", key: "w"
        ))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

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
            button.toolTip = AppLocalization.text("本地词典", "LocalDictionary")
        }
        let menu = NSMenu()
        let show = NSMenuItem(title: AppLocalization.text("显示词典", "Show Dictionary"), action: #selector(showDictionary), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let manageDictionaries = NSMenuItem(title: AppLocalization.text("词典管理…", "Dictionary Manager…"),
                                            action: #selector(showDictionaryManager),
                                            keyEquivalent: "")
        manageDictionaries.target = self
        menu.addItem(manageDictionaries)
        let selectNote = NSMenuItem(title: AppLocalization.text("更改当前 Markdown 笔记…", "Change Current Markdown Note…"),
                                    action: #selector(selectObsidianNote),
                                    keyEquivalent: "")
        selectNote.target = self
        menu.addItem(selectNote)
        let languageSettings = NSMenuItem(title: AppLocalization.text("语言设置…", "Language Settings…"),
                                          action: #selector(showLanguageSettings),
                                          keyEquivalent: "")
        languageSettings.target = self
        menu.addItem(languageSettings)
        let aiSettings = NSMenuItem(title: AppLocalization.text("AI 服务设置…", "AI Service Settings…"),
                                    action: #selector(showAISettings),
                                    keyEquivalent: "")
        aiSettings.target = self
        menu.addItem(aiSettings)
        let helpAndAbout = NSMenuItem(
            title: AppLocalization.text("使用说明与版权…", "User Guide & Legal…"),
            action: #selector(showHelpAndAbout), keyEquivalent: ""
        )
        helpAndAbout.target = self
        menu.addItem(helpAndAbout)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: AppLocalization.text("退出", "Quit"),
                              action: #selector(requestApplicationTermination(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func showHotKeyRegistrationFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法启用 Option + Space"
        alert.informativeText = "全局快捷键可能已被其他应用占用。词典、设置和本地文件均不受影响；仍可通过菜单栏的“显示词典”打开面板。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func configureDictionary() async {
        // Reconcile App-owned storage before publishing any Catalog to query,
        // indexing, removal, manager, or panel runtime state.
        let lifecycle = await ownedDictionaryLifecycleReconciler.reconcile()
        var catalog = lifecycle.catalog
        let catalogIsWritable = !lifecycle.report.blocked
#if DEBUG
        if !lifecycle.report.issues.isEmpty {
            let codes = lifecycle.report.issues.map(\.code.rawValue).joined(separator: ",")
            NSLog("LocalDictionary lifecycle issues=%ld codes=%@",
                  lifecycle.report.issues.count, codes)
        }
#endif
        let config = AppConfig.loadIfPresent()
        if let config, catalogIsWritable {
            do {
                let mutation = try dictionaryCatalogStore.mutate { latest, _ in
                    let adapted = LegacyDictionaryConfigAdapter().adapt(config, into: latest)
                    latest = adapted
                }
                catalog = mutation.catalog
            } catch {
                // Preserve the last readable in-memory catalog.  A corrupt or unsupported
                // on-disk catalog is never replaced during startup.
            }
        } else if catalogIsWritable {
            catalog = LegacyDictionaryConfigAdapter()
                .markingUnresolvableLegacyReferencesUnavailable(in: catalog)
        }
        dictionaryCatalog = catalog
        recordOpenResourceEvidence(catalog)
        await managedDictionaryLifecycleCoordinator.initialize(reconciledCatalog: catalog)
        dictionaryIndexCoordinator.synchronize(catalog: catalog)

        let managedService = ManagedDictionaryQueryService(
            catalog: catalog,
            runtime: LiveManagedDictionaryQueryRuntime(),
            lifecycleCoordinator: managedDictionaryLifecycleCoordinator
        )
        managedDictionaryQueryService = managedService
        dictionaryIndexCoordinator.setRuntimeInvalidator { dictionaryID in
            await managedService.invalidateRuntime(dictionaryID: dictionaryID)
        }

        if let config {
            let core = DictionaryCoreBridge(dictionaryPath: config.primaryDictionary,
                                            indexPath: config.indexPath)
            let supplementalConfigurations = config.supplementalDictionaries
            let supplementalDictionaries = supplementalConfigurations.map { configuration in
                SupplementalDictionaryRuntime(
                    id: configuration.id,
                    displayName: configuration.displayName,
                    priority: configuration.priority,
                    core: DictionaryCoreBridge(
                        dictionaryPath: configuration.dictionaryPath,
                        indexPath: configuration.indexPath,
                        cacheMaximumBytes: 2 * 1024 * 1024,
                        cacheMaximumEntries: 32
                    )
                )
            }
            var reverseSources = [ReverseDictionarySource(
                dictionaryID: DictionarySourceID.oxfordOALD8.rawValue,
                dictionaryName: "牛津高阶 8",
                dictionaryURL: URL(fileURLWithPath: config.primaryDictionary),
                indexURL: URL(fileURLWithPath: config.indexPath),
                queryPriority: 0,
                sortPosition: 1,
                expectedEntryCount: catalog.dictionaries.first {
                    $0.dictionaryID == DictionarySourceID.oxfordOALD8.rawValue
                }?.indexMetadata.entryCount,
                formatterIdentifier: catalog.dictionaries.first {
                    $0.dictionaryID == DictionarySourceID.oxfordOALD8.rawValue
                }?.formatterIdentifier ?? DictionaryFormatterIdentifier.oxfordOALD8V1
            )]
            reverseSources.append(contentsOf: supplementalConfigurations.map { configuration in
                ReverseDictionarySource(
                    dictionaryID: configuration.id.rawValue,
                    dictionaryName: configuration.displayName,
                    dictionaryURL: URL(fileURLWithPath: configuration.dictionaryPath),
                    indexURL: URL(fileURLWithPath: configuration.indexPath),
                    queryPriority: 0,
                    sortPosition: Int64(configuration.priority + 1),
                    expectedEntryCount: catalog.dictionaries.first {
                        $0.dictionaryID == configuration.id.rawValue
                    }?.indexMetadata.entryCount,
                    formatterIdentifier: catalog.dictionaries.first {
                        $0.dictionaryID == configuration.id.rawValue
                    }?.formatterIdentifier ?? DictionaryFormatterIdentifier.legacyGenericMDictV1
                )
            })
            // Keep the configured identities so normal enable/disable changes can be applied at
            // runtime, but publish only active Catalog registrations.  A retired legacy
            // tombstone must stop both forward and reverse lookup without touching external files.
            legacyReverseDictionarySources = reverseSources
            reverseSources = Self.activeLegacyReverseSources(
                legacyReverseDictionarySources, catalog: catalog
            )
            reverseSources.append(contentsOf: Self.managedReverseSources(from: catalog))
            await restoreReverseIndexes(for: reverseSources)
            panelController = DictionaryPanelController(core: core,
                                                        supplementalDictionaries: supplementalDictionaries,
                                                        noteStore: noteStore,
                                                        notePicker: notePicker,
                                                        aiService: aiService,
                                                        managedDictionaryQueryService: managedService,
                                                        dictionaryCatalog: catalog,
                                                        reverseLookupService: reverseLookupService,
                                                        reverseIndexCoordinator: reverseIndexCoordinator,
                                                        backgroundWorkCoordinator: backgroundWorkCoordinator,
                                                        reverseDictionarySources: reverseSources,
                                                        openAISettings: { [weak self] in
                                                            self?.showAISettings()
                                                        })
        } else {
            legacyReverseDictionarySources = []
            let core = DictionaryCoreBridge(dictionaryPath: "", indexPath: "")
            let reverseSources = Self.managedReverseSources(from: catalog)
            await restoreReverseIndexes(for: reverseSources)
            panelController = DictionaryPanelController(core: core,
                                                        noteStore: noteStore,
                                                        notePicker: notePicker,
                                                        aiService: aiService,
                                                        managedDictionaryQueryService: managedService,
                                                        dictionaryCatalog: catalog,
                                                        reverseLookupService: reverseLookupService,
                                                        reverseIndexCoordinator: reverseIndexCoordinator,
                                                        backgroundWorkCoordinator: backgroundWorkCoordinator,
                                                        reverseDictionarySources: reverseSources,
                                                        openAISettings: { [weak self] in
                                                            self?.showAISettings()
                                                        })
        }
        let removalCoordinator = ManagedDictionaryRemovalCoordinator(
            catalog: catalog,
            catalogStore: dictionaryCatalogStore,
            queryService: managedService,
            lifecycleCoordinator: managedDictionaryLifecycleCoordinator,
            isIndexing: { [dictionaryIndexCoordinator] dictionaryID in
                dictionaryIndexCoordinator.activity?.dictionaryID == dictionaryID
            }
        )
        removalCoordinator.beforeRemoval = { [weak self] dictionaryID in
            self?.panelController?.managedDictionaryWillBeRemoved(dictionaryID: dictionaryID)
        }
        removalCoordinator.onCatalogChanged = { [weak self] updated in
            self?.applyCatalogChange(updated, replaceManagedCatalog: false)
        }
        dictionaryRemovalCoordinator = removalCoordinator
        resourceCenterController.setRemovalCoordinator(removalCoordinator)

        dictionaryIndexCoordinator.onCatalogChanged = { [weak self] updated in
            self?.applyCatalogChange(updated)
        }
        dictionaryManagerController?.update(catalog: catalog)
        dictionaryManagerController?.updateReverseSources(
            Self.activeLegacyReverseSources(legacyReverseDictionarySources, catalog: catalog) +
                Self.managedReverseSources(from: catalog)
        )
        scheduleReverseCapabilityProbes(for: catalog)
    }

    private func recordOpenResourceEvidence(_ catalog: DictionaryCatalog) {
        let root = DictionaryImportService.defaultApplicationSupportRootURL()
        for descriptor in catalog.dictionaries where
            descriptor.storageOwnership == .appManagedOpenResource {
            let metadata = descriptor.openResourceMetadata
            let receiptPresent = metadata.map {
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent($0.sidecarRelativePath).path
                )
            } ?? false
            let publicationPresent = descriptor.publishedIndexIdentity.map {
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent($0.relativePath).path
                )
            } ?? false
            let publicationIdentityValid = descriptor.state == .ready &&
                livePublishedIndexVerifier(root, descriptor)
            ManualEvidenceRecorder.shared.record("openResourcePersistentState", strings: [
                "resourceID": metadata?.resourceID ?? "unknown",
                "publicationID": descriptor.publishedIndexIdentity?.indexPublicationID ??
                    "missing",
                "sourceOwnership": descriptor.storageOwnership.rawValue,
                "catalogState": descriptor.state.rawValue,
                "statusPresented": DictionaryManagerPresentation.statusText(for: descriptor)
            ], booleans: [
                "enabled": descriptor.enabled,
                "receiptPresent": receiptPresent,
                "publicationPresent": publicationPresent,
                "publicationIdentityValid": publicationIdentityValid,
                "descriptorBuilt": descriptor.publishedIndexIdentity != nil,
                "queryServiceRegistered": descriptor.enabled && descriptor.state == .ready &&
                    publicationIdentityValid
            ])
        }
    }

    private func applyCatalogChange(_ catalog: DictionaryCatalog,
                                    replaceManagedCatalog: Bool = true) {
        reverseCatalogGeneration &+= 1
        let reverseGeneration = reverseCatalogGeneration
        let reverseSources = Self.activeLegacyReverseSources(
            legacyReverseDictionarySources, catalog: catalog
        ) +
            Self.managedReverseSources(from: catalog)
        dictionaryCatalog = catalog
        dictionaryIndexCoordinator.synchronize(catalog: catalog)
        dictionaryRemovalCoordinator?.synchronize(catalog: catalog)
        resourceCenterController.synchronize(catalog: catalog)
        dictionaryManagerController?.update(catalog: catalog)
        dictionaryManagerController?.updateReverseSources(
            reverseSources
        )
        panelController?.updateDictionaryCatalog(catalog)
        panelController?.updateReverseDictionarySources(reverseSources)
        // Installation/removal changes the actual set of internal reverse descriptors. Merely
        // updating the manager's source rows left the long-lived production lookup actor with its
        // launch-time descriptor set, so a newly ready FreeDict index was never queried.
        Task { [weak self] in
            await self?.restoreReverseIndexes(
                for: reverseSources, expectedGeneration: reverseGeneration
            )
        }
        if replaceManagedCatalog, let service = managedDictionaryQueryService {
            Task { await service.replaceCatalog(catalog) }
        }
        scheduleReverseCapabilityProbes(for: catalog)
    }

    private func scheduleReverseCapabilityProbes(for catalog: DictionaryCatalog) {
        guard !terminationStarted else { return }
        for descriptor in catalog.dictionaries where
            descriptor.sourceKind == .managedLocal &&
            descriptor.storageOwnership == .appManagedImported &&
            descriptor.state == .ready && descriptor.enabled &&
            descriptor.publishedIndexIdentity != nil &&
            descriptor.reverseCapabilityProbe == nil &&
            reverseCapabilityProbeTasks[descriptor.dictionaryID] == nil {
            let dictionaryID = descriptor.dictionaryID
            let publicationID = descriptor.publishedIndexIdentity?.indexPublicationID
            ManualEvidenceRecorder.shared.record(
                "reverseCapabilityProbeStarted",
                strings: [
                    "dictionaryID": dictionaryID,
                    "publicationID": publicationID ?? "missing",
                    "trigger": "automaticAfterForwardIndex"
                ],
                integers: [
                    "maximumEntries": Int64(ManagedReverseCapabilityProbe.maximumEntries)
                ]
            )
            reverseCapabilityProbeTasks[dictionaryID] = Task { [weak self] in
                let worker = Task.detached(priority: .utility) {
                    ManagedReverseCapabilityProbe.inspect(
                        descriptor: descriptor, mode: .sample
                    )
                }
                let report = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self else { return }
                self.reverseCapabilityProbeTasks[dictionaryID] = nil
                guard !Task.isCancelled,
                      let index = self.dictionaryCatalog.dictionaries.firstIndex(where: {
                          $0.dictionaryID == dictionaryID &&
                              $0.publishedIndexIdentity?.indexPublicationID == publicationID &&
                              $0.reverseCapabilityProbe == descriptor.reverseCapabilityProbe
                      }) else { return }
                var updated = self.dictionaryCatalog
                updated.dictionaries[index].reverseCapabilityProbe = report.result
                updated.dictionaries[index].updatedAt = Date()
                updated.updatedAt = Date()
                do {
                    try self.dictionaryCatalogStore.save(updated)
                    self.applyCatalogChange(updated)
                    ManualEvidenceRecorder.shared.record(
                        "reverseCapabilityProbeCompleted",
                        strings: [
                            "dictionaryID": dictionaryID,
                            "publicationID": publicationID ?? "missing",
                            "trigger": "automaticAfterForwardIndex",
                            "mode": report.mode.rawValue,
                            "result": report.result.rawValue,
                            "typedReason": report.terminalReason.rawValue
                        ], integers: [
                            "processedEntryCount": Int64(clamping: report.processedEntryCount),
                            "expectedEntryCount": Int64(clamping: report.expectedEntryCount ?? 0),
                            "usableEntryCount": Int64(clamping: report.usableEntryCount),
                            "usableNativeGlossCount": Int64(clamping: report.usableNativeGlossCount),
                            "skippedEntryCount": Int64(clamping: report.skippedEntryCount)
                        ]
                    )
                } catch {
                    ManualEvidenceRecorder.shared.record(
                        "reverseCapabilityProbeCompleted",
                        strings: [
                            "dictionaryID": dictionaryID,
                            "publicationID": publicationID ?? "missing",
                            "trigger": "automaticAfterForwardIndex",
                            "result": "catalogSaveFailed"
                        ]
                    )
                    #if DEBUG
                    NSLog("LocalDictionary reverse capability probe Catalog save failed type=%@",
                          String(reflecting: type(of: error)))
                    #endif
                }
            }
        }
    }

    @objc private func showDictionary() { panelController?.show() }
    @objc private func showDictionaryManager() {
        guard let dictionaryRemovalCoordinator else { return }
        if dictionaryManagerController == nil {
            dictionaryManagerController = DictionaryManagerWindowController(
                catalog: dictionaryCatalog,
                catalogStore: dictionaryCatalogStore,
                indexCoordinator: dictionaryIndexCoordinator,
                removalCoordinator: dictionaryRemovalCoordinator,
                resourceCenterController: resourceCenterController,
                reverseIndexCoordinator: reverseIndexCoordinator,
                reverseLookupService: reverseLookupService,
                reverseSources: Self.activeLegacyReverseSources(
                    legacyReverseDictionarySources, catalog: dictionaryCatalog
                ) +
                    Self.managedReverseSources(from: dictionaryCatalog),
                onCatalogChanged: { [weak self] catalog in
                    self?.applyCatalogChange(catalog)
                }
            )
        }
        dictionaryManagerController?.show()
    }
    @objc private func selectObsidianNote() {
        guard notePicker.chooseTarget(for: noteStore) else { return }
        panelController?.targetNoteDidChange()
    }
    @objc private func showAISettings() { aiSettingsController.show() }
    @objc private func showLanguageSettings() { languageSettingsController.show() }
    @objc private func showHelpAndAbout() { helpAndAboutController.show() }
    private static func managedReverseSources(
        from catalog: DictionaryCatalog
    ) -> [ReverseDictionarySource] {
        catalog.sortedDictionaries.compactMap { descriptor in
            guard descriptor.enabled, descriptor.state == .ready,
                  descriptor.sourceKind == .managedLocal ||
                    descriptor.sourceKind == .openResource,
                  descriptor.publishedIndexIdentity != nil else { return nil }
            return ReverseDictionarySource(managed: descriptor)
        }
    }

    private static func activeLegacyReverseSources(
        _ configured: [ReverseDictionarySource],
        catalog: DictionaryCatalog
    ) -> [ReverseDictionarySource] {
        let activeIDs = Set(catalog.dictionaries.compactMap { descriptor -> String? in
            guard descriptor.sourceKind == .legacyReference,
                  descriptor.storageOwnership == .externalReference,
                  descriptor.enabled,
                  descriptor.state == .ready,
                  !descriptor.isRetiredLegacyRegistration else { return nil }
            return descriptor.dictionaryID
        })
        return configured.filter { activeIDs.contains($0.dictionaryID) }
    }

    private func restoreReverseIndexes(
        for sources: [ReverseDictionarySource],
        expectedGeneration: UInt64? = nil
    ) async {
        let states = await Task.detached(priority: .utility) {
            ReverseIndexInventory.inspect(sources: sources)
        }.value
        if let expectedGeneration,
           expectedGeneration != reverseCatalogGeneration { return }
        await reverseLookupService.replaceDescriptors(states.compactMap(\.descriptor))
        await reverseLookupService.replaceBuildStages(
            Dictionary(uniqueKeysWithValues: states.map { ($0.dictionaryID, $0.stage) })
        )
    }

}
