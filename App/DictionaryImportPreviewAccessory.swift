import AppKit

@MainActor
final class DictionaryImportPreviewAccessory: NSObject {
    @MainActor
    private final class PreviewRow {
        let preview: DictionaryImportPreview
        let estimatedLabel: NSTextField
        var candidateButtons: [String: NSButton] = [:]

        init(preview: DictionaryImportPreview, estimatedLabel: NSTextField) {
            self.preview = preview
            self.estimatedLabel = estimatedLabel
        }

        var selectedMDDIDs: Set<String> {
            Set(candidateButtons.compactMap { $0.value.state == .on ? $0.key : nil })
        }
    }

    let view: NSView
    private var rows: [PreviewRow] = []

    init(previews: [DictionaryImportPreview]) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 380))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        view = scrollView
        super.init()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        for preview in previews {
            stack.addArrangedSubview(makePreviewBox(preview))
        }
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: 660, height: max(fitting.height, 360))
        stack.autoresizingMask = [.width]
        scrollView.documentView = stack
    }

    var selections: [DictionaryImportSelection] {
        rows.map {
            DictionaryImportSelection(preview: $0.preview,
                                      selectedMDDIDs: $0.selectedMDDIDs)
        }
    }

    private func makePreviewBox(_ preview: DictionaryImportPreview) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.wantsLayer = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.cornerRadius = 7
        box.titlePosition = .noTitle

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = content

        let title = NSTextField(labelWithString: preview.displayName)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = preview.displayName
        title.setAccessibilityLabel("词典名称：\(preview.displayName)")
        content.addArrangedSubview(title)
        content.addArrangedSubview(field("原始文件名", preview.originalFileName))
        content.addArrangedSubview(field("MDX 文件大小", byteString(preview.mdxFileSize)))
        content.addArrangedSubview(field(
            "MDict 版本",
            preview.header.engineVersion,
            help: "词典文件声明的 MDict 格式版本。"
        ))
        content.addArrangedSubview(field(
            "编码",
            preview.header.encoding,
            help: "词典正文使用的文字编码。"
        ))
        content.addArrangedSubview(field(
            "压缩",
            preview.header.compression.displayName,
            help: "是否检测到 MDict 压缩记录。"
        ))
        content.addArrangedSubview(field(
            "加密",
            preview.header.isEncrypted ? "是" : "否",
            help: "加密词典可能无法建立索引；导入不会修改原始文件。"
        ))
        content.addArrangedSubview(field(
            "词典类型",
            DictionaryManagerPresentation.queryLevelText(preview.queryLevel)
        ))
        content.addArrangedSubview(field("默认启用", preview.enabled ? "是" : "否"))
        content.addArrangedSubview(field("显示方式", "基础格式显示"))
        content.addArrangedSubview(field("导入后状态", "等待建立索引"))
        content.addArrangedSubview(field("重复状态", "未发现相同内容的已导入词典"))

        let estimated = field("预计所需磁盘空间", "")
        content.addArrangedSubview(estimated)
        let row = PreviewRow(preview: preview, estimatedLabel: estimated)
        rows.append(row)

        let mddTitle = NSTextField(labelWithString: "候选 MDD 文件")
        mddTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        mddTitle.toolTip = "MDD 可包含图片、音频或字体。本阶段仅托管所选文件，不读取其中资源。"
        content.addArrangedSubview(mddTitle)
        if preview.mddCandidates.isEmpty {
            content.addArrangedSubview(secondaryLabel("未发现规范基名匹配的 MDD；可仅导入 MDX。"))
        } else {
            if preview.mddCandidates.count > 1 {
                content.addArrangedSubview(secondaryLabel("检测到多个候选，默认均不选择；请明确勾选需要托管的文件。"))
            }
            for candidate in preview.mddCandidates {
                let button = NSButton(
                    checkboxWithTitle: "\(candidate.fileName)（\(byteString(candidate.fileSize))）",
                    target: self,
                    action: #selector(candidateSelectionChanged(_:))
                )
                button.controlSize = .small
                button.identifier = NSUserInterfaceItemIdentifier(candidate.id)
                button.state = preview.automaticallySelectedMDDIDs.contains(candidate.id) ? .on : .off
                button.toolTip = "选择后会与 MDX 一起复制；本阶段不会读取 MDD 内容。"
                button.setAccessibilityLabel("候选 MDD：\(candidate.fileName)")
                row.candidateButtons[candidate.id] = button
                content.addArrangedSubview(button)
            }
        }
        updateEstimatedSize(for: row)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 630),
            content.widthAnchor.constraint(equalTo: box.widthAnchor)
        ])
        return box
    }

    @objc private func candidateSelectionChanged(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let row = rows.first(where: { $0.candidateButtons[identifier] != nil }) else { return }
        updateEstimatedSize(for: row)
    }

    private func updateEstimatedSize(for row: PreviewRow) {
        row.estimatedLabel.stringValue = "预计所需磁盘空间：" + byteString(
            row.preview.estimatedDiskBytes(selectedMDDIDs: row.selectedMDDIDs)
        )
    }

    private func field(_ name: String, _ value: String,
                       help: String? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: "\(name)：\(value)")
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = help ?? value
        label.setAccessibilityLabel("\(name)：\(value)")
        if let help { label.setAccessibilityHelp(help) }
        return label
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        return label
    }

    private func byteString(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

/// Resizable, screen-bounded import preview. The action bar is outside the scroll view so Import
/// and Cancel remain fully visible even on a small MacBook display with the Dock shown.
@MainActor
final class DictionaryImportPreviewWindowController: NSWindowController {
    let accessory: DictionaryImportPreviewAccessory
    private let onImport: ([DictionaryImportSelection]) -> Void
    private weak var parentWindow: NSWindow?

    init(previews: [DictionaryImportPreview], parentWindow: NSWindow,
         visibleFrameOverride: NSRect? = nil,
         onImport: @escaping ([DictionaryImportSelection]) -> Void) {
        accessory = DictionaryImportPreviewAccessory(previews: previews)
        self.onImport = onImport
        self.parentWindow = parentWindow
        let visible = visibleFrameOverride ?? parentWindow.screen?.visibleFrame ??
            NSScreen.main?.visibleFrame ??
            NSRect(x: 0, y: 0, width: 1_024, height: 700)
        let width = min(CGFloat(760), max(520, visible.width - 80))
        let height = min(CGFloat(640), max(360, visible.height - 80))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = previews.count == 1 ? "导入预览" : "导入预览（\(previews.count) 本词典）"
        window.minSize = NSSize(width: min(520, width), height: min(360, height))
        window.maxSize = NSSize(width: visible.width, height: visible.height)
        super.init(window: window)
        buildContent(previewCount: previews.count)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window, let parentWindow else { return }
        parentWindow.beginSheet(window)
    }

    private func buildContent(previewCount: Int) {
        guard let window else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString:
            previewCount == 1 ? "确认要导入的词典" : "确认要导入的 \(previewCount) 本词典")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "仅检查必要元数据。点击“导入”后会复制文件并自动建立查询索引。")
        explanation.textColor = .secondaryLabelColor
        let rights = NSTextField(wrappingLabelWithString:
            "导入即表示你确认有权在本机使用该词典文件；LocalDictionary 不联网验证文件权利。")
        rights.textColor = .secondaryLabelColor
        rights.font = .systemFont(ofSize: 11)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelImport))
        let confirm = NSButton(title: "导入", target: self, action: #selector(confirmImport))
        confirm.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), cancel, confirm])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.distribution = .fill
        actions.alignment = .centerY
        [title, explanation, rights, actions, accessory.view].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        window.contentView = root
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            accessory.view.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
            accessory.view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            accessory.view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            accessory.view.bottomAnchor.constraint(equalTo: rights.topAnchor, constant: -10),
            rights.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            rights.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            rights.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),
            actions.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }

    @objc private func cancelImport() { finish(importing: false) }
    @objc private func confirmImport() { finish(importing: true) }

    private func finish(importing: Bool) {
        let selections = accessory.selections
        if let parentWindow, let window, window.sheetParent === parentWindow {
            parentWindow.endSheet(window)
        }
        if importing { onImport(selections) }
    }
}

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
