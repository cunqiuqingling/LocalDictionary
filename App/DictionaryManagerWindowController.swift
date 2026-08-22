import AppKit
import UniformTypeIdentifiers

@MainActor
enum ResourceCenterTerminationKeyEquivalentState {
    static var isForwardingCommandQ = false
}

@MainActor
final class ResourceCenterSheetWindow: NSWindow {
    var requestClose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        requestClose?()
    }

    override func performClose(_ sender: Any?) {
        requestClose?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            ResourceCenterTerminationKeyEquivalentState.isForwardingCommandQ = true
            defer { ResourceCenterTerminationKeyEquivalentState.isForwardingCommandQ = false }
            guard let quit = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
                $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask.contains(.command)
            }), let action = quit.action else { return false }
            return NSApp.sendAction(action, to: quit.target, from: quit)
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class DictionaryManagerWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private enum Column: String, CaseIterable {
        case name
        case source
        case level
        case enabled
        case forwardState
        case reverseState
        case action
    }

    private var catalog: DictionaryCatalog
    private var dictionaries: [DictionaryDescriptor] = []
    private let catalogStore: DictionaryCatalogStore
    private let orderCoordinator: DictionaryCatalogOrderCoordinator
    private let importInspector: MDictImportInspector
    private let importService: DictionaryImportService
    private let indexCoordinator: ManagedDictionaryIndexCoordinator
    private let removalCoordinator: ManagedDictionaryRemovalCoordinator
    private let resourceCenterController: ResourceCenterController
    private let reverseIndexCoordinator: ReverseIndexCoordinator
    private let reverseLookupService: ReverseLookupService
    private let reverseInventoryRootURL: URL?
    private let reverseCapabilityProbeRunner:
        @Sendable (DictionaryDescriptor, ManagedReverseCapabilityProbeMode)
            -> ManagedReverseCapabilityProbeReport
    private let onCatalogChanged: (DictionaryCatalog) -> Void
    private var reverseSources: [ReverseDictionarySource]
    private var reverseStoredStates: [String: ReverseIndexStoredState] = [:]
    private var reverseProgress: [String: ReverseIndexDictionaryProgress] = [:]
    private var reverseBuildTask: Task<Void, Never>?
    /// Set synchronously before a reverse build Task starts, so removal cannot race the first
    /// progress callback. Terminal progress remains visible but is never mistaken for active work.
    private var reverseBuildDictionaryIDs: Set<String> = []
    private var reverseCapabilityProbeTasks: [String: Task<Void, Never>] = [:]
    private var previewAccessory: DictionaryImportPreviewAccessory?
    private var previewWindowController: DictionaryImportPreviewWindowController?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSStackView()
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()
    private let removeButton = NSButton()
    private let buildAllReverseButton = NSButton()
    private let reorderHelpLabel = NSTextField(labelWithString:
        "拖动或使用上下按钮调整统一查询顺序；同等匹配质量按此顺序显示。")
    private var shouldCenterOnFirstShow: Bool
    private var removingDictionaryID: String?
    private var cancellingDictionaryID: String?
    private var resourceCenterSheet: ResourceCenterSheetWindow?
    private static let dictionaryPasteboardType = NSPasteboard.PasteboardType(
        "com.localdict.dictionary-catalog-id"
    )

    init(catalog: DictionaryCatalog,
         catalogStore: DictionaryCatalogStore,
         importInspector: MDictImportInspector = MDictImportInspector(),
         importService: DictionaryImportService? = nil,
         indexCoordinator: ManagedDictionaryIndexCoordinator,
         removalCoordinator: ManagedDictionaryRemovalCoordinator,
         resourceCenterController: ResourceCenterController,
         reverseIndexCoordinator: ReverseIndexCoordinator,
         reverseLookupService: ReverseLookupService,
         reverseSources: [ReverseDictionarySource] = [],
         reverseInventoryRootURL: URL? = nil,
         reverseCapabilityProbeRunner: @escaping @Sendable (
            DictionaryDescriptor, ManagedReverseCapabilityProbeMode
         ) -> ManagedReverseCapabilityProbeReport = {
            ManagedReverseCapabilityProbe.inspect(descriptor: $0, mode: $1)
         },
         onCatalogChanged: @escaping (DictionaryCatalog) -> Void = { _ in }) {
        self.catalog = catalog
        self.catalogStore = catalogStore
        orderCoordinator = DictionaryCatalogOrderCoordinator(
            catalog: catalog, catalogStore: catalogStore
        )
        self.importInspector = importInspector
        self.importService = importService ?? DictionaryImportService(catalogStore: catalogStore)
        self.indexCoordinator = indexCoordinator
        self.removalCoordinator = removalCoordinator
        self.resourceCenterController = resourceCenterController
        self.reverseIndexCoordinator = reverseIndexCoordinator
        self.reverseLookupService = reverseLookupService
        self.reverseSources = reverseSources
        self.reverseInventoryRootURL = reverseInventoryRootURL
        self.reverseCapabilityProbeRunner = reverseCapabilityProbeRunner
        self.onCatalogChanged = onCatalogChanged
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DictionaryManagerPresentation.defaultWindowWidth,
                height: DictionaryManagerPresentation.defaultWindowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLocalization.text("词典管理", "Dictionary Manager")
        window.minSize = NSSize(
            width: DictionaryManagerPresentation.minimumWindowWidth,
            height: DictionaryManagerPresentation.minimumWindowHeight
        )
        shouldCenterOnFirstShow = !window.setFrameUsingName(
            "LocalDictionary.DictionaryManager"
        )
        window.setFrameAutosaveName("LocalDictionary.DictionaryManager")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent()
        update(catalog: catalog)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resourceLanguagePreferencesDidChange),
            name: .localDictionaryLanguagePreferencesDidChange,
            object: LanguagePreferencesStore.shared
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if shouldCenterOnFirstShow {
            window.center()
            shouldCenterOnFirstShow = false
        }
        window.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func prepareForTermination() -> Bool {
        let resourceCenterEnded = endResourceCenterBeforeApplicationTermination()
        indexCoordinator.cancelCurrentTask()
        reverseBuildTask?.cancel()
        reverseBuildTask = nil
        reverseCapabilityProbeTasks.values.forEach { $0.cancel() }
        reverseCapabilityProbeTasks.removeAll()
        reverseIndexCoordinator.cancel()
        window?.orderOut(nil)
        return resourceCenterEnded
    }

    @discardableResult
    func endResourceCenterBeforeApplicationTermination() -> Bool {
        guard let sheet = resourceCenterSheet else { return false }
        closeResourceCenter()
        sheet.orderOut(nil)
        return resourceCenterSheet == nil && sheet.sheetParent == nil
    }

    func windowWillClose(_ notification: Notification) {
        closeResourceCenter()
    }

    var isResourceCenterPresented: Bool { resourceCenterSheet != nil }

    var reverseIndexActiveForTermination: Bool { reverseBuildTask != nil }

    func update(catalog: DictionaryCatalog) {
        let selectedID = selectedDictionary?.dictionaryID
        self.catalog = catalog
        orderCoordinator.synchronize(catalog: catalog)
        indexCoordinator.synchronize(catalog: catalog)
        removalCoordinator.synchronize(catalog: catalog)
        resourceCenterController.synchronize(catalog: catalog)
        dictionaries = catalog.activeSortedDictionaries
        if let cancellingDictionaryID,
           !dictionaries.contains(where: {
               $0.dictionaryID == cancellingDictionaryID && $0.state == .indexing
           }) {
            self.cancellingDictionaryID = nil
        }
        tableView.reloadData()
        scrollView.isHidden = dictionaries.isEmpty
        emptyStateView.isHidden = !dictionaries.isEmpty
        if let selectedID,
           let row = dictionaries.firstIndex(where: { $0.dictionaryID == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateSelectionActions()
        refreshReverseInventory()
    }

    func updateReverseSources(_ sources: [ReverseDictionarySource]) {
        reverseSources = sources
        refreshReverseInventory()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { dictionaries.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < dictionaries.count, let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        if column == .enabled {
            let dictionary = dictionaries[row]
            let button = NSButton(checkboxWithTitle: "", target: self,
                                  action: #selector(enabledStateChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(dictionary.dictionaryID)
            button.state = dictionary.enabled ? .on : .off
            button.isEnabled = (dictionary.sourceKind == .managedLocal ||
                dictionary.sourceKind == .openResource ||
                dictionary.sourceKind == .legacyReference) &&
                removingDictionaryID != dictionary.dictionaryID
            button.toolTip = dictionary.sourceKind == .legacyReference
                ? "启用或停用此旧配置词典；不会删除或修改其原始文件。"
                : "启用或停用此托管词典；不会删除其索引。"
            button.setAccessibilityLabel("启用或停用“\(dictionary.displayName)”")
            button.setAccessibilityValue(dictionary.enabled ? "已启用" : "已停用")
            return button
        }
        if column == .action { return combinedActionView(for: dictionaries[row]) }
        let identifier = NSUserInterfaceItemIdentifier("DictionaryManager.\(column.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier,
                                           owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let dictionary = dictionaries[row]
        let value = value(for: column, dictionary: dictionary)
        cell.textField?.stringValue = value
        cell.textField?.textColor = column == .forwardState
            ? stateColor(for: dictionary) : .labelColor
        cell.textField?.setAccessibilityLabel("\(tableColumn.title)：\(value)")
        if column == .name {
            cell.toolTip = dictionary.displayName
        } else if column == .forwardState {
            var detail = DictionaryManagerPresentation.statusDetail(
                for: dictionary,
                activity: presentationActivity(for: dictionary)
            )
            if dictionary.state == .failed,
               let failure = DictionaryManagerPresentation.safeIndexFailureMessage(
                   indexCoordinator.failureMessage(for: dictionary.dictionaryID)
               ) {
                detail += "\n" + failure
            }
            if let metadata = dictionary.openResourceMetadata {
                detail += "\n版本：\(metadata.resourceVersion)"
                detail += "\n许可证：\(metadata.license.name) \(metadata.license.version)"
                detail += "\n来源项目：\(metadata.sourceProject)"
            }
            cell.toolTip = detail
        } else if column == .reverseState {
            cell.toolTip = DictionaryManagerPresentation.reverseStatusDetail(
                reverseStoredStates[dictionary.dictionaryID],
                progress: reverseProgress[dictionary.dictionaryID],
                capability: reverseCapability(dictionary.dictionaryID)
            )
        } else {
            cell.toolTip = nil
        }
        return cell
    }

    private func configureContent() {
        guard let window else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let heading = NSTextField(labelWithString: t("已安装词典", "Installed Dictionaries"))
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(wrappingLabelWithString: t(
            "正向查询索引与中文反向索引彼此独立。选择“详情”可查看词条数、大小、时间、进度和失败原因。",
            "Forward and native-language reverse indexes are independent. Choose Details to " +
                "view entry count, size, time, progress, and failure reason."
        ))
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        configureEmptyState()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let orderingActions = NSStackView(views: [
            configuredMoveButton(moveUpButton, title: t("上移", "Move Up"),
                                 action: #selector(moveSelectedUp)),
            configuredMoveButton(moveDownButton, title: t("下移", "Move Down"),
                                 action: #selector(moveSelectedDown)),
            restoreDefaultsButton(),
            configuredRemoveButton()
        ])
        orderingActions.orientation = .horizontal
        orderingActions.spacing = 8
        orderingActions.alignment = .centerY
        orderingActions.distribution = .fill

        let resourceActions = NSStackView(views: [
            configuredBuildAllReverseButton(),
            resourceCenterButton(),
            importButton()
        ])
        resourceActions.orientation = .horizontal
        resourceActions.spacing = 10
        resourceActions.alignment = .centerY
        resourceActions.distribution = .fill

        reorderHelpLabel.textColor = .secondaryLabelColor
        reorderHelpLabel.stringValue = t(
            "拖动或使用上下按钮调整统一查询顺序；同等匹配质量按此顺序显示。",
            "Drag or use the arrow buttons to set one query order for all dictionaries."
        )
        reorderHelpLabel.font = .systemFont(ofSize: 11)
        reorderHelpLabel.setAccessibilityLabel("排序说明")

        let actions = NSStackView(views: [orderingActions, resourceActions, reorderHelpLabel])
        actions.orientation = .vertical
        actions.spacing = 7
        actions.alignment = .leading
        actions.distribution = .fill
        actions.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(heading)
        root.addSubview(explanation)
        root.addSubview(scrollView)
        root.addSubview(emptyStateView)
        root.addSubview(actions)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            explanation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),
            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor,
                                                     constant: 40),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                                      constant: -40),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                               constant: -24),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        window.initialFirstResponder = tableView
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 46
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.registerForDraggedTypes([Self.dictionaryPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityLabel(t("词典列表", "Dictionary List"))
        tableView.setAccessibilityHelp("使用方向键选择词典；可在所有来源之间调整统一查询顺序。")

        addColumn(.name, title: t("词典名称", "Dictionary"))
        addColumn(.source, title: t("来源", "Source"))
        addColumn(.level, title: t("词典类型", "Dictionary Type"))
        addColumn(.enabled, title: t("启用", "Enabled"))
        addColumn(.forwardState, title: t("正向状态", "Forward Status"))
        addColumn(.reverseState, title: t("中文反向索引", "Native Reverse Index"))
        addColumn(.action, title: t("操作", "Actions"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
    }

    private func addColumn(_ column: Column, title: String) {
        let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
        tableColumn.title = title
        let width = DictionaryManagerPresentation.columnWidths[column.rawValue] ?? 80
        tableColumn.width = width
        tableColumn.minWidth = width
        tableColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(tableColumn)
    }

    private func configureEmptyState() {
        let title = NSTextField(labelWithString: t(
            "当前没有可用的本地词典", "No Local Dictionaries Available"
        ))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: t(
            "可以导入一个本地 MDX，或打开资源中心查看经过验证的开放资源。",
            "Import a local MDX or open the Resource Center to browse validated open resources."
        ))
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.distribution = .fill
        emptyStateView.addArrangedSubview(title)
        emptyStateView.addArrangedSubview(detail)
        let importButton = importButton()
        importButton.setAccessibilityLabel("导入本地 MDX")
        emptyStateView.addArrangedSubview(importButton)
        emptyStateView.addArrangedSubview(resourceCenterButton())
    }

    private func resourceCenterButton() -> NSButton {
        let button = NSButton(title: t("查找双语开放词典…", "Find Bilingual Dictionaries…"), target: self,
                              action: #selector(showResourceCenter))
        button.bezelStyle = .rounded
        button.toolTip = "按当前母语与学习语言，从官方目录实时匹配可安装的双语开放词典。"
        button.setAccessibilityLabel("查找双语开放词典")
        return button
    }

    private func importButton() -> NSButton {
        let button = NSButton(title: t("导入本地 MDX…", "Import Local MDX…"), target: self,
                              action: #selector(beginImport))
        button.bezelStyle = .rounded
        button.toolTip = "选择一个 MDX 文件，预览后点击一次“导入”即可复制并自动建立查询索引。"
        button.setAccessibilityLabel("导入本地 MDX")
        return button
    }

    private func configuredBuildAllReverseButton() -> NSButton {
        buildAllReverseButton.title = t(
            "建立全部中文反向索引", "Build All Native-Language Reverse Indexes"
        )
        buildAllReverseButton.target = self
        buildAllReverseButton.action = #selector(buildAllReverseIndexes)
        buildAllReverseButton.bezelStyle = .rounded
        buildAllReverseButton.toolTip =
            "只为尚未完成、失败或已过期的词典串行建立 sidecar；已完成的词典会保留。"
        buildAllReverseButton.setAccessibilityLabel("建立全部中文反向索引")
        return buildAllReverseButton
    }

    private func configuredMoveButton(_ button: NSButton, title: String,
                                      action: Selector) -> NSButton {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.toolTip = title == "上移"
            ? "在统一查询顺序中将所选词典上移。"
            : "在统一查询顺序中将所选词典下移。"
        button.setAccessibilityLabel(title + "所选词典")
        return button
    }

    private func restoreDefaultsButton() -> NSButton {
        let button = NSButton(title: t("恢复默认顺序…", "Restore Default Order…"), target: self,
                              action: #selector(confirmRestoreDefaultOrder))
        button.bezelStyle = .rounded
        button.toolTip = "恢复默认词典顺序，不改变启用、状态或索引。"
        button.setAccessibilityLabel("恢复默认顺序")
        return button
    }

    private func configuredRemoveButton() -> NSButton {
        removeButton.title = t("移除词典…", "Remove Dictionary…")
        removeButton.target = self
        removeButton.action = #selector(confirmRemoveSelectedDictionary)
        removeButton.bezelStyle = .rounded
        removeButton.setAccessibilityLabel("移除所选词典")
        return removeButton
    }

    private var selectedDictionary: DictionaryDescriptor? {
        let row = tableView.selectedRow
        guard row >= 0, row < dictionaries.count else { return nil }
        return dictionaries[row]
    }

    private func t(_ chinese: String, _ english: String) -> String {
        AppLocalization.text(chinese, english)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionActions()
    }

    private func updateSelectionActions() {
        guard let selectedDictionary else {
            moveUpButton.isEnabled = false
            moveDownButton.isEnabled = false
            moveUpButton.toolTip = "请先在词典列表中选择一本词典。"
            moveDownButton.toolTip = "请先在词典列表中选择一本词典。"
            removeButton.isEnabled = false
            removeButton.toolTip = "选择一个托管词典后可以移除。"
            return
        }
        moveUpButton.isEnabled = DictionaryCatalogOrdering.canMove(
            selectedDictionary.dictionaryID, direction: .up, in: catalog
        )
        moveDownButton.isEnabled = DictionaryCatalogOrdering.canMove(
            selectedDictionary.dictionaryID, direction: .down, in: catalog
        )
        moveUpButton.toolTip = moveUpButton.isEnabled
            ? "在统一查询顺序中将所选词典上移。"
            : "所选词典已经位于查询顺序的最前面。"
        moveDownButton.toolTip = moveDownButton.isEnabled
            ? "在统一查询顺序中将所选词典下移。"
            : "所选词典已经位于查询顺序的最后面。"
        let isRemoving = removingDictionaryID == selectedDictionary.dictionaryID ||
            removalCoordinator.isRemoving(selectedDictionary.dictionaryID)
        let hasActiveReverseWork = reverseCapabilityProbeTasks[
            selectedDictionary.dictionaryID
        ] != nil || reverseBuildDictionaryIDs.contains(selectedDictionary.dictionaryID)
        removeButton.isEnabled =
            (selectedDictionary.sourceKind == .managedLocal ||
             selectedDictionary.sourceKind == .openResource ||
             selectedDictionary.sourceKind == .legacyReference) && !isRemoving &&
                !hasActiveReverseWork
        if selectedDictionary.sourceKind == .legacyReference {
            removeButton.toolTip = hasActiveReverseWork
                ? "该词典仍有中文释义检测或反向索引任务，请先取消。"
                : "从 LocalDictionary 移除此旧登记；不会删除或修改原 MDX、MDD 或旧索引。"
        } else if isRemoving {
            removeButton.toolTip = "该词典正在安全移除。"
        } else if selectedDictionary.state == .indexing ||
                    indexCoordinator.activity?.dictionaryID == selectedDictionary.dictionaryID {
            removeButton.toolTip = "该词典正在建立索引，请先取消索引。"
        } else {
            removeButton.toolTip = "移除 App 托管的词典副本和独立索引，不修改最初导入的原文件。"
        }
    }

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < dictionaries.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(dictionaries[row].dictionaryID,
                       forType: Self.dictionaryPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation)
        -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView,
              let dictionaryID = info.draggingPasteboard.string(
                forType: Self.dictionaryPasteboardType
              ) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        do {
            _ = try DictionaryCatalogOrdering.moving(
                dictionaryID, toDisplayedRow: row, in: catalog
            )
            resetReorderHelp()
            return .move
        } catch {
            return []
        }
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let dictionaryID = info.draggingPasteboard.string(
            forType: Self.dictionaryPasteboardType
        ) else { return false }
        do {
            let updated = try DictionaryCatalogOrdering.moving(
                dictionaryID, toDisplayedRow: row, in: catalog
            )
            let saved = persistCatalogChange(updated, selectedID: dictionaryID,
                                             failureTitle: "无法保存词典顺序")
            if saved {
                ManualEvidenceRecorder.shared.record("dictionaryOrderChanged", strings: [
                    "dictionaryID": dictionaryID,
                    "resultKind": "success"
                ], integers: ["displayedRow": Int64(row)])
            }
            return saved
        } catch {
            showError(title: "无法调整词典顺序", operation: .saveOrdering, error: error)
            return false
        }
    }

    func tableView(_ tableView: NSTableView,
                   draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        resetReorderHelp()
    }

    private func resetReorderHelp() {
        reorderHelpLabel.stringValue = "拖动或使用上下按钮调整统一查询顺序；同等匹配质量按此顺序显示。"
        reorderHelpLabel.textColor = .secondaryLabelColor
    }

    @objc private func moveSelectedUp() {
        moveSelected(direction: .up)
    }

    @objc private func moveSelectedDown() {
        moveSelected(direction: .down)
    }

    private func moveSelected(direction: DictionaryMoveDirection) {
        guard let selectedDictionary else { return }
        do {
            let updated = try DictionaryCatalogOrdering.moving(
                selectedDictionary.dictionaryID, direction: direction, in: catalog
            )
            if persistCatalogChange(updated,
                                    selectedID: selectedDictionary.dictionaryID,
                                    failureTitle: "无法保存词典顺序") {
                ManualEvidenceRecorder.shared.record("dictionaryOrderChanged", strings: [
                    "dictionaryID": selectedDictionary.dictionaryID,
                    "direction": String(describing: direction),
                    "resultKind": "success"
                ])
            }
        } catch {
            showError(title: "无法调整词典顺序", operation: .saveOrdering, error: error)
        }
    }

    @objc private func confirmRestoreDefaultOrder() {
        guard let window else { return }
        let updated = DictionaryCatalogOrdering.restoringDefaults(in: catalog)
        guard updated != catalog else {
            showInformation(title: "顺序无需恢复", message: "当前已经是默认顺序。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "恢复默认顺序？"
        alert.informativeText = "恢复默认词典顺序，不改变启用状态、索引或词典内容。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "恢复默认顺序")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            _ = self.persistCatalogChange(updated, selectedID: nil,
                                          failureTitle: "无法恢复默认顺序")
        }
    }

    @objc private func confirmRemoveSelectedDictionary() {
        guard let window, let dictionary = selectedDictionary else { return }
        if dictionary.sourceKind == .legacyReference {
            guard reverseCapabilityProbeTasks[dictionary.dictionaryID] == nil,
                  !reverseBuildDictionaryIDs.contains(dictionary.dictionaryID) else {
                showInformation(title: "请先结束当前任务",
                                message: "该词典仍有检测或反向索引任务，请先取消并等待任务结束。")
                return
            }
            let alert = NSAlert()
            alert.messageText = "从 LocalDictionary 移除“\(dictionary.displayName)”？"
            alert.informativeText =
                "只移除 App 内的旧配置登记并停止查询；原 MDX、MDD、旧正向索引和 local.json 均不会删除或修改。之后可选择原 MDX，按新导入流程重新建立查询及中文反向索引。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "移除 App 登记")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.retireLegacyRegistration(dictionaryID: dictionary.dictionaryID)
            }
            return
        }
        guard dictionary.sourceKind == .managedLocal ||
              dictionary.sourceKind == .openResource else {
            showInformation(title: "不能移除旧配置词典",
                            message: "该词典来自旧配置引用。LocalDictionary 不会删除其原始文件，可通过停用来停止查询。")
            return
        }
        guard dictionary.state != .indexing,
              indexCoordinator.activity?.dictionaryID != dictionary.dictionaryID else {
            showInformation(title: "请先取消索引",
                            message: "该词典正在建立索引，请先取消索引，并等待任务真正结束。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "移除词典“\(dictionary.displayName)”？"
        alert.informativeText = dictionary.sourceKind == .openResource
            ? "将经过现有 receipt、Catalog identity 和受控 inventory 边界移除该开放资源及其索引。身份不明文件不会被删除。此操作不可撤销。"
            : "将从 LocalDictionary 中移除该词典，并删除 App 托管目录中的 MDX 副本和 SQLite 索引。用户最初选择导入的原始文件不会被修改；已保存的收藏正文快照仍可阅读。此操作不可撤销。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "移除词典")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.performRemoval(dictionaryID: dictionary.dictionaryID)
        }
    }

    /// Retires only the App registration.  External legacy dictionary and index paths are never
    /// passed to the managed removal worker and are never unlinked.
    private func retireLegacyRegistration(dictionaryID: String) {
        ManualEvidenceRecorder.shared.record("legacyDictionaryRemovalRequested", strings: [
            "dictionaryID": dictionaryID,
            "sourceOwnership": DictionaryStorageOwnership.externalReference.rawValue
        ])
        let updated: DictionaryCatalog
        do {
            // This is a lifecycle mutation, not an ordering-only change.  Start from the latest
            // durable Catalog and persist every tombstone field atomically so local.json cannot
            // resurrect the registration after relaunch.
            let mutation = try catalogStore.mutate { latest, _ in
                latest = try LegacyDictionaryRegistrationRetirement.retiring(
                    dictionaryID: dictionaryID, in: latest
                )
            }
            updated = mutation.catalog
        } catch {
            ManualEvidenceRecorder.shared.record("legacyDictionaryRemovalCompleted", strings: [
                "dictionaryID": dictionaryID,
                "result": "catalogSaveFailed"
            ])
            showInformation(title: "无法移除旧配置登记",
                            message: (error as? LocalizedError)?.errorDescription ??
                                "该旧配置登记当前无法移除。")
            return
        }
        update(catalog: updated)
        onCatalogChanged(updated)
        ManualEvidenceRecorder.shared.record("legacyDictionaryRemovalCompleted", strings: [
            "dictionaryID": dictionaryID,
            "result": "retiredRegistration"
        ], booleans: ["externalFilesTouched": false])
        showInformation(
            title: "旧词典登记已移除",
            message: "已停止使用该旧配置词典；原 MDX、MDD、旧索引和 local.json 均保持不变。现在可以选择原 MDX，按新的导入流程重新建立索引。"
        )
    }

    private func performRemoval(dictionaryID: String) {
        guard removingDictionaryID == nil else { return }
        let isOpenResource = catalog.dictionaries.first(where: {
            $0.dictionaryID == dictionaryID
        })?.storageOwnership == .appManagedOpenResource
        let openResourceID = catalog.dictionaries.first(where: {
            $0.dictionaryID == dictionaryID
        })?.openResourceMetadata?.resourceID
        if isOpenResource {
            let descriptor = catalog.dictionaries.first { $0.dictionaryID == dictionaryID }
            ManualEvidenceRecorder.shared.record("resourceRemoveClicked", strings: [
                "resourceID": descriptor?.openResourceMetadata?.resourceID ?? "unknown",
                "sourceOwnership": descriptor?.storageOwnership.rawValue ?? "unknown"
            ])
        }
        removingDictionaryID = dictionaryID
        tableView.reloadData()
        updateSelectionActions()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.removalCoordinator.remove(dictionaryID: dictionaryID)
            self.removingDictionaryID = nil
            self.update(catalog: self.removalCoordinator.catalog)
            switch result {
            case .removed(let cleanupDeferred):
                if let openResourceID {
                    ManualEvidenceRecorder.shared.record("resourceRemoved", strings: [
                        "resourceID": openResourceID,
                        "resultKind": "success"
                    ], booleans: ["cleanupDeferred": cleanupDeferred])
                }
                self.showInformation(
                    title: "词典已移除",
                    message: isOpenResource
                        ? (cleanupDeferred
                            ? "开放资源已从列表移除；托管文件将在下次启动时继续清理。"
                            : "开放资源、派生索引和安装记录已移除。")
                        : (cleanupDeferred
                            ? "词典已从列表移除；托管文件将在下次启动时继续安全清理。原始导入文件未修改。"
                            : "App 托管的词典副本和索引已移除；原始导入文件未修改。")
                )
            case .failed(let error):
                if let openResourceID {
                    ManualEvidenceRecorder.shared.record("resourceRemovalFailed", strings: [
                        "resourceID": openResourceID,
                        "resultKind": "failure",
                        "typedReason": String(describing: error)
                    ])
                }
                if isOpenResource {
                    self.showInformation(
                        title: "无法移除开放资源",
                        message: "未能安全移除该开放资源。请重新打开词典管理后重试；不会触碰任何用户导入文件。"
                    )
                } else {
                    self.showError(title: "无法移除词典", operation: .removeDictionary,
                                   error: error)
                }
            }
            self.updateSelectionActions()
        }
    }

    @discardableResult
    private func persistCatalogChange(_ updated: DictionaryCatalog,
                                      selectedID: String?,
                                      failureTitle: String) -> Bool {
        guard updated != catalog else { return true }
        let previous = catalog
        do {
            let saved = try orderCoordinator.save(updated)
            update(catalog: saved)
            if let selectedID { selectDictionary(id: selectedID) }
            onCatalogChanged(saved)
            return true
        } catch {
            update(catalog: previous)
            if let selectedID { selectDictionary(id: selectedID) }
            let operation: DictionaryManagerPresentation.ErrorOperation =
                failureTitle == "无法恢复默认顺序" ? .restoreOrdering : .saveOrdering
            showError(title: failureTitle, operation: operation, error: error)
            return false
        }
    }

    @objc func showResourceCenter() {
        guard let window else { return }
        let preferences = LanguagePreferencesStore.shared.load()
        resourceCenterController.updateLanguagePair(
            nativeLanguageCode: preferences.nativeLanguage.rawValue,
            learningLanguageCode: preferences.learningLanguage.rawValue
        )
        if let existing = resourceCenterSheet {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let content = ResourceCenterViewController(
            controller: resourceCenterController,
            onClose: { [weak self] in self?.closeResourceCenter() }
        )
        let sheet = ResourceCenterSheetWindow(contentViewController: content)
        sheet.title = "开放资源中心"
        sheet.styleMask = [.titled, .closable, .resizable]
        sheet.minSize = NSSize(width: 760, height: 500)
        sheet.setContentSize(NSSize(width: 900, height: 620))
        resourceCenterSheet = sheet
        sheet.requestClose = { [weak self] in self?.closeResourceCenter() }
        window.beginSheet(sheet) { [weak self] _ in
            self?.resourceCenterSheet = nil
        }
        resourceCenterController.refresh()
    }

    @objc private func resourceLanguagePreferencesDidChange(_ notification: Notification) {
        let preferences = (notification.userInfo?["preferences"] as? LanguagePreferences)
            ?? LanguagePreferencesStore.shared.load()
        resourceCenterController.updateLanguagePair(
            nativeLanguageCode: preferences.nativeLanguage.rawValue,
            learningLanguageCode: preferences.learningLanguage.rawValue
        )
        if resourceCenterSheet != nil { resourceCenterController.refresh() }
    }

    private func closeResourceCenter() {
        guard let sheet = resourceCenterSheet else { return }
        resourceCenterController.presentationWillClose()
        resourceCenterSheet = nil
        sheet.requestClose = nil
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }

    @objc private func enabledStateChanged(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let index = catalog.dictionaries.firstIndex(where: {
                  $0.dictionaryID == identifier &&
                      ($0.sourceKind == .managedLocal ||
                       $0.sourceKind == .openResource ||
                       $0.sourceKind == .legacyReference)
              }) else { return }
        let previous = catalog
        let requestedEnabled = sender.state == .on
        ManualEvidenceRecorder.shared.record("dictionaryEnableChanged", strings: [
            "dictionaryID": identifier,
            "sourceOwnership": catalog.dictionaries[index].storageOwnership.rawValue
        ], booleans: ["enabled": requestedEnabled])
        do {
            let timestamp = Date()
            let mutation = try catalogStore.mutate { latest, _ in
                guard let latestIndex = latest.dictionaries.firstIndex(where: {
                    $0.dictionaryID == identifier && !$0.isRetiredLegacyRegistration
                }) else { throw DictionaryCatalogOrderingError.dictionaryNotFound }
                latest.dictionaries[latestIndex].enabled = requestedEnabled
                latest.dictionaries[latestIndex].updatedAt = timestamp
                latest.updatedAt = timestamp
            }
            update(catalog: mutation.catalog)
            onCatalogChanged(mutation.catalog)
        } catch {
            update(catalog: previous)
            showError(title: "无法保存启用状态", operation: .saveEnabledState,
                      error: error)
        }
    }

    private func combinedActionView(for dictionary: DictionaryDescriptor) -> NSView {
        let forward = forwardIndexActionButton(for: dictionary)
        let reverse = reverseIndexActionButton(for: dictionary)
        let detail = NSButton(title: "详情", target: self,
                              action: #selector(showDictionaryDetails(_:)))
        detail.identifier = NSUserInterfaceItemIdentifier(dictionary.dictionaryID)
        detail.bezelStyle = .rounded
        detail.controlSize = .small
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.heightAnchor.constraint(equalToConstant: 22).isActive = true
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentHuggingPriority(.defaultHigh, for: .vertical)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        detail.setAccessibilityLabel("查看“\(dictionary.displayName)”索引详情")
        let detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            detail.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            detailContainer.widthAnchor.constraint(equalTo: detail.widthAnchor),
            detailContainer.heightAnchor.constraint(equalToConstant: 22)
        ])
        detailContainer.setContentHuggingPriority(.required, for: .horizontal)
        detailContainer.setContentHuggingPriority(.required, for: .vertical)
        detailContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        let firstRow = NSStackView(views: [reverse, detailContainer])
        firstRow.orientation = .horizontal
        firstRow.alignment = .centerY
        firstRow.spacing = 5
        firstRow.setHuggingPriority(.required, for: .horizontal)
        firstRow.setHuggingPriority(.required, for: .vertical)
        firstRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let values = forward.map { [firstRow, $0] } ?? [firstRow]
        let stack = NSStackView(views: values)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func forwardIndexActionButton(for dictionary: DictionaryDescriptor) -> NSButton? {
        guard let presentation = DictionaryManagerPresentation.indexAction(
            for: dictionary, activity: presentationActivity(for: dictionary)
        ), presentation.action != .none else { return nil }
        let selector: Selector?
        switch presentation.action {
        case .start, .retry: selector = #selector(startIndexing(_:))
        case .cancel: selector = #selector(cancelIndexing(_:))
        case .none: selector = nil
        }
        let button = NSButton(title: presentation.title, target: self, action: selector)
        button.isEnabled = presentation.isEnabled
        button.toolTip = presentation.toolTip
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(dictionary.dictionaryID)
        button.setAccessibilityLabel("\(presentation.title)：“\(dictionary.displayName)”")
        button.setAccessibilityHelp(presentation.toolTip)
        return button
    }

    private func reverseIndexActionButton(for dictionary: DictionaryDescriptor) -> NSButton {
        let sourceExists = reverseSources.contains { $0.dictionaryID == dictionary.dictionaryID }
        let capability = reverseCapability(dictionary.dictionaryID)
        let isProbingCapability = reverseCapabilityProbeTasks[dictionary.dictionaryID] != nil
        let canProbeCapability = dictionary.sourceKind == .managedLocal &&
            dictionary.storageOwnership == .appManagedImported &&
            dictionary.state == .ready && dictionary.publishedIndexIdentity != nil
        let progress = reverseProgress[dictionary.dictionaryID]
        let stage = progress?.stage ??
            reverseStoredStates[dictionary.dictionaryID]?.stage ?? .notBuilt
        let title: String
        let selector: Selector?
        switch stage {
        case .queued, .readingEntries, .writingIndex, .optimizing, .validating,
             .publishing:
            title = "取消反向索引"
            selector = #selector(cancelReverseIndex(_:))
        case .cancelling:
            title = "正在取消"
            selector = nil
        case _ where capability == .unknownNeedsProbe:
            title = isProbingCapability
                ? "取消完整检测"
                : dictionary.reverseCapabilityProbe == .unknown
                    ? "完整检测中文释义" : "检测中文释义"
            selector = isProbingCapability
                ? #selector(cancelReverseCapabilityProbe(_:))
                : #selector(probeReverseCapability(_:))
        case .ready where capability == .supported:
            title = "重建反向索引"
            selector = #selector(buildReverseIndex(_:))
        case .notApplicable:
            title = capability == .supported
                ? ReverseIndexCapability.noChineseDefinitions.displayName
                : capability.displayName
            selector = nil
        case .ready:
            title = capability.displayName
            selector = nil
        case .failed, .cancelled:
            title = capability == .supported ? "重试反向索引" : capability.displayName
            selector = capability == .supported ? #selector(buildReverseIndex(_:)) : nil
        case .stale:
            title = capability == .supported ? "重建反向索引" : capability.displayName
            selector = capability == .supported ? #selector(buildReverseIndex(_:)) : nil
        case .notBuilt:
            title = capability == .supported ? "建立反向索引" : capability.displayName
            selector = capability == .supported ? #selector(buildReverseIndex(_:)) : nil
        }
        let button = NSButton(title: title, target: self, action: selector)
        button.identifier = NSUserInterfaceItemIdentifier(dictionary.dictionaryID)
        button.bezelStyle = .rounded
        button.controlSize = .small
        if capability == .unknownNeedsProbe {
            button.isEnabled = canProbeCapability && selector != nil
            button.toolTip = isProbingCapability
                ? "取消本次完整检测；普通正向查询不受影响。"
                : dictionary.reverseCapabilityProbe == .unknown
                    ? "自动抽样尚未得出结论；完整扫描到可靠中文词义或词典末尾，不会建立反向索引。"
                    : "完整扫描到可靠中文词义或词典末尾；不会建立反向索引。"
        } else {
            button.isEnabled = sourceExists && selector != nil
            button.toolTip = sourceExists && capability == .supported
                ? "只建立独立的中文反向 sidecar，不修改这本词典的正向索引。"
                : "能力判断：\(capability.displayName)。"
        }
        button.setAccessibilityLabel("\(title)：“\(dictionary.displayName)”")
        button.setAccessibilityHelp(button.toolTip)
        return button
    }

    private func refreshReverseInventory() {
        let sources = reverseSources
        let rootURL = reverseInventoryRootURL
        Task { @MainActor [weak self] in
            let states = await Task.detached(priority: .utility) {
                if let rootURL {
                    return ReverseIndexInventory.inspect(
                        sources: sources, rootURL: rootURL
                    )
                }
                return ReverseIndexInventory.inspect(sources: sources)
            }.value
            guard let self, self.reverseSources.map(\.dictionaryID) ==
                    sources.map(\.dictionaryID) else { return }
            self.reverseStoredStates = Dictionary(uniqueKeysWithValues: states.map {
                ($0.dictionaryID, $0)
            })
            let descriptors = states.compactMap(\.descriptor)
            await self.reverseLookupService.replaceDescriptors(descriptors)
            await self.reverseLookupService.replaceBuildStages(
                Dictionary(uniqueKeysWithValues: states.map { ($0.dictionaryID, $0.stage) })
            )
            self.tableView.reloadData()
            self.updateReverseBuildAllState()
        }
    }

    private func updateReverseBuildAllState() {
        let hasEligible = reverseSources.contains { source in
            guard source.reverseCapability.isBuildEligible else { return false }
            let stage = reverseProgress[source.dictionaryID]?.stage ??
                reverseStoredStates[source.dictionaryID]?.stage ?? .notBuilt
            return stage != .ready
        }
        buildAllReverseButton.isEnabled = reverseBuildTask == nil && hasEligible
        buildAllReverseButton.title = reverseBuildTask == nil
            ? "建立全部中文反向索引" : "取消全部反向索引"
        if reverseBuildTask != nil { buildAllReverseButton.isEnabled = true }
    }

    @objc private func probeReverseCapability(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue else { return }
        startReverseCapabilityProbe(dictionaryID: dictionaryID)
    }

    @objc private func cancelReverseCapabilityProbe(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue,
              let task = reverseCapabilityProbeTasks[dictionaryID] else { return }
        task.cancel()
        tableView.reloadData()
    }

    private func startReverseCapabilityProbe(dictionaryID: String) {
        guard reverseCapabilityProbeTasks[dictionaryID] == nil,
              let descriptor = dictionaries.first(where: {
                  $0.dictionaryID == dictionaryID
              }),
              descriptor.sourceKind == .managedLocal,
              descriptor.storageOwnership == .appManagedImported,
              descriptor.state == .ready,
              let publicationID = descriptor.publishedIndexIdentity?.indexPublicationID
        else { return }

        let originalProbe = descriptor.reverseCapabilityProbe
        let runner = reverseCapabilityProbeRunner
        ManualEvidenceRecorder.shared.record("reverseCapabilityProbeStarted", strings: [
            "dictionaryID": dictionaryID,
            "publicationID": publicationID,
            "previousState": originalProbe?.rawValue ?? "notTested",
            "trigger": "userFullScan",
            "mode": ManagedReverseCapabilityProbeMode.full.rawValue
        ])
        reverseCapabilityProbeTasks[dictionaryID] = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) {
                runner(descriptor, .full)
            }
            let report = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            self.reverseCapabilityProbeTasks[dictionaryID] = nil
            self.tableView.reloadData()
            guard !Task.isCancelled else {
                ManualEvidenceRecorder.shared.record(
                    "reverseCapabilityProbeCompleted",
                    strings: [
                        "dictionaryID": dictionaryID,
                        "publicationID": publicationID,
                        "result": "cancelled",
                        "typedReason": ManagedReverseCapabilityProbeTerminalReason.cancelled.rawValue,
                        "mode": ManagedReverseCapabilityProbeMode.full.rawValue
                    ], integers: [
                        "processedEntryCount": Int64(clamping: report.processedEntryCount)
                    ]
                )
                return
            }
            guard let index = self.catalog.dictionaries.firstIndex(where: {
                guard $0.dictionaryID == dictionaryID,
                      $0.publishedIndexIdentity?.indexPublicationID == publicationID else {
                    return false
                }
                // A launch-time 512-entry sample can finish while the user's explicit full scan
                // is running. Its inconclusive nil -> unknown update must not discard the later,
                // conclusive full result. Any other state change remains stale and is rejected.
                return $0.reverseCapabilityProbe == originalProbe ||
                    (report.mode == .full && originalProbe == nil &&
                     $0.reverseCapabilityProbe == .unknown)
            }) else {
                ManualEvidenceRecorder.shared.record(
                    "reverseCapabilityProbeCompleted",
                    strings: [
                        "dictionaryID": dictionaryID,
                        "publicationID": publicationID,
                        "result": "staleResultDiscarded",
                        "typedReason": "publicationChanged",
                        "mode": report.mode.rawValue
                    ]
                )
                return
            }

            var updated = self.catalog
            updated.dictionaries[index].reverseCapabilityProbe = report.result
            updated.dictionaries[index].updatedAt = Date()
            updated.updatedAt = Date()
            do {
                try self.catalogStore.save(updated)
                let updatedDescriptor = updated.dictionaries[index]
                self.reverseSources = self.reverseSources.map { source in
                    source.dictionaryID == dictionaryID
                        ? ReverseDictionarySource(managed: updatedDescriptor) : source
                }
                self.update(catalog: updated)
                self.onCatalogChanged(updated)
                ManualEvidenceRecorder.shared.record(
                    "reverseCapabilityProbeCompleted",
                    strings: [
                        "dictionaryID": dictionaryID,
                        "publicationID": publicationID,
                        "result": report.result.rawValue,
                        "typedReason": report.terminalReason.rawValue,
                        "mode": report.mode.rawValue
                    ], integers: [
                        "processedEntryCount": Int64(clamping: report.processedEntryCount),
                        "expectedEntryCount": Int64(clamping: report.expectedEntryCount ?? 0),
                        "usableEntryCount": Int64(clamping: report.usableEntryCount),
                        "usableNativeGlossCount": Int64(clamping: report.usableNativeGlossCount),
                        "skippedEntryCount": Int64(clamping: report.skippedEntryCount)
                    ]
                )
                self.presentReverseCapabilityProbeResult(
                    report, dictionaryID: dictionaryID,
                    dictionaryName: updatedDescriptor.displayName,
                    publicationID: publicationID
                )
            } catch {
                ManualEvidenceRecorder.shared.record(
                    "reverseCapabilityProbeCompleted",
                    strings: [
                        "dictionaryID": dictionaryID,
                        "publicationID": publicationID,
                        "result": "catalogSaveFailed",
                        "typedReason": report.terminalReason.rawValue,
                        "mode": report.mode.rawValue
                    ]
                )
                self.showInformation(
                    title: "检测结果未能保存",
                    message: "中文释义检测已停止；词典和查询索引均未修改，请稍后重试。"
                )
            }
        }
        tableView.reloadData()
    }

    private func presentReverseCapabilityProbeResult(
        _ report: ManagedReverseCapabilityProbeReport,
        dictionaryID: String,
        dictionaryName: String,
        publicationID: String
    ) {
        guard let window, window.isVisible else { return }
        let alert = Self.reverseCapabilityProbeResultAlert(
            report, dictionaryName: dictionaryName
        )
        alert.beginSheetModal(for: window) { [weak self] response in
            guard report.result == .supported,
                  response == .alertFirstButtonReturn else { return }
            self?.requestReverseBuild(
                dictionaryID: dictionaryID,
                expectedPublicationID: publicationID,
                trigger: "probeResult"
            )
        }
    }

    static func reverseCapabilityProbeResultAlert(
        _ report: ManagedReverseCapabilityProbeReport,
        dictionaryName: String
    ) -> NSAlert {
        let processed = report.expectedEntryCount.map {
            "已检查 \(report.processedEntryCount) / \($0) 个词条。"
        } ?? "已检查 \(report.processedEntryCount) 个词条。"
        let alert = NSAlert()
        alert.alertStyle = report.result == .unknown ? .warning : .informational
        switch report.result {
        case .supported:
            alert.messageText = "检测到可用中文释义"
            alert.informativeText =
                "\(dictionaryName) 支持中文反向查询。\(processed) 现在可以建立独立的中文反向索引；普通正向索引不会被修改。"
            alert.addButton(withTitle: "立即建立中文反向索引")
            alert.addButton(withTitle: "稍后")
        case .noUsableNativeGloss:
            alert.messageText = "未检测到可用中文释义"
            alert.informativeText =
                "已完整检查 \(report.processedEntryCount) 个词条。该词典仍可正常用于正向查询，但无需建立中文反向索引。"
            alert.addButton(withTitle: "好")
        case .unsupportedFormatter:
            alert.messageText = "当前格式暂不支持中文反向查询"
            alert.informativeText = "检测已完成；普通正向查询不受影响。"
            alert.addButton(withTitle: "好")
        case .unknown:
            alert.messageText = "中文释义检测未能完成"
            alert.informativeText =
                "\(processed) 停止阶段：\(Self.probeTerminalReasonText(report.terminalReason))。普通正向查询不受影响，可稍后重试。"
            alert.addButton(withTitle: "好")
        }
        return alert
    }

    private static func probeTerminalReasonText(
        _ reason: ManagedReverseCapabilityProbeTerminalReason
    ) -> String {
        switch reason {
        case .cancelled, .enumerationCancelled: return "已取消"
        case .runtimeValidationFailed: return "查询索引校验失败"
        case .reopenFailed: return "无法重新打开查询索引"
        case .enumerationUnsupported: return "当前索引不支持词条枚举"
        case .readFailed: return "读取词条失败"
        case .sampleLimitReached: return "自动抽样未得出结论"
        case .ineligibleDescriptor: return "词典状态不适合检测"
        case .unsupportedCapabilityState, .extractorUnavailable,
             .unsupportedFormatter: return "当前格式暂不支持"
        case .formatterDeclaresNoUsableNativeGloss,
             .endOfFileNoUsableNativeGloss: return "未检测到可用中文释义"
        case .usableNativeGlossFound: return "已检测到可用中文释义"
        }
    }

    @objc private func buildAllReverseIndexes() {
        if reverseBuildTask != nil || reverseIndexCoordinator.currentTask != nil {
            cancelActiveReverseBuild()
            return
        }
        let pending = reverseSources.filter { source in
            guard source.reverseCapability.isBuildEligible else { return false }
            let stage = reverseStoredStates[source.dictionaryID]?.stage ?? .notBuilt
            return stage != .ready
        }
        guard !pending.isEmpty else {
            let completed = reverseSources.filter {
                $0.reverseCapability == .supported &&
                    reverseStoredStates[$0.dictionaryID]?.stage == .ready
            }.count
            let noNeed = reverseSources.filter {
                [.nativeChineseLookup, .derivedReady, .notApplicable,
                 .noChineseDefinitions].contains($0.reverseCapability) ||
                    reverseStoredStates[$0.dictionaryID]?.stage == .notApplicable
            }.count
            let unsupported = reverseSources.count - completed - noNeed
            showInformation(title: "中文反向索引已完成",
                            message: "已完成：\(completed)；无需建立：\(noNeed)；" +
                                "当前不支持：\(max(0, unsupported))；失败：0。")
            return
        }
        ManualEvidenceRecorder.shared.record("reverseBuildClicked", strings: [
            "scope": "all"
        ], integers: ["dictionaryCount": Int64(pending.count)])
        startReverseBuild(pending, summarizesAllCapabilities: true)
    }

    @objc private func buildReverseIndex(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue else { return }
        requestReverseBuild(dictionaryID: dictionaryID, trigger: "rowAction")
    }

    private func requestReverseBuild(
        dictionaryID: String,
        expectedPublicationID: String? = nil,
        trigger: String
    ) {
        if let expectedPublicationID {
            guard dictionaries.first(where: { $0.dictionaryID == dictionaryID })?
                .publishedIndexIdentity?.indexPublicationID == expectedPublicationID else {
                showInformation(title: "词典索引已经更新",
                                message: "请重新检测中文释义后再建立反向索引。")
                return
            }
        }
        guard let source = reverseSources.first(where: {
            $0.dictionaryID == dictionaryID
        }) else {
            showInformation(title: "暂时无法建立中文反向索引",
                            message: "词典查询索引尚未发布到当前窗口，请关闭并重新打开词典管理后重试。")
            return
        }
        guard reverseBuildTask == nil, reverseIndexCoordinator.currentTask == nil else {
            showInformation(title: "已有反向索引任务进行中",
                            message: "反向索引按词典串行建立；可以先取消当前任务。")
            return
        }
        guard source.reverseCapability.isBuildEligible else {
            showInformation(title: "无需建立中文反向索引",
                            message: source.reverseCapability.displayName)
            return
        }
        ManualEvidenceRecorder.shared.record("reverseBuildClicked", strings: [
            "dictionaryID": dictionaryID,
            "scope": "single",
            "trigger": trigger
        ])
        startReverseBuild([source])
    }

    @objc private func cancelReverseIndex(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue,
              reverseProgress[dictionaryID] != nil else { return }
        cancelActiveReverseBuild()
    }

    private func cancelActiveReverseBuild() {
        ManualEvidenceRecorder.shared.record("reverseBuildCancelled", strings: [
            "operationState": "cancelled"
        ])
        reverseBuildTask?.cancel()
        reverseIndexCoordinator.cancel()
        updateReverseBuildAllState()
    }

    private func startReverseBuild(_ sources: [ReverseDictionarySource],
                                   summarizesAllCapabilities: Bool = false) {
        guard !sources.isEmpty else { return }
        reverseBuildDictionaryIDs = Set(sources.map(\.dictionaryID))
        updateSelectionActions()
        reverseBuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateReverseBuildAllState()
            defer {
                self.reverseBuildTask = nil
                self.reverseBuildDictionaryIDs.removeAll()
                self.updateReverseBuildAllState()
                self.updateSelectionActions()
            }
            do {
                let descriptors = try await self.reverseIndexCoordinator.build(
                    sources
                ) { [weak self] snapshot in
                    guard let self else { return }
                    self.reverseProgress = Dictionary(uniqueKeysWithValues:
                        snapshot.dictionaries.map { ($0.dictionaryID, $0) })
                    Task {
                        await self.reverseLookupService.replaceBuildStages(
                            Dictionary(uniqueKeysWithValues:
                                snapshot.dictionaries.map { ($0.dictionaryID, $0.stage) })
                        )
                    }
                    self.tableView.reloadData()
                }
                await self.reverseLookupService.mergeDescriptors(descriptors)
                let inventorySources = self.reverseSources
                let inventoryRootURL = self.reverseInventoryRootURL
                let states = await Task.detached(priority: .utility) {
                    if let inventoryRootURL {
                        return ReverseIndexInventory.inspect(
                            sources: inventorySources, rootURL: inventoryRootURL
                        )
                    }
                    return ReverseIndexInventory.inspect(sources: inventorySources)
                }.value
                self.reverseStoredStates = Dictionary(uniqueKeysWithValues: states.map {
                    ($0.dictionaryID, $0)
                })
                let terminal = self.reverseIndexCoordinator.latestProgress?.dictionaries.filter {
                    [.failed, .cancelled, .stale, .notApplicable].contains($0.stage)
                } ?? []
                self.reverseProgress = Dictionary(uniqueKeysWithValues: terminal.map {
                    ($0.dictionaryID, $0)
                })
                self.tableView.reloadData()
                if summarizesAllCapabilities {
                    #if !REVERSE_INDEX_CONTROLLER_TESTING
                    let stateByID = Dictionary(uniqueKeysWithValues: states.map {
                        ($0.dictionaryID, $0.stage)
                    })
                    var completed = 0
                    var noNeed = 0
                    var unsupported = 0
                    var failed = 0
                    for source in self.reverseSources {
                        switch source.reverseCapability {
                        case .supported:
                            switch stateByID[source.dictionaryID] ?? .notBuilt {
                            case .ready: completed += 1
                            case .notApplicable: noNeed += 1
                            default: failed += 1
                            }
                        case .nativeChineseLookup, .derivedReady, .notApplicable,
                             .noChineseDefinitions:
                            noNeed += 1
                        case .unsupportedFormatter, .unsupportedGlossExtraction,
                             .enumerationUnavailable,
                             .unknownNeedsProbe:
                            unsupported += 1
                        }
                    }
                    self.showInformation(
                        title: failed == 0 ? "中文反向索引处理完成" : "中文反向索引部分完成",
                        message: "已完成：\(completed)；无需建立：\(noNeed)；" +
                            "当前不支持：\(unsupported)；失败：\(failed)。"
                    )
                    #endif
                }
            } catch {
                if error as? ReverseIndexError != .cancelled {
                    self.showInformation(
                        title: "中文反向索引未完成",
                        message: (error as? LocalizedError)?.errorDescription ??
                            "建立失败，可查看对应词典详情后重试。"
                    )
                }
                self.tableView.reloadData()
            }
        }
    }

    #if REVERSE_INDEX_CONTROLLER_TESTING
    /// Test-only entry point: materialize the production action cell and click its real AppKit
    /// button. This keeps the complete row -> target/action -> controller -> runtime path intact.
    func triggerReverseIndexRowActionForTesting(dictionaryID: String) -> Bool {
        guard reverseSources.contains(where: { $0.dictionaryID == dictionaryID }),
              let row = dictionaries.firstIndex(where: {
                  $0.dictionaryID == dictionaryID
              }) else {
            return false
        }
        let actionColumn = tableView.column(withIdentifier: .init(Column.action.rawValue))
        guard actionColumn >= 0,
              let actionView = tableView.view(
                atColumn: actionColumn, row: row, makeIfNecessary: true
              ) else { return false }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
        }
        guard let button = buttons(in: actionView).first(where: {
            $0.identifier?.rawValue == dictionaryID &&
                $0.action == #selector(buildReverseIndex(_:))
        }) else { return false }
        button.performClick(nil)
        return reverseBuildTask != nil
    }

    func waitForReverseIndexActionForTesting() async {
        while reverseBuildTask != nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func triggerReverseBuildAllForTesting() async -> Bool {
        while reverseStoredStates.count < reverseSources.count {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        buildAllReverseButton.performClick(nil)
        return reverseBuildTask != nil
    }

    func reverseProgressForTesting(dictionaryID: String)
        -> ReverseIndexDictionaryProgress? {
        reverseProgress[dictionaryID]
    }
    #endif

    #if OPEN_RESOURCE_UI_TESTING
    func waitForReverseCapabilityProbeForTesting(dictionaryID: String) async {
        while reverseCapabilityProbeTasks[dictionaryID] != nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    #endif

    @objc private func showDictionaryDetails(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue,
              let dictionary = dictionaries.first(where: {
                  $0.dictionaryID == dictionaryID
              }) else { return }
        let entryCount = dictionary.indexMetadata.entryCount.map(String.init) ?? "—"
        let forwardSize = dictionary.indexMetadata.indexFileSize.map {
            ByteCountFormatter.string(
                fromByteCount: Int64(clamping: $0), countStyle: .file
            )
        } ?? "—"
        let forwardDate = dictionary.indexMetadata.indexedAt.map {
            Self.dateFormatter.string(from: $0)
        } ?? "—"
        var detail = [
            "正向查询索引",
            DictionaryManagerPresentation.statusDetail(
                for: dictionary, activity: presentationActivity(for: dictionary)
            ),
            "词条数量：\(entryCount)",
            "正向索引大小：\(forwardSize)",
            "最近正向索引：\(forwardDate)",
            "",
            "中文反向索引",
            DictionaryManagerPresentation.reverseStatusDetail(
                reverseStoredStates[dictionaryID],
                progress: reverseProgress[dictionaryID],
                capability: reverseCapability(dictionaryID)
            )
        ]
        if dictionary.state == .failed,
           let failure = DictionaryManagerPresentation.safeIndexFailureMessage(
               indexCoordinator.failureMessage(for: dictionaryID)
           ) {
            detail.append(failure)
        }
        if dictionary.reverseCapabilityProbe == .unknown {
            detail.append("自动抽样最多检查 512 条，尚未得出结论；可执行一次完整检测。普通正向查询不受影响。")
        }
        let canProbe = reverseCapability(dictionaryID) == .unknownNeedsProbe &&
            dictionary.sourceKind == .managedLocal &&
            dictionary.storageOwnership == .appManagedImported &&
            dictionary.state == .ready && dictionary.publishedIndexIdentity != nil &&
            reverseCapabilityProbeTasks[dictionaryID] == nil
        guard canProbe, let window else {
            showInformation(title: dictionary.displayName,
                            message: detail.joined(separator: "\n"))
            return
        }
        let alert = NSAlert()
        alert.messageText = dictionary.displayName
        alert.informativeText = detail.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: dictionary.reverseCapabilityProbe == .unknown
            ? "完整检测中文释义" : "检测中文释义")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.startReverseCapabilityProbe(dictionaryID: dictionaryID)
        }
    }

    @objc private func startIndexing(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue else { return }
        guard removingDictionaryID != dictionaryID,
              !removalCoordinator.isRemoving(dictionaryID) else {
            showInformation(title: "词典正在移除",
                            message: "请等待当前安全移除操作完成。")
            return
        }
        switch indexCoordinator.start(dictionaryID: dictionaryID) {
        case .started:
            break
        case .busy:
            showInformation(title: "已有索引任务进行中",
                            message: "为控制 CPU、内存和磁盘负载，同一时间只建立一个索引。")
        case .unavailable:
            showInformation(
                title: "无法建立索引",
                message: "无法开始建立索引。托管副本和用户原始导入文件均未修改；请检查词典状态、文件可用性和磁盘空间后重试。"
            )
        }
    }

    @objc private func cancelIndexing(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue else { return }
        guard indexCoordinator.activity?.dictionaryID == dictionaryID else { return }
        cancellingDictionaryID = dictionaryID
        indexCoordinator.cancel(dictionaryID: dictionaryID)
        tableView.reloadData()
        updateSelectionActions()
    }

    @objc private func beginImport() {
        guard let window else { return }
        ManualEvidenceRecorder.shared.record("localMDXImportStarted", strings: [
            "operationState": "selecting"
        ])
        let panel = NSOpenPanel()
        panel.title = "选择本地 MDict 词典"
        panel.message = "请选择一个你有权在本机使用的 .mdx 文件。不会扫描其他目录或上传内容。"
        panel.prompt = "检查"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let mdxType = UTType(filenameExtension: "mdx") {
            panel.allowedContentTypes = [mdxType]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let selectedURL = panel.url else { return }
            self?.inspectSelection(selectedURL)
        }
    }

    private func inspectSelection(_ selectedURL: URL) {
        let inspector = importInspector
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                inspector.inspect(selectedURL)
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let previews):
                self.presentImportPreview(previews)
            case .failure(let error):
                self.showError(title: "无法检查词典", operation: .inspect, error: error)
            }
        }
    }

    private func presentImportPreview(_ previews: [DictionaryImportPreview]) {
        guard let window else { return }
        if let duplicate = previews.compactMap({ preview -> (DictionaryImportPreview, DictionaryDescriptor)? in
            guard let descriptor = importService.duplicateDescriptor(for: preview, in: catalog)
            else { return nil }
            return (preview, descriptor)
        }).first {
            presentDuplicateNotice(previews: previews, existing: duplicate.1)
            return
        }

        let controller = DictionaryImportPreviewWindowController(
            previews: previews, parentWindow: window
        ) { [weak self] selections in
            guard let self else { return }
            self.previewWindowController = nil
            self.previewAccessory = nil
            self.performImport(selections)
        }
        previewAccessory = controller.accessory
        previewWindowController = controller
        controller.present()
    }

    private func performImport(_ selections: [DictionaryImportSelection],
                               allowDuplicateContent: Bool = false) {
        guard let window else { return }
        ManualEvidenceRecorder.shared.record("localMDXImportConfirmed", strings: [
            "operationState": "importing"
        ], integers: ["selectionCount": Int64(selections.count)])
        let totalBytes = selections.reduce(UInt64(0)) {
            $0 &+ $1.preview.mdxFileSize &+
                $1.selectedMDDCandidates.reduce(UInt64(0)) { $0 &+ $1.fileSize }
        }
        let cancellationToken = DictionaryImportCancellationToken()
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 360, height: 18))
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = Double(max(totalBytes, 1))
        let progressPresenter = DictionaryImportProgressPresenter(indicator: indicator)

        let progressAlert = NSAlert()
        progressAlert.messageText = "正在复制词典文件…"
        progressAlert.informativeText = "文件会先复制到安全临时位置；取消或失败不会留下半成品词典记录。"
        progressAlert.accessoryView = indicator
        progressAlert.addButton(withTitle: "取消")
        progressAlert.beginSheetModal(for: window) { _ in cancellationToken.cancel() }

        let startingCatalog = catalog
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.importService.importSelections(
                    selections,
                    into: startingCatalog,
                    cancellationToken: cancellationToken,
                    progress: { completed, _ in
                        Task { @MainActor in
                            progressPresenter.update(completedBytes: completed)
                        }
                    },
                    allowDuplicateContent: allowDuplicateContent
                )
                if progressAlert.window.sheetParent != nil {
                    window.endSheet(progressAlert.window)
                }
                self.update(catalog: updated)
                self.onCatalogChanged(updated)
                let importedIDs = Set(updated.dictionaries.map(\.dictionaryID))
                    .subtracting(startingCatalog.dictionaries.map(\.dictionaryID))
                if let first = importedIDs.first { self.selectDictionary(id: first) }
                var startedName: String?
                if let first = importedIDs.first,
                   let descriptor = updated.dictionaries.first(where: {
                       $0.dictionaryID == first
                   }), case .started = self.indexCoordinator.start(dictionaryID: first) {
                    startedName = descriptor.displayName
                }
                self.showInformation(
                    title: "导入完成",
                    message: startedName.map {
                        "\($0) 已导入，正在自动建立查询索引。完成后即可查询；词典管理会显示中文反向查询能力。"
                    } ?? "词典已导入。若另一本词典正在建立索引，本词典会稳定保留为“等待建立索引”，可随后重试。"
                )
            } catch let error as DictionaryImportError {
                if progressAlert.window.sheetParent != nil {
                    window.endSheet(progressAlert.window)
                }
                if case .cancelled = error { return }
                if case .duplicate = error {
                    self.showInformation(title: "该词典可能已导入",
                                         message: "已安装列表中存在内容相同的词典，本次没有重复复制。")
                } else {
                    self.showError(title: "导入失败", operation: .importDictionary,
                                   error: error)
                }
            } catch {
                if progressAlert.window.sheetParent != nil {
                    window.endSheet(progressAlert.window)
                }
                self.showError(title: "导入失败", operation: .importDictionary, error: error)
            }
        }
    }

    private func presentDuplicateNotice(previews: [DictionaryImportPreview],
                                        existing: DictionaryDescriptor) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "该词典可能已导入"
        alert.informativeText = "已安装列表中已有内容相同的词典“\(existing.displayName)”。可以取消、显示现有词典，或明确作为独立词典导入。当前安全模型不支持用手动文件原地替换现有词典。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "显示现有词典")
        alert.addButton(withTitle: "作为独立词典")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.selectDictionary(id: existing.dictionaryID)
            } else if response == .alertSecondButtonReturn {
                self.performImport(
                    previews.map {
                        DictionaryImportSelection(preview: $0, selectedMDDIDs: [])
                    },
                    allowDuplicateContent: true
                )
            }
        }
    }

    private func selectDictionary(id: String) {
        guard let row = dictionaries.firstIndex(where: { $0.dictionaryID == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func showError(title: String,
                           operation: DictionaryManagerPresentation.ErrorOperation,
                           error: Error) {
        guard let window else { return }
        #if DEBUG
        NSLog("LocalDictionary manager operation failed type=%@",
              String(reflecting: type(of: error)))
        #endif
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = DictionaryManagerPresentation.errorMessage(for: operation)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func showInformation(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func value(for column: Column, dictionary: DictionaryDescriptor) -> String {
        switch column {
        case .name: return dictionary.displayName
        case .source: return DictionaryManagerPresentation.sourceText(dictionary.sourceKind)
        case .level: return DictionaryManagerPresentation.queryLevelText(dictionary.queryLevel)
        case .enabled: return dictionary.enabled ? "是" : "否"
        case .forwardState:
            return DictionaryManagerPresentation.statusText(
                for: dictionary,
                activity: presentationActivity(for: dictionary)
            )
        case .reverseState:
            if DictionaryManagerPresentation.requiresReinstallation(dictionary) {
                return "重新安装后检测"
            }
            if dictionary.reverseCapabilityProbe == .unknown,
               reverseCapability(dictionary.dictionaryID) == .unknownNeedsProbe {
                return "自动抽样未确认，需完整检测"
            }
            return DictionaryManagerPresentation.reverseStatusText(
                reverseStoredStates[dictionary.dictionaryID],
                progress: reverseProgress[dictionary.dictionaryID],
                capability: reverseCapability(dictionary.dictionaryID)
            )
        case .action: return ""
        }
    }

    private func reverseCapability(_ dictionaryID: String) -> ReverseIndexCapability {
        if let source = reverseSources.first(where: { $0.dictionaryID == dictionaryID }) {
            return source.reverseCapability
        }
        // Disabled dictionaries intentionally do not enter the query source set, but their
        // persisted capability remains authoritative in Dictionary Manager. Falling back to
        // unknown here made a disabled supported/unsupported import look untested again.
        if let descriptor = dictionaries.first(where: { $0.dictionaryID == dictionaryID }) {
            return ReverseDictionarySource(managed: descriptor).reverseCapability
        }
        return .unknownNeedsProbe
    }

    private func stateColor(for dictionary: DictionaryDescriptor) -> NSColor {
        let activity = presentationActivity(for: dictionary)
        if activity == .removing || activity == .cancellingIndex { return .systemOrange }
        if DictionaryManagerPresentation.requiresReinstallation(dictionary) {
            return .systemOrange
        }
        if !dictionary.enabled { return .secondaryLabelColor }
        switch dictionary.state {
        case .ready: return .systemGreen
        case .pendingIndex, .indexing, .copying, .scanning: return .systemOrange
        case .disabled: return .secondaryLabelColor
        default: return .systemRed
        }
    }

    private func presentationActivity(
        for dictionary: DictionaryDescriptor
    ) -> DictionaryManagerPresentation.Activity {
        if removingDictionaryID == dictionary.dictionaryID ||
            removalCoordinator.isRemoving(dictionary.dictionaryID) {
            return .removing
        }
        if cancellingDictionaryID == dictionary.dictionaryID {
            return .cancellingIndex
        }
        return .idle
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yyyy-MM-dd HH:mm")
        return formatter
    }()
}

@MainActor
private final class DictionaryImportProgressPresenter {
    private weak var indicator: NSProgressIndicator?

    init(indicator: NSProgressIndicator) {
        self.indicator = indicator
    }

    func update(completedBytes: UInt64) {
        indicator?.doubleValue = Double(completedBytes)
    }
}

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
