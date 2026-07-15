import AppKit

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
        case indexedAt
    }

    private var catalog: DictionaryCatalog
    private var dictionaries: [DictionaryDescriptor] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSStackView()

    init(catalog: DictionaryCatalog) {
        self.catalog = catalog
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 430),
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
            "本阶段仅展示当前目录状态。导入、开放资源和排序编辑将在后续阶段提供。")
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        configureEmptyState()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [
            futureButton(title: "获取开放词典"),
            futureButton(title: "导入本地 MDX/MDD"),
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
        addColumn(.indexedAt, title: "最近索引", width: 145)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat) {
        let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = min(width, 48)
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
    }

    private func configureEmptyState() {
        let title = NSTextField(labelWithString: "尚未安装本地词典")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        let detail = NSTextField(wrappingLabelWithString:
            "LocalDictionary 仍可启动并使用 AI 设置；本地词典导入将在后续阶段提供。")
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

    @objc private func showFuturePhaseNotice(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = sender.title
        alert.informativeText = "将在后续阶段提供。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        if let window { alert.beginSheetModal(for: window) }
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
        case .indexedAt:
            guard let date = dictionary.indexMetadata.indexedAt else { return "—" }
            return Self.dateFormatter.string(from: date)
        }
    }

    private func stateColor(_ state: DictionaryState) -> NSColor {
        switch state {
        case .ready: return .systemGreen
        case .indexing, .copying, .scanning: return .systemOrange
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
