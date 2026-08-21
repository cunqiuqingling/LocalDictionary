import AppKit

@MainActor
final class ResourceCenterViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name, languages, version, size, license, status
    }

    private let controller: ResourceCenterController
    private let onClose: @MainActor () -> Void
    private var snapshot: ResourceCenterSnapshot
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let recommendationLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let detailScrollView = NSScrollView()
    private let refreshButton = NSButton()
    private let actionButton = NSButton()
    private let cancelButton = NSButton()
    private let copyDiagnosticButton = NSButton()
    private let closeButton = NSButton()

    init(controller: ResourceCenterController,
         onClose: @escaping @MainActor () -> Void = {}) {
        self.controller = controller
        self.onClose = onClose
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

        let heading = NSTextField(labelWithString: t("开放资源中心", "Resource Center"))
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: t(
            "开放资源从审核后的官方固定地址下载，并在本机转换为内部 SQLite；" +
                "手动导入仍支持你有权使用的 MDX。",
            "Open resources are downloaded from reviewed official fixed URLs and converted " +
                "locally. Manual import remains available for MDX files you may use."
        ))
        explanation.textColor = .secondaryLabelColor

        recommendationLabel.textColor = .labelColor
        recommendationLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        recommendationLabel.setAccessibilityIdentifier("resource-center-language-recommendation")

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        detailLabel.maximumNumberOfLines = 0
        detailLabel.isSelectable = true
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.setAccessibilityIdentifier("resource-center-detail-text")

        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.setAccessibilityIdentifier("resource-center-table-scroll")

        let detailDocument = NSView()
        detailDocument.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailDocument.addSubview(detailLabel)
        detailScrollView.documentView = detailDocument
        detailScrollView.hasVerticalScroller = true
        detailScrollView.hasHorizontalScroller = false
        detailScrollView.autohidesScrollers = true
        detailScrollView.borderType = .bezelBorder
        detailScrollView.setAccessibilityIdentifier("resource-center-detail-scroll")

        refreshButton.title = t("刷新已签名目录", "Refresh Signed Catalog")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded

        actionButton.title = t("下载并安装", "Download and Install")
        actionButton.target = self
        actionButton.action = #selector(performSelectedAction)
        actionButton.bezelStyle = .rounded

        cancelButton.title = t("停止当前操作", "Stop Current Operation")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded

        copyDiagnosticButton.title = t("复制诊断信息", "Copy Diagnostics")
        copyDiagnosticButton.target = self
        copyDiagnosticButton.action = #selector(copyDiagnostics)
        copyDiagnosticButton.bezelStyle = .rounded
        copyDiagnosticButton.setAccessibilityLabel("复制所选资源的下载诊断信息")

        closeButton.title = t("关闭", "Close")
        closeButton.target = self
        closeButton.action = #selector(closeResourceCenter)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityLabel("关闭开放资源中心")

        let preferredNotice = NSTextField(wrappingLabelWithString: t(
            "Preferred 五本词典来自用户已有配置；资源中心不会下载、分发、重排或改写它们。",
            "The five Preferred dictionaries come from your existing configuration; the " +
                "Resource Center does not download, distribute, reorder, or rewrite them."
        ))
        preferredNotice.textColor = .secondaryLabelColor
        preferredNotice.font = .systemFont(ofSize: 11)

        let buttons = NSStackView(views: [
            refreshButton, actionButton, cancelButton, copyDiagnosticButton, closeButton
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [
            heading, explanation, recommendationLabel, statusLabel, scroll,
            detailScrollView, buttons, preferredNotice
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        buttons.setAccessibilityIdentifier("resource-center-action-bar")

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 300),
            detailScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            detailScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 170),
            detailDocument.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: detailDocument.topAnchor, constant: 7),
            detailLabel.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor, constant: -7)
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
            value = Self.sizeText(rowValue.installedSize)
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
        tableView.setAccessibilityLabel(t("可安装开放词典", "Installable Open Dictionaries"))
        addColumn(.name, title: t("资源", "Resource"), width: 210)
        addColumn(.languages, title: t("语言", "Languages"), width: 105)
        addColumn(.version, title: t("版本", "Version"), width: 80)
        addColumn(.size, title: t("大小", "Size"), width: 90)
        addColumn(.license, title: t("许可证", "License"), width: 160)
        addColumn(.status, title: t("状态", "Status"), width: 130)
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
        statusLabel.stringValue = AppLocalization.language == .english
            ? englishCatalogMessage(for: snapshot.catalogState)
            : snapshot.catalogMessage
        let recommended = snapshot.recommendedResources.map(\.displayName)
        recommendationLabel.stringValue = recommended.isEmpty
            ? t("推荐给当前语言组合：暂无已验证资源",
                "Recommended for the current language pair: no validated resources")
            : t("推荐给当前语言组合（最多 3 项）：" + recommended.joined(separator: "、"),
                "Recommended for the current language pair (up to 3): " +
                    recommended.joined(separator: ", "))
        refreshButton.isEnabled = snapshot.catalogState != .loading
        tableView.reloadData()
        if snapshot.resources.isEmpty {
            detailLabel.stringValue =
                "当前没有通过完整合规审计的可安装资源。只有许可证允许重新分发和格式转换、" +
                "来源与托管稳定、大小和 SHA-256 固定、签名信任链有效的双语资源才会出现。\n" +
                "已安装开放资源 \(snapshot.installedOpenResourceCount) 本，用户导入 " +
                "\(snapshot.importedDictionaryCount) 本。关闭本窗口后，可在词典管理中手动导入" +
                "你有权使用的 MDX。"
        }
        updateSelection()
    }

    private func updateSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshot.resources.count else {
            actionButton.isEnabled = false
            cancelButton.isEnabled = false
            copyDiagnosticButton.isEnabled = false
            return
        }
        let resource = snapshot.resources[row]
        detailLabel.stringValue = """
        \(resource.summary)
        来源/发布者：\(resource.publisher)
        原始下载：\(resource.sourceURL)
        源格式：\(resource.sourceFormat)
        许可证：\(resource.licenseName)
        许可证链接：\(resource.licenseURL)
        署名：\(resource.attribution)
        校验：\(resource.checksumSummary)
        \(resource.redistributionStatement)
        \(resource.localConversionStatement)
        \(resource.failureMessage.map { "失败原因：\($0)" } ?? "")
        \(resource.diagnosticText.map { "\n诊断信息（不含用户数据）\n\($0)" } ?? "")
        """
        if resource.operationState == .needsReinstall {
            actionButton.title = t("重新安装", "Reinstall")
        } else {
            actionButton.title = resource.canUpdate
                ? t("安全更新", "Safe Update") : t("下载并安装", "Download and Install")
        }
        actionButton.isEnabled = resource.canInstall || resource.canUpdate
        actionButton.toolTip = resource.canUpdate
            ? "当前版本会保留；只有新版本完成安全安装和索引后才能切换。"
            : "下载和安装只使用已签名目录中的 URL，不能手动输入地址。"
        copyDiagnosticButton.isEnabled = resource.diagnosticText?.isEmpty == false
        switch resource.operationState {
        case .downloading, .downloaded, .verifying, .installing, .converting, .indexing,
             .validatingIndex:
            cancelButton.isEnabled = true
        default:
            cancelButton.isEnabled = false
        }
    }

    @objc private func refresh() {
        controller.refresh()
    }

    private func t(_ chinese: String, _ english: String) -> String {
        AppLocalization.text(chinese, english)
    }

    private func englishCatalogMessage(for state: ResourceCenterCatalogState) -> String {
        switch state {
        case .catalogUnavailable: return "The resource catalog is unavailable."
        case .loading: return "Securely validating the resource catalog…"
        case .catalogInvalid: return "The resource catalog did not pass validation."
        case .available: return "The reviewed built-in Starter Catalog is ready."
        case .offlineVerified: return "Using the last locally verified resource catalog."
        }
    }

    @objc private func performSelectedAction() {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshot.resources.count else { return }
        let resource = snapshot.resources[row]
        ManualEvidenceRecorder.shared.record(
            resource.operationState == .needsReinstall ||
                resource.operationState == .failed ||
                resource.operationState == .cancelled
                ? "resourceRetryClicked" : "resourceInstallClicked",
            strings: [
                "resourceID": resource.id,
                "operationState": String(describing: resource.operationState)
            ]
        )
        controller.install(resourceID: resource.id)
    }

    @objc private func cancel() {
        controller.cancelCurrentOperation()
    }

    @objc private func copyDiagnostics() {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshot.resources.count,
              let text = snapshot.resources[row].diagnosticText,
              !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closeResourceCenter() {
        controller.presentationWillClose()
        onClose()
    }

    override func cancelOperation(_ sender: Any?) {
        closeResourceCenter()
    }

    private static func statusText(_ state: ResourceCenterOperationState) -> String {
        switch state {
        case .available: return AppLocalization.text("可安装", "Available")
        case .downloading(let received, let expected):
            if let expected, expected > 0 {
                return "\(received * 100 / expected)%"
            }
            return AppLocalization.text("正在下载", "Downloading")
        case .downloaded: return AppLocalization.text("下载完成", "Downloaded")
        case .verifying: return AppLocalization.text("正在验证", "Verifying")
        case .installing: return AppLocalization.text("正在安装", "Installing")
        case .converting(let processed, let total):
            if let total, total > 0 { return "转换 \(processed * 100 / total)%" }
            return AppLocalization.text("正在转换（\(processed) 条）",
                                        "Converting (\(processed) entries)")
        case .indexing: return AppLocalization.text("正在索引", "Indexing")
        case .validatingIndex: return AppLocalization.text("正在验证索引", "Validating Index")
        case .publishing: return AppLocalization.text("正在发布", "Publishing")
        case .installed: return AppLocalization.text("已安装", "Installed")
        case .updateAvailable: return AppLocalization.text("有更新", "Update Available")
        case .needsReinstall: return AppLocalization.text("需要重新安装", "Needs Reinstall")
        case .removing: return AppLocalization.text("正在移除", "Removing")
        case .failed: return AppLocalization.text("失败", "Failed")
        case .cancelled: return AppLocalization.text("已取消", "Cancelled")
        }
    }

    static func sizeText(_ byteCount: UInt64?) -> String {
        guard let byteCount, byteCount > 0 else {
            return AppLocalization.text("安装时获取", "Measured on install")
        }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: byteCount), countStyle: .file
        )
    }
}

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
