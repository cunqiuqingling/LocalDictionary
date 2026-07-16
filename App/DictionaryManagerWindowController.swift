import AppKit
import UniformTypeIdentifiers

@MainActor
final class DictionaryManagerWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name
        case source
        case level
        case position
        case enabled
        case state
        case entries
        case indexSize
        case indexedAt
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
    private let onCatalogChanged: (DictionaryCatalog) -> Void
    private var previewAccessory: DictionaryImportPreviewAccessory?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSStackView()
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()
    private let removeButton = NSButton()
    private let reorderHelpLabel = NSTextField(labelWithString:
        "仅可在相同查询级别内排序；跨组拖动会被拒绝。")
    private var removingDictionaryID: String?
    private static let dictionaryPasteboardType = NSPasteboard.PasteboardType(
        "com.localdict.dictionary-catalog-id"
    )

    init(catalog: DictionaryCatalog,
         catalogStore: DictionaryCatalogStore,
         importInspector: MDictImportInspector = MDictImportInspector(),
         importService: DictionaryImportService? = nil,
         indexCoordinator: ManagedDictionaryIndexCoordinator,
         removalCoordinator: ManagedDictionaryRemovalCoordinator,
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
        self.onCatalogChanged = onCatalogChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 430),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "词典管理"
        window.minSize = NSSize(width: 760, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
        update(catalog: catalog)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func update(catalog: DictionaryCatalog) {
        let selectedID = selectedDictionary?.dictionaryID
        self.catalog = catalog
        orderCoordinator.synchronize(catalog: catalog)
        dictionaries = catalog.sortedDictionaries
        tableView.reloadData()
        scrollView.isHidden = dictionaries.isEmpty
        emptyStateView.isHidden = !dictionaries.isEmpty
        if let selectedID,
           let row = dictionaries.firstIndex(where: { $0.dictionaryID == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateSelectionActions()
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
                dictionary.sourceKind == .legacyReference) &&
                removingDictionaryID != dictionary.dictionaryID
            button.toolTip = dictionary.sourceKind == .legacyReference
                ? "启用或停用此旧配置词典；不会删除或修改其原始文件。"
                : "启用或停用此托管词典；不会删除其索引。"
            return button
        }
        if column == .action { return indexActionView(for: dictionaries[row]) }
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
        cell.textField?.stringValue = value(for: column, dictionary: dictionaries[row])
        cell.textField?.textColor = column == .state ? stateColor(dictionaries[row].state)
                                                     : .labelColor
        if column == .state, let message = indexCoordinator.failureMessage(
            for: dictionaries[row].dictionaryID
        ) {
            cell.toolTip = message
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

        let heading = NSTextField(labelWithString: "已安装词典")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(wrappingLabelWithString:
            "可安全托管本地 MDX/MDD、建立独立索引，并调整同级词典的查询顺序。")
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        configureEmptyState()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let orderingActions = NSStackView(views: [
            configuredMoveButton(moveUpButton, title: "上移",
                                 action: #selector(moveSelectedUp)),
            configuredMoveButton(moveDownButton, title: "下移",
                                 action: #selector(moveSelectedDown)),
            restoreDefaultsButton(),
            configuredRemoveButton()
        ])
        orderingActions.orientation = .horizontal
        orderingActions.spacing = 8
        orderingActions.alignment = .centerY

        let resourceActions = NSStackView(views: [
            futureButton(title: "获取开放词典"),
            importButton()
        ])
        resourceActions.orientation = .horizontal
        resourceActions.spacing = 10
        resourceActions.alignment = .centerY

        reorderHelpLabel.textColor = .secondaryLabelColor
        reorderHelpLabel.font = .systemFont(ofSize: 11)

        let actions = NSStackView(views: [orderingActions, resourceActions, reorderHelpLabel])
        actions.orientation = .vertical
        actions.spacing = 7
        actions.alignment = .leading
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
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 27
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.registerForDraggedTypes([Self.dictionaryPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        addColumn(.name, title: "词典名称", width: 205)
        addColumn(.source, title: "来源类型", width: 92)
        addColumn(.level, title: "查询级别", width: 70)
        addColumn(.position, title: "排序", width: 48)
        addColumn(.enabled, title: "启用", width: 48)
        addColumn(.state, title: "状态", width: 72)
        addColumn(.entries, title: "词条数量", width: 85)
        addColumn(.indexSize, title: "索引大小", width: 82)
        addColumn(.indexedAt, title: "最近索引", width: 130)
        addColumn(.action, title: "索引操作", width: 140, minWidth: 140)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat,
                           minWidth: CGFloat? = nil) {
        let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = minWidth ?? min(width, 48)
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
    }

    private func configureEmptyState() {
        let title = NSTextField(labelWithString: "尚未安装本地词典")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        let detail = NSTextField(wrappingLabelWithString:
            "LocalDictionary 仍可启动并使用 AI 设置；可通过下方按钮托管本地 MDX。")
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.addArrangedSubview(title)
        emptyStateView.addArrangedSubview(detail)
    }

    private func futureButton(title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(showFuturePhaseNotice(_:)))
        button.bezelStyle = .rounded
        return button
    }

    private func importButton() -> NSButton {
        let button = NSButton(title: "导入本地 MDX/MDD", target: self,
                              action: #selector(beginImport))
        button.bezelStyle = .rounded
        return button
    }

    private func configuredMoveButton(_ button: NSButton, title: String,
                                      action: Selector) -> NSButton {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.toolTip = title == "上移"
            ? "在当前查询级别内将所选词典上移。"
            : "在当前查询级别内将所选词典下移。"
        return button
    }

    private func restoreDefaultsButton() -> NSButton {
        let button = NSButton(title: "恢复默认顺序", target: self,
                              action: #selector(confirmRestoreDefaultOrder))
        button.bezelStyle = .rounded
        button.toolTip = "只恢复各查询级别内的默认顺序，不改变启用、状态或索引。"
        return button
    }

    private func configuredRemoveButton() -> NSButton {
        removeButton.title = "移除词典…"
        removeButton.target = self
        removeButton.action = #selector(confirmRemoveSelectedDictionary)
        removeButton.bezelStyle = .rounded
        return removeButton
    }

    private var selectedDictionary: DictionaryDescriptor? {
        let row = tableView.selectedRow
        guard row >= 0, row < dictionaries.count else { return nil }
        return dictionaries[row]
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionActions()
    }

    private func updateSelectionActions() {
        guard let selectedDictionary else {
            moveUpButton.isEnabled = false
            moveDownButton.isEnabled = false
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
        let isRemoving = removingDictionaryID == selectedDictionary.dictionaryID ||
            removalCoordinator.isRemoving(selectedDictionary.dictionaryID)
        removeButton.isEnabled = selectedDictionary.sourceKind == .managedLocal && !isRemoving
        if selectedDictionary.sourceKind == .legacyReference {
            removeButton.toolTip = "该词典来自旧配置引用。LocalDictionary 不会删除其原始文件，可通过停用来停止查询。"
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
        } catch DictionaryCatalogOrderingError.crossLevelMove {
            reorderHelpLabel.stringValue = "不能跨查询级别移动；请放回当前分组。"
            reorderHelpLabel.textColor = .systemRed
            return []
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
            return persistCatalogChange(updated, selectedID: dictionaryID,
                                        failureTitle: "无法保存词典顺序")
        } catch DictionaryCatalogOrderingError.crossLevelMove {
            reorderHelpLabel.stringValue = "不能跨查询级别移动；请放回当前分组。"
            reorderHelpLabel.textColor = .systemRed
            showInformation(title: "不能跨查询级别移动",
                            message: "本阶段只允许在相同查询级别内调整顺序。")
            return false
        } catch {
            showError(title: "无法调整词典顺序", error: error)
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
        reorderHelpLabel.stringValue = "仅可在相同查询级别内排序；跨组拖动会被拒绝。"
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
            _ = persistCatalogChange(updated,
                                     selectedID: selectedDictionary.dictionaryID,
                                     failureTitle: "无法保存词典顺序")
        } catch {
            showError(title: "无法调整词典顺序", error: error)
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
        alert.informativeText = "只恢复各查询级别内的顺序，不改变启用状态、索引或词典内容。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            _ = self.persistCatalogChange(updated, selectedID: nil,
                                          failureTitle: "无法恢复默认顺序")
        }
    }

    @objc private func confirmRemoveSelectedDictionary() {
        guard let window, let dictionary = selectedDictionary else { return }
        guard dictionary.sourceKind == .managedLocal else {
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
        alert.informativeText = "将从 LocalDictionary 中移除该词典，并删除 App 托管目录中的 MDX 副本和 SQLite 索引。用户最初选择导入的原始文件不会被修改；已保存的收藏正文快照仍可阅读。此操作不可撤销。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "移除词典")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.performRemoval(dictionaryID: dictionary.dictionaryID)
        }
    }

    private func performRemoval(dictionaryID: String) {
        guard removingDictionaryID == nil else { return }
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
                self.showInformation(
                    title: "词典已移除",
                    message: cleanupDeferred
                        ? "Catalog 已更新；托管目录将在下次启动时继续安全清理。"
                        : "App 托管的词典副本和索引已移除；原始导入文件未修改。"
                )
            case .failed(let error):
                self.showError(title: "无法移除词典", error: error)
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
            try orderCoordinator.save(updated)
            update(catalog: updated)
            if let selectedID { selectDictionary(id: selectedID) }
            onCatalogChanged(updated)
            return true
        } catch {
            update(catalog: previous)
            if let selectedID { selectDictionary(id: selectedID) }
            showError(title: failureTitle, error: error)
            return false
        }
    }

    @objc private func showFuturePhaseNotice(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = sender.title
        alert.informativeText = "将在后续阶段提供。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        if let window { alert.beginSheetModal(for: window) }
    }

    @objc private func enabledStateChanged(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let index = catalog.dictionaries.firstIndex(where: {
                  $0.dictionaryID == identifier &&
                      ($0.sourceKind == .managedLocal ||
                       $0.sourceKind == .legacyReference)
              }) else { return }
        let previous = catalog
        var updated = catalog
        updated.dictionaries[index].enabled = sender.state == .on
        updated.dictionaries[index].updatedAt = Date()
        updated.updatedAt = Date()
        do {
            try orderCoordinator.save(updated)
            update(catalog: updated)
            onCatalogChanged(updated)
        } catch {
            update(catalog: previous)
            showError(title: "无法保存启用状态", error: error)
        }
    }

    private func indexActionView(for dictionary: DictionaryDescriptor) -> NSView {
        guard dictionary.sourceKind == .managedLocal else {
            return NSTextField(labelWithString: "—")
        }
        let button: NSButton
        switch dictionary.state {
        case .pendingIndex:
            button = NSButton(title: "建立索引", target: self,
                              action: #selector(startIndexing(_:)))
            button.toolTip = "为该托管词典建立本地索引，不删除或修改源 MDX。"
        case .failed:
            button = NSButton(title: "重试", target: self,
                              action: #selector(startIndexing(_:)))
            button.toolTip = "重新为该托管词典建立本地索引。"
        case .indexing:
            button = NSButton(title: "取消索引", target: self,
                              action: #selector(cancelIndexing(_:)))
            button.toolTip = "请求取消当前索引任务。"
        case .ready:
            button = NSButton(title: "已建立", target: nil, action: nil)
            button.isEnabled = false
            button.toolTip = "该词典索引已完成。"
        default:
            button = NSButton(title: "不可用", target: nil, action: nil)
            button.isEnabled = false
            button.toolTip = "当前词典状态不允许建立索引。"
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(dictionary.dictionaryID)
        if removingDictionaryID == dictionary.dictionaryID ||
            removalCoordinator.isRemoving(dictionary.dictionaryID) {
            button.isEnabled = false
            button.toolTip = "该词典正在安全移除。"
        }
        guard dictionary.state == .indexing else { return button }

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        let stack = NSStackView(views: [indicator, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
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
        case .unavailable(let message):
            showInformation(title: "无法建立索引", message: message)
        }
    }

    @objc private func cancelIndexing(_ sender: NSButton) {
        guard let dictionaryID = sender.identifier?.rawValue else { return }
        indexCoordinator.cancel(dictionaryID: dictionaryID)
    }

    @objc private func beginImport() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择本地 MDict 词典"
        panel.message = "请选择一个 .mdx 文件，或包含一个或多个 .mdx 的文件夹。"
        panel.prompt = "检查"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
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
                self.showError(title: "无法检查词典", error: error)
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
            presentDuplicateNotice(existing: duplicate.1)
            return
        }

        let accessory = DictionaryImportPreviewAccessory(previews: previews)
        previewAccessory = accessory
        let alert = NSAlert()
        alert.messageText = previews.count == 1 ? "导入预览" : "导入预览（\(previews.count) 本词典）"
        alert.informativeText = "仅检查必要元数据。确认后将复制文件并创建等待索引的 Catalog 记录。"
        alert.alertStyle = .informational
        alert.accessoryView = accessory.view
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self, accessory] response in
            guard let self else { return }
            self.previewAccessory = nil
            guard response == .alertFirstButtonReturn else { return }
            self.performImport(accessory.selections)
        }
    }

    private func performImport(_ selections: [DictionaryImportSelection]) {
        guard let window else { return }
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
        progressAlert.informativeText = "文件先写入 staging；取消或失败不会发布半成品。"
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
                    }
                )
                if progressAlert.window.sheetParent != nil {
                    window.endSheet(progressAlert.window)
                }
                self.update(catalog: updated)
                self.onCatalogChanged(updated)
                let importedIDs = Set(updated.dictionaries.map(\.dictionaryID))
                    .subtracting(startingCatalog.dictionaries.map(\.dictionaryID))
                if let first = importedIDs.first { self.selectDictionary(id: first) }
                self.showInformation(title: "导入完成",
                                     message: "文件已安全托管，词典状态为“等待索引”。")
            } catch let error as DictionaryImportError {
                if progressAlert.window.sheetParent != nil {
                    window.endSheet(progressAlert.window)
                }
                if case .cancelled = error { return }
                if case .duplicate = error {
                    self.showError(title: "该词典可能已导入", error: error)
                } else {
                    self.showError(title: "导入失败", error: error)
                }
            } catch {
                if progressAlert.window.sheetParent != nil {
                    window.endSheet(progressAlert.window)
                }
                self.showError(title: "导入失败", error: error)
            }
        }
    }

    private func presentDuplicateNotice(existing: DictionaryDescriptor) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "该词典可能已导入"
        alert.informativeText = "Catalog 中已有内容摘要相同的词典“\(existing.displayName)”。本轮默认不重复复制。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "显示现有词典")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.selectDictionary(id: existing.dictionaryID)
            }
        }
    }

    private func selectDictionary(id: String) {
        guard let row = dictionaries.firstIndex(where: { $0.dictionaryID == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func showError(title: String, error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.alertStyle = .warning
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
        case .source: return dictionary.sourceKind.displayName
        case .level: return dictionary.queryLevel.displayName
        case .position: return String(dictionary.sortPosition)
        case .enabled: return dictionary.enabled ? "是" : "否"
        case .state: return dictionary.state.displayName
        case .entries:
            guard let count = dictionary.indexMetadata.entryCount else { return "—" }
            return Self.numberFormatter.string(from: NSNumber(value: count)) ?? String(count)
        case .indexSize:
            guard let size = dictionary.indexMetadata.indexFileSize else { return "—" }
            return ByteCountFormatter.string(fromByteCount: Int64(clamping: size),
                                             countStyle: .file)
        case .indexedAt:
            guard let date = dictionary.indexMetadata.indexedAt else { return "—" }
            return Self.dateFormatter.string(from: date)
        case .action: return ""
        }
    }

    private func stateColor(_ state: DictionaryState) -> NSColor {
        switch state {
        case .ready: return .systemGreen
        case .pendingIndex, .indexing, .copying, .scanning: return .systemOrange
        case .disabled: return .secondaryLabelColor
        default: return .systemRed
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
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
