import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: DictionaryPanelController?
    private var dictionaryManagerController: DictionaryManagerWindowController?
    private var dictionaryCatalog = DictionaryCatalog.empty()
    private let dictionaryCatalogStore = DictionaryCatalogStore()
    private let managedDictionaryLifecycleCoordinator =
        ManagedDictionaryLifecycleCoordinator()
    // The Resource Center has no product UI in this stage, but its future installation entry
    // must use this same process-local coordinator rather than creating a second state source.
    private lazy var openResourceInstallationCoordinator = OpenResourceInstallationCoordinator(
        lifecycleCoordinator: managedDictionaryLifecycleCoordinator
    )
    private lazy var ownedDictionaryLifecycleReconciler =
        OwnedDictionaryLifecycleReconciler(
            catalogStore: dictionaryCatalogStore,
            verifyPublishedIndex: livePublishedIndexVerifier
        )
    private var managedDictionaryQueryService: ManagedDictionaryQueryService?
    private var dictionaryRemovalCoordinator: ManagedDictionaryRemovalCoordinator?
    private lazy var dictionaryIndexCoordinator = ManagedDictionaryIndexCoordinator(
        catalogStore: dictionaryCatalogStore,
        buildIndex: liveDictionaryIndexBuilder,
        expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion),
        lifecycleCoordinator: managedDictionaryLifecycleCoordinator
    )
    private var hotKey: GlobalHotKey?
    private let selectionReader = AccessibilitySelectionReader()
    private let clipboardFallback = ClipboardSelectionFallback()
    private let permissionPrompter = AccessibilityPermissionPrompter()
    private let noteStore = ObsidianNoteStore()
    private let notePicker = ObsidianNotePicker()
    private let aiConfigurationStore = AIConfigurationStore()
    private let aiKeychainStore = AIKeychainStore()
    private let aiCache = AIExplanationCache()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

    func applicationWillTerminate(_ notification: Notification) {
        dictionaryIndexCoordinator.cancelCurrentTask()
        Task { await managedDictionaryLifecycleCoordinator.shutdown() }
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
        let classification = QueryIntentClassifier.classify(rawText)
        switch classification.intent {
        case .word, .phrase, .sentence:
            debugLog("selection_nonempty=true characters=\(classification.normalizedText.count)")
            let found = panelController.showAndLookup(classification.normalizedText)
            debugLog("lookup_found=\(found)")
        case .textTooLong where classification.rejectionReason == .empty:
            debugLog("selection_nonempty=false")
            panelController.show()
        case .textTooLong:
            debugLog("selection_nonempty=true characters=\(classification.normalizedText.count) too_long=true")
            panelController.showSelectionTooLongMessage()
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
        let manageDictionaries = NSMenuItem(title: "词典管理…",
                                            action: #selector(showDictionaryManager),
                                            keyEquivalent: "")
        manageDictionaries.target = self
        menu.addItem(manageDictionaries)
        let selectNote = NSMenuItem(title: "更改当前 Markdown 笔记…",
                                    action: #selector(selectObsidianNote),
                                    keyEquivalent: "")
        selectNote.target = self
        menu.addItem(selectNote)
        let aiSettings = NSMenuItem(title: "AI 服务设置…",
                                    action: #selector(showAISettings),
                                    keyEquivalent: "")
        aiSettings.target = self
        menu.addItem(aiSettings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
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
            let supplementalDictionaries = config.supplementalDictionaries.map { configuration in
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
            panelController = DictionaryPanelController(core: core,
                                                        supplementalDictionaries: supplementalDictionaries,
                                                        noteStore: noteStore,
                                                        notePicker: notePicker,
                                                        aiService: aiService,
                                                        managedDictionaryQueryService: managedService,
                                                        dictionaryCatalog: catalog,
                                                        openAISettings: { [weak self] in
                                                            self?.showAISettings()
                                                        })
        } else {
            let core = DictionaryCoreBridge(dictionaryPath: "", indexPath: "")
            panelController = DictionaryPanelController(core: core,
                                                        noteStore: noteStore,
                                                        notePicker: notePicker,
                                                        aiService: aiService,
                                                        managedDictionaryQueryService: managedService,
                                                        dictionaryCatalog: catalog,
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

        dictionaryIndexCoordinator.onCatalogChanged = { [weak self] updated in
            self?.applyCatalogChange(updated)
        }
        dictionaryManagerController?.update(catalog: catalog)
    }

    private func applyCatalogChange(_ catalog: DictionaryCatalog,
                                    replaceManagedCatalog: Bool = true) {
        dictionaryCatalog = catalog
        dictionaryIndexCoordinator.synchronize(catalog: catalog)
        dictionaryRemovalCoordinator?.synchronize(catalog: catalog)
        dictionaryManagerController?.update(catalog: catalog)
        panelController?.updateDictionaryCatalog(catalog)
        if replaceManagedCatalog, let service = managedDictionaryQueryService {
            Task { await service.replaceCatalog(catalog) }
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
    @objc private func quitApplication() { NSApp.terminate(nil) }
}
