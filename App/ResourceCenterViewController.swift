import AppKit

@MainActor
final class ResourceCenterViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name, languages, version, size, license, status
    }

    private let controller: ResourceCenterController
    private var snapshot: ResourceCenterSnapshot
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton()
    private let actionButton = NSButton()
    private let cancelButton = NSButton()

    init(controller: ResourceCenterController) {
        self.controller = controller
        snapshot = controller.snapshot
        super.init(nibName: nil, bundle: nil)
        controller.onSnapshotChanged = { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let heading = NSTextField(labelWithString: "开放资源中心")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "只安装通过签名、允许主机、大小、SHA-256、许可证与 receipt 验证的单文件 MDX。")
        explanation.textColor = .secondaryLabelColor

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        detailLabel.maximumNumberOfLines = 8
        detailLabel.isSelectable = true
        detailLabel.textColor = .secondaryLabelColor

        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        refreshButton.title = "刷新已签名目录"
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded

        actionButton.title = "下载并安装"
        actionButton.target = self
        actionButton.action = #selector(performSelectedAction)
        actionButton.bezelStyle = .rounded

        cancelButton.title = "取消当前操作"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded

        let preferredNotice = NSTextField(wrappingLabelWithString:
            "Preferred 五本词典来自用户已有配置；Resource Center 不下载、分发、重排或改写其 formatter。")
        preferredNotice.textColor = .secondaryLabelColor
        preferredNotice.font = .systemFont(ofSize: 11)

        let buttons = NSStackView(views: [refreshButton, actionButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [
            heading, explanation, statusLabel, scroll, detailLabel, buttons, preferredNotice
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        apply(snapshot)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshot.resources.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < snapshot.resources.count, let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue) else {
            return nil
        }
        let rowValue = snapshot.resources[row]
        let value: String
        switch column {
        case .name: value = rowValue.displayName
        case .languages: value = rowValue.languages
        case .version: value = rowValue.version
        case .size:
            value = rowValue.installedSize.map {
                ByteCountFormatter.string(fromByteCount: Int64(clamping: $0),
                                          countStyle: .file)
            } ?? "—"
        case .license: value = rowValue.licenseName
        case .status: value = Self.statusText(rowValue.operationState)
        }
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 26
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel("可安装开放词典")
        addColumn(.name, title: "资源", width: 210)
        addColumn(.languages, title: "语言", width: 105)
        addColumn(.version, title: "版本", width: 80)
        addColumn(.size, title: "大小", width: 90)
        addColumn(.license, title: "许可证", width: 160)
        addColumn(.status, title: "状态", width: 130)
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat) {
        let value = NSTableColumn(identifier: .init(column.rawValue))
        value.title = title
        value.width = width
        value.minWidth = width
        value.resizingMask = .userResizingMask
        tableView.addTableColumn(value)
    }

    private func apply(_ snapshot: ResourceCenterSnapshot) {
        self.snapshot = snapshot
        guard isViewLoaded else { return }
        statusLabel.stringValue = snapshot.catalogMessage
        refreshButton.isEnabled = snapshot.catalogState != .loading
        tableView.reloadData()
        if snapshot.resources.isEmpty {
            detailLabel.stringValue =
                "当前没有可安装资源。已安装开放资源 \(snapshot.installedOpenResourceCount) 本，" +
                "用户导入 \(snapshot.importedDictionaryCount) 本。手动导入仍可在词典管理窗口使用。"
        }
        updateSelection()
    }

    private func updateSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshot.resources.count else {
            actionButton.isEnabled = false
            cancelButton.isEnabled = false
            return
        }
        let resource = snapshot.resources[row]
        detailLabel.stringValue = """
        \(resource.summary)
        来源/发布者：\(resource.publisher)
        来源：\(resource.sourceURL)
        许可证：\(resource.licenseName)
        许可证链接：\(resource.licenseURL)
        \(resource.redistributionStatement)
        \(resource.failureMessage ?? "")
        """
        actionButton.title = resource.canUpdate ? "安全更新" : "下载并安装"
        actionButton.isEnabled = resource.canInstall || resource.canUpdate
        actionButton.toolTip = resource.canUpdate
            ? "当前版本会保留；只有新版本完成安全安装和索引后才能切换。"
            : "下载和安装只使用已签名目录中的 URL，不能手动输入地址。"
        switch resource.operationState {
        case .downloading, .verifying:
            cancelButton.isEnabled = true
        default:
            cancelButton.isEnabled = false
        }
    }

    @objc private func refresh() {
        controller.refresh()
    }

    @objc private func performSelectedAction() {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshot.resources.count else { return }
        controller.install(resourceID: snapshot.resources[row].id)
    }

    @objc private func cancel() {
        controller.cancelCurrentOperation()
    }

    private static func statusText(_ state: ResourceCenterOperationState) -> String {
        switch state {
        case .available: return "可安装"
        case .downloading(let received, let expected):
            if let expected, expected > 0 {
                return "\(received * 100 / expected)%"
            }
            return "正在下载"
        case .verifying: return "正在验证"
        case .installing: return "正在安装"
        case .indexing: return "正在索引"
        case .installed: return "已安装"
        case .updateAvailable: return "有更新"
        case .removing: return "正在移除"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
