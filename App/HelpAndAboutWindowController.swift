import AppKit

struct HelpAndAboutMetadata: Equatable {
    let applicationName: String
    let version: String
    let build: String
    let copyright: String

    init(bundle: Bundle = .main) {
        applicationName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "LocalDictionary"
        version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "—"
        build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
        copyright = (bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String)
            ?? "Copyright © 2026 liuzhentie（刘震铁，aka “cunqiu”）"
    }

    init(applicationName: String, version: String, build: String, copyright: String) {
        self.applicationName = applicationName
        self.version = version
        self.build = build
        self.copyright = copyright
    }
}

struct HelpAndAboutDocuments: Equatable {
    let guideSimplifiedChinese: String
    let guideEnglish: String
    let privacy: String
    let license: String
    let thirdPartyNotices: String

    init(bundle: Bundle = .main) {
        guideSimplifiedChinese = Self.chineseGuide
        guideEnglish = Self.englishGuide
        privacy = Self.load(
            resource: "Privacy", extension: "md", bundle: bundle,
            fallback: "隐私说明未能从 App Bundle 中读取。请重新安装经过完整性验证的 App。"
        )
        license = Self.load(
            resource: "LICENSE", extension: "md", bundle: bundle,
            fallback: "GPL-3.0-only 完整许可证未能从 App Bundle 中读取。"
        )
        thirdPartyNotices = Self.load(
            resource: "THIRD_PARTY_NOTICES", extension: "md", bundle: bundle,
            fallback: "第三方许可证通知未能从 App Bundle 中读取。"
        )
    }

    init(guideSimplifiedChinese: String, guideEnglish: String, privacy: String,
         license: String, thirdPartyNotices: String) {
        self.guideSimplifiedChinese = guideSimplifiedChinese
        self.guideEnglish = guideEnglish
        self.privacy = privacy
        self.license = license
        self.thirdPartyNotices = thirdPartyNotices
    }

    private static func load(resource: String, extension fileExtension: String,
                             bundle: Bundle, fallback: String) -> String {
        guard let url = bundle.url(
            forResource: resource, withExtension: fileExtension,
            subdirectory: "ReleaseLegal"
        ), let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty else {
            return fallback
        }
        return value
    }

    private static let chineseGuide = #"""
    # LocalDictionary 使用说明

    ## 1. 开始使用

    - LocalDictionary 是原生 macOS 菜单栏词典。点击菜单栏图标并选择“显示词典”，即可手动输入单词、短语或长文本。
    - Option + Space 用于查询其他应用中当前选中的文字。首次使用时，macOS 可能要求授予辅助功能权限；未授权时仍可手动输入查询。
    - App 不请求屏幕录制、麦克风或系统录音权限。扫描版 PDF 当前不包含 OCR。

    ## 2. 母语、学习语言与界面语言

    - 母语决定用户主要阅读的解释语言；学习语言决定词汇和句法分析的学习对象；界面语言控制菜单和按钮文字。
    - 首次发布只开放经过完整验证的简体中文与 English 组合。Apple 系统离线翻译的语言对根据当前母语和学习语言实时生成，不由 AI 解释语言决定。
    - 查询母语内容时翻译到学习语言；查询学习语言内容时翻译到母语。混合文本会按产品界面提供相应语言版本。

    ## 3. 本地词典查询与管理

    - App 可以导入用户主动选择的 MDX 文件，并在本机托管目录中自动建立独立 SQLite 查询索引。原始导入文件不会因托管副本的建立或移除而被修改。
    - “词典管理”可以查看查询状态、启用或停用词典，并在不同来源之间调整统一查询顺序。同等匹配质量按用户设置的顺序显示。
    - 支持中文释义的双语词典可以建立中文反向索引。反向结果是本地候选，不代表唯一答案；低置信或长说明中的偶然文字不会作为精确词义显示。
    - App 不内置商业词典，不提供商业 MDX/MDD 下载。用户需自行确认导入词典的合法来源与本机使用权。

    ## 4. Apple 系统离线翻译

    - 基础翻译使用 macOS Translation framework。相关语言包已经安装时，母语单词、短语和句子查询可以自动尝试本机翻译；中文反向词典候选随后显示。
    - 缺少语言包时，App 不会静默下载。只有用户主动点击“准备离线语言包”后，才进入 Apple 管理的系统准备流程。
    - 单次翻译超时、取消或查询被替换只结束当前操作，不应使后续查询永久失效。

    ## 5. 应用内划词

    - 在词典正文内选择单个词时，App 优先查询已启用的本地词典；存在可靠本地结果时不会自动联网调用第三方 AI。
    - 选择中文或其他母语短语时，先显示可用的 Apple 本机离线翻译，再提供“AI 双语解释”按钮。
    - 多词短语或句子不会被逐字拼成假释义。第三方 AI 只有在用户明确点击按钮后才会联网。
    - 同一选区只保留一个内联卡片；关闭卡片或切换选区后，旧异步结果不会写入新选区。

    ## 6. 长文本学习

    - 长文本页面依次提供离线基础翻译、最多 15 个重点词汇、基础结构分析、AI 深度翻译和逐句 AI 深度分析。
    - 本地结构分析采用“正确优先”原则：无法可靠识别时会降低置信度或不显示，不把规则拼接结果冒充完整机器翻译。
    - 学习语言文本是逐句 AI 分析的对象；解释主要使用母语，并可引用学习语言片段。

    ## 7. 可选第三方 AI

    - AI 功能默认不自动联网。只有点击“AI 双语解释”“AI 深度翻译”或“逐句 AI 深度分析”等明确按钮后，当前查询内容才会发送给所选 Provider。
    - 对同一条未改动的查询连续按三次 Return，会把第三次 Return 视为用户明确启动“AI 双语解释”；前两次仍只执行本地词典和 Apple 离线翻译。查询内容改变或按键间隔过长会重新计数。
    - 未找到本地词条或基础翻译时，结果区域会提示这一快捷操作；也可以直接点击“AI 双语解释”，两种方式都不会静默自动联网。
    - API Key 保存在 macOS Keychain；Provider 名称、Base URL、模型和开关等非敏感设置保存在本机。项目不内置 API Key。
    - DeepSeek、Google Gemini 和兼容接口的实际可用性、计费、日志与隐私政策由相应服务商决定。LocalDictionary 不展示 Provider 的内部推理内容。
    - Provider 返回安全、非空的普通文本或 Markdown 时，App 会尽量兼容显示。当前查询存在 AI 结果时，可用“清除此条 AI 缓存”移除该查询的 AI 产物，而不删除本地词典或 Apple 离线翻译结果。

    ## 8. 收藏与 Markdown 笔记

    - 星标用于收藏当前词条或长文本。启用“收藏时加入 AI 内容”后，收藏可包含用户已经主动生成的 AI 结果。
    - Obsidian/Markdown 写入只操作用户明确选择或创建的单个 Markdown 文件，不自动扫描整个 Vault，也不删除已经写出的笔记内容。

    ## 9. 开放资源中心

    - 首次发布的 Starter Catalog 只显示经过完整安装、重启、查询和移除生命周期验证的 Princeton WordNet 与 GNU GCIDE。
    - 只有用户点击具体资源的安装按钮后，App 才连接编译时固定的官方 HTTPS 主机，并校验版本、大小、SHA-256、格式和许可证 metadata。
    - App Bundle 不包含这些词典正文；资源下载和转换均不影响本地 MDX 导入功能。

    ## 10. 隐私与数据边界

    - 本地词典查询、索引、Apple 系统离线翻译、重点词汇和基础结构提示在设备上处理。
    - App 当前没有项目自有服务器、广告、用户分析、自动遥测或自动崩溃上传。
    - App 不会把整本词典、词典路径、未选中的页面内容、Obsidian 笔记正文或查询历史自动发送给 AI Provider。
    - 详细边界请查看本窗口的“隐私”标签。

    ## 11. 首次打开与已知限制

    - Community unsigned 构建没有 Developer ID 签名或 Apple 公证。若 macOS 首次阻止打开，只建议使用“系统设置 → 隐私与安全性 → 仍要打开”；不建议关闭 Gatekeeper、使用 sudo 或通过 xattr 绕过。
    - 当前要求 macOS 15.0 或以上及 Apple Silicon（arm64）。Windows、Linux、Intel Mac、OCR 和扫描版 PDF 取词不在首发范围。
    - 部分应用若无法通过辅助功能接口提供选区，可先复制文字，再粘贴到搜索框。
    """#

    private static let englishGuide = #"""
    # LocalDictionary User Guide

    ## 1. Getting Started

    - LocalDictionary is a native macOS menu-bar dictionary. Choose “Show Dictionary” to enter a word, phrase, or longer text manually.
    - Option + Space looks up the current selection in another app. macOS may request Accessibility permission; manual input remains available without it.
    - The app does not request Screen Recording, microphone, or system-audio access. OCR is not included.

    ## 2. Language Roles

    - Native Language controls the language used for most explanations. Learning Language is the language being studied. UI Language controls menus and buttons.
    - The first release exposes only the fully validated Simplified Chinese and English pair. Apple offline translation follows the current Native/Learning pair and is independent of the AI explanation language.

    ## 3. Local Dictionaries

    - User-selected MDX files can be imported and indexed locally. The managed copy and its SQLite index do not modify the original import file.
    - Dictionary Manager controls availability and one unified query order across legacy, imported, and open-resource dictionaries.
    - Bilingual dictionaries with reliable Chinese glosses can build a local reverse index. Precision takes priority over returning many weak candidates.
    - No commercial dictionary content is bundled or offered for download.

    ## 4. Apple Offline Translation

    - When the required Apple language pack is installed, native-language words, phrases, and sentences can be translated locally before reverse-dictionary candidates are shown.
    - Missing language packs are never downloaded silently. Preparation begins only after the user explicitly chooses to prepare the pack.

    ## 5. Inline Lookup

    - A selected word uses enabled local dictionaries first. A reliable local hit does not trigger third-party AI automatically.
    - Native-language phrases show available Apple offline translation first, followed by an explicit AI Bilingual Explanation action.
    - Each selection owns one compact card. Results from an older selection cannot replace the current card.

    ## 6. Long-Text Learning

    - Long text provides offline translation, up to 15 key terms, a confidence-first local structure hint, AI Deep Translation, and per-sentence AI analysis.
    - AI analysis is centered on the Learning Language study text while explanations primarily use the Native Language.

    ## 7. Optional AI

    - AI never runs merely because text was selected or queried. Content is sent only after an explicit AI action.
    - Press Return three times without changing the query to explicitly start AI Bilingual Explanation on the third press. The first two presses remain local/Apple-only; editing the query or waiting too long resets the sequence.
    - A local miss shows this shortcut as a hint. The visible AI Bilingual Explanation button remains available as the equivalent explicit action.
    - API keys are stored in macOS Keychain. Provider/model settings remain local. No API key is bundled.
    - Safe visible plain text and Markdown are displayed through a bounded compatibility path. Provider reasoning is not shown.
    - “Clear AI Cache for This Query” removes current-query AI artifacts while preserving local and Apple offline results.

    ## 8. Favorites, Notes, and Resources

    - Favorites can optionally include AI content that the user already generated.
    - Markdown export writes only to a file explicitly selected or created by the user; it does not scan an entire Obsidian vault.
    - The v0.1 Starter Catalog exposes only Princeton WordNet and GNU GCIDE. Downloads start only after an explicit install action and are verified before local conversion.

    ## 9. Privacy and First Launch

    - Local lookup, indexing, Apple offline translation, vocabulary extraction, and local structure hints run on the device.
    - The app currently has no project-operated server, advertising, analytics, automatic telemetry, or automatic crash upload.
    - Community unsigned builds are not Developer ID signed or notarized. If macOS blocks first launch, use System Settings → Privacy & Security → Open Anyway; do not disable Gatekeeper or use sudo/xattr bypasses.
    - The first release requires macOS 15.0 or later on Apple Silicon (arm64).
    """#
}

@MainActor
final class HelpAndAboutWindowController: NSWindowController, NSWindowDelegate {
    private enum Topic: Int, CaseIterable {
        case guide
        case privacy
        case license
        case thirdParty
    }

    private let uiEnglish: Bool
    private let metadata: HelpAndAboutMetadata
    private let documents: HelpAndAboutDocuments
    private let topicControl: NSSegmentedControl
    private let textView = NSTextView()
    private var hasPositionedWindow = false

    init(uiEnglish: Bool, bundle: Bundle = .main,
         metadata: HelpAndAboutMetadata? = nil,
         documents: HelpAndAboutDocuments? = nil) {
        self.uiEnglish = uiEnglish
        self.metadata = metadata ?? HelpAndAboutMetadata(bundle: bundle)
        self.documents = documents ?? HelpAndAboutDocuments(bundle: bundle)
        topicControl = NSSegmentedControl(
            labels: uiEnglish
                ? ["User Guide", "Privacy", "Copyright & License", "Third Party"]
                : ["使用说明", "隐私", "版权与许可", "第三方"],
            trackingMode: .selectOne, target: nil, action: nil
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true
        )
        super.init(window: window)
        configureWindow(window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        fitInsideVisibleScreen(window)
        if !hasPositionedWindow {
            window.center()
            hasPositionedWindow = true
        }
        updateDocument()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = t("使用说明与版权", "User Guide & Legal")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 540, height: 420)
        window.setFrameAutosaveName("LocalDictionary.HelpAndAbout")
        window.setAccessibilityIdentifier("help-about-window")

        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
            ?? NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(t("LocalDictionary 应用图标", "LocalDictionary app icon"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84)
        ])

        let title = NSTextField(labelWithString: metadata.applicationName)
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.setAccessibilityIdentifier("help-about-app-name")
        let version = NSTextField(labelWithString: t(
            "版本 \(metadata.version)（build \(metadata.build)）",
            "Version \(metadata.version) (build \(metadata.build))"
        ))
        version.font = .systemFont(ofSize: 13, weight: .semibold)
        version.textColor = .secondaryLabelColor
        version.setAccessibilityIdentifier("help-about-version")
        let copyright = NSTextField(wrappingLabelWithString: metadata.copyright)
        copyright.font = .systemFont(ofSize: 12)
        copyright.textColor = .secondaryLabelColor
        copyright.setAccessibilityIdentifier("help-about-copyright")
        let licenseSummary = NSTextField(wrappingLabelWithString: t(
            "原创项目代码采用 GPL-3.0-only；第三方代码和词典数据保留各自权利与许可证。",
            "Original project code is GPL-3.0-only; third-party code and dictionary data retain their own rights and licenses."
        ))
        licenseSummary.font = .systemFont(ofSize: 12)
        licenseSummary.textColor = .secondaryLabelColor
        licenseSummary.maximumNumberOfLines = 2

        let headerText = NSStackView(views: [title, version, copyright, licenseSummary])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 3
        let header = NSStackView(views: [icon, headerText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 18

        topicControl.target = self
        topicControl.action = #selector(topicChanged)
        topicControl.selectedSegment = Topic.guide.rawValue
        topicControl.segmentStyle = .rounded
        topicControl.setAccessibilityIdentifier("help-about-topics")

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityIdentifier("help-about-content")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.setAccessibilityIdentifier("help-about-scroll")

        let close = NSButton(
            title: t("关闭", "Close"), target: self, action: #selector(closeWindow)
        )
        close.keyEquivalent = "\r"
        close.setAccessibilityIdentifier("help-about-close")
        let footer = NSStackView(views: [flexibleSpacer(), close])
        footer.orientation = .horizontal

        let root = NSStackView(views: [header, topicControl, scrollView, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        topicControl.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        window.contentView = content
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            topicControl.widthAnchor.constraint(equalTo: header.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: header.widthAnchor),
            footer.widthAnchor.constraint(equalTo: header.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        updateDocument()
    }

    @objc private func topicChanged() { updateDocument() }

    @objc private func closeWindow() { close() }

    private func updateDocument() {
        let topic = Topic(rawValue: topicControl.selectedSegment) ?? .guide
        let value: String
        let preserveVerbatimLayout: Bool
        switch topic {
        case .guide:
            value = uiEnglish ? documents.guideEnglish : documents.guideSimplifiedChinese
            preserveVerbatimLayout = false
        case .privacy:
            value = documents.privacy
            preserveVerbatimLayout = false
        case .license:
            let summary = t(
                "版权与许可\n\n\(metadata.copyright)\n\nLocalDictionary 原创项目代码采用 GPL-3.0-only。在适用法律允许的范围内，本程序不附带任何保证。以下为随 App 打包的完整许可证文本。\n\n",
                "Copyright & License\n\n\(metadata.copyright)\n\nOriginal LocalDictionary project code is GPL-3.0-only. To the extent permitted by applicable law, the program is provided without warranty. The complete bundled license follows.\n\n"
            )
            value = summary + documents.license
            preserveVerbatimLayout = true
        case .thirdParty:
            value = documents.thirdPartyNotices
            preserveVerbatimLayout = false
        }
        textView.textStorage?.setAttributedString(
            Self.attributedDocument(value, preserveVerbatimLayout: preserveVerbatimLayout)
        )
        textView.scrollToBeginningOfDocument(nil)
    }

    private static func attributedDocument(
        _ source: String, preserveVerbatimLayout: Bool
    ) -> NSAttributedString {
        if preserveVerbatimLayout {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 1.5
            paragraph.paragraphSpacing = 2
            return NSAttributedString(string: source, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        }

        let output = NSMutableAttributedString()
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if output.length > 0, !output.string.hasSuffix("\n\n") {
                    output.append(NSAttributedString(string: "\n"))
                }
                continue
            }

            let heading = headingContent(trimmed)
            var text = heading?.text ?? trimmed
            var prefix = ""
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 1.5
            paragraph.paragraphSpacing = heading == nil ? 5 : 8
            if heading == nil, text.hasPrefix("- ") {
                text.removeFirst(2)
                prefix = "• "
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = 18
            }
            text = plainInlineMarkdown(text)
            let font: NSFont
            if let heading {
                let sizes: [CGFloat] = [22, 18, 16, 14.5, 13.5, 13]
                font = .systemFont(
                    ofSize: sizes[min(max(heading.level - 1, 0), sizes.count - 1)],
                    weight: heading.level <= 2 ? .bold : .semibold
                )
            } else {
                font = .systemFont(ofSize: 13)
            }
            output.append(NSAttributedString(string: prefix + text + "\n", attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        return output
    }

    private static func headingContent(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.count > level else { return nil }
        let boundary = line.index(line.startIndex, offsetBy: level)
        guard line[boundary].isWhitespace else { return nil }
        let text = line[boundary...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func plainInlineMarkdown(_ source: String) -> String {
        source
            .replacingOccurrences(
                of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1（$2）",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"<((?:https?://)[^>]+)>"#, with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    private func fitInsideVisibleScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 18, dy: 18)
        var frame = window.frame
        frame.size.width = min(max(frame.width, window.minSize.width), visible.width)
        frame.size.height = min(max(frame.height, window.minSize.height), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func t(_ chinese: String, _ english: String) -> String {
        uiEnglish ? english : chinese
    }
}
