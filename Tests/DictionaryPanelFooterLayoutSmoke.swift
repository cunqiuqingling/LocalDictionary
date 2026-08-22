import AppKit

private enum FooterSmokeFailure: Error { case failed(String) }

private func footerExpect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw FooterSmokeFailure.failed(message) }
}

@main
private enum DictionaryPanelFooterLayoutSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for panelWidth in [CGFloat(420), 360, 320] {
                let container = NSView(frame: NSRect(
                    x: 0, y: 0, width: panelWidth, height: 300
                ))
                container.appearance = NSAppearance(named: appearanceName)
                let footer = NSStackView()
                let local = verticalGroup(
                    heading: "本地功能",
                    buttons: ["建立中文反向索引…", "下载 Apple 离线翻译语言包（英语 ⇄ 中文）"]
                )
                let ai = verticalGroup(
                    heading: "AI 功能（仅点击后联网）",
                    buttons: ["AI 双语解释", "逐句 AI 深度分析", "打开 AI 设置…"]
                )
                let host = NSTextField(wrappingLabelWithString:
                    "正在等待 macOS 准备 Apple 离线翻译语言资源…")
                let status = NSTextField(wrappingLabelWithString:
                    "首次准备可能联网；只有用户点击 AI 按钮后才会访问 Provider。")
                status.maximumNumberOfLines = 3
                DictionaryPanelFooterLayout.assemble(
                    footer: footer, localGroup: local,
                    translationHostView: host, statusLabel: status, aiGroup: ai
                )
                container.addSubview(footer)
                NSLayoutConstraint.activate([
                    footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    footer.topAnchor.constraint(equalTo: container.topAnchor),
                    footer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
                container.layoutSubtreeIfNeeded()
                let fittingHeight = footer.fittingSize.height
                try footerExpect(fittingHeight > 0 && fittingHeight < 260,
                                 "footer reserved excessive blank height: \(fittingHeight)")
                try footerExpect(!allSubviews(container).contains(where: \.hasAmbiguousLayout),
                                 "ambiguous footer at \(panelWidth) \(appearanceName.rawValue)")
                for button in allSubviews(container).compactMap({ $0 as? NSButton }) {
                    let frame = button.convert(button.bounds, to: container)
                    try footerExpect(!button.isHidden && frame.minX >= -8 &&
                        frame.maxX <= container.bounds.maxX + 8,
                        "clipped footer button '\(button.title)' frame=\(frame) " +
                        "container=\(container.bounds) at width \(panelWidth)")
                    try footerExpect(button.title == button.attributedTitle.string,
                                     "button title was truncated in its model")
                }
            }
        }
        print("Dictionary panel production footer layout smoke: PASS")
    }

    @MainActor
    private static func verticalGroup(heading: String, buttons: [String]) -> NSStackView {
        let group = NSStackView()
        let label = NSTextField(labelWithString: heading)
        group.addArrangedSubview(label)
        for title in buttons {
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .rounded
            button.controlSize = .small
            group.addArrangedSubview(button)
        }
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        return group
    }

    @MainActor
    private static func allSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }
}
