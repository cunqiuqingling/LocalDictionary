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
    private let importInspector: MDictImportInspector
    private let importService: DictionaryImportService
    private let indexCoordinator: ManagedDictionaryIndexCoordinator
    private let onCatalogChanged: (DictionaryCatalog) -> Void
    private var previewAccessory: DictionaryImportPreviewAccessory?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSStackView()

    init(catalog: DictionaryCatalog,
         catalogStore: DictionaryCatalogStore,
         importInspector: MDictImportInspector = MDictImportInspector(),
         importService: DictionaryImportService? = nil,
         indexCoordinator: ManagedDictionaryIndexCoordinator,
         onCatalogChanged: @escaping (DictionaryCatalog) -> Void = { _ in }) {
        self.catalog = catalog
        self.catalogStore = catalogStore
        self.importInspector = importInspector
        self.importService = importService ?? DictionaryImportService(catalogStore: catalogStore)
        self.indexCoordinator = indexCoordinator
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
        self.catalog = catalog
        dictionaries = catalog.sortedDictionaries
        tableView.reloadData()
        scrollView.isHidden = dictionaries.isEmpty
        emptyStateView.isHidden = !dictionaries.isEmpty
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
            button.isEnabled = dictionary.sourceKind == .managedLocal
            button.toolTip = button.isEnabled
                ? "启用或停用此托管 Catalog 记录；本阶段不会加入生产查询。"
                : "旧五词典仍由 legacy 调度器管理。"
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
            "可安全托管本地 MDX/MDD，并手动建立独立索引；用户词典暂不加入查询。")
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        configureEmptyState()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [
            futureButton(title: "获取开放词典"),
            importButton(),
            futureButton(title: "查询顺序与显示规则")
        ])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY
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
                  $0.dictionaryID == identifier && $0.sourceKind == .managedLocal
              }) else { return }
        let previous = catalog
        var updated = catalog
        updated.dictionaries[index].enabled = sender.state == .on
        updated.dictionaries[index].updatedAt = Date()
        updated.updatedAt = Date()
        do {
            try catalogStore.save(updated)
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
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(dictionary.dictionaryID)
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
