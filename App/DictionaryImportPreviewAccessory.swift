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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 470))
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
        stack.frame = NSRect(x: 0, y: 0, width: 680, height: max(fitting.height, 450))
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
        content.addArrangedSubview(title)
        content.addArrangedSubview(field("原始文件名", preview.originalFileName))
        content.addArrangedSubview(field("MDX 文件大小", byteString(preview.mdxFileSize)))
        content.addArrangedSubview(field("MDict 版本", preview.header.engineVersion))
        content.addArrangedSubview(field("编码", preview.header.encoding))
        content.addArrangedSubview(field("压缩", preview.header.compression.displayName))
        content.addArrangedSubview(field("加密", preview.header.isEncrypted ? "是" : "否"))
        content.addArrangedSubview(field("文件摘要", String(preview.mdxSHA256.prefix(16)) + "…"))
        content.addArrangedSubview(field("查询级别", preview.queryLevel.displayName))
        content.addArrangedSubview(field("默认启用", preview.enabled ? "是" : "否"))
        content.addArrangedSubview(field("Formatter", preview.formatterIdentifier))
        content.addArrangedSubview(field("导入后状态", preview.state.displayName))

        let estimated = field("预计所需磁盘空间", "")
        content.addArrangedSubview(estimated)
        let row = PreviewRow(preview: preview, estimatedLabel: estimated)
        rows.append(row)

        let mddTitle = NSTextField(labelWithString: "候选 MDD 文件")
        mddTitle.font = .systemFont(ofSize: 12, weight: .semibold)
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
                row.candidateButtons[candidate.id] = button
                content.addArrangedSubview(button)
            }
        }
        updateEstimatedSize(for: row)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 650),
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

    private func field(_ name: String, _ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: "\(name)：\(value)")
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
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

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
