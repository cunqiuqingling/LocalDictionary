import AppKit
import Foundation

private enum HelpSmokeError: Error {
    case failed(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HelpSmokeError.failed(message) }
}

@MainActor
private func findView(_ identifier: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for subview in root.subviews {
        if let found = findView(identifier, in: subview) { return found }
    }
    return nil
}

@main
struct HelpAndAboutWindowSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let builtIn = HelpAndAboutDocuments(bundle: .main)
        try expect(builtIn.guideSimplifiedChinese.contains("连续按三次 Return") &&
                   builtIn.guideEnglish.contains("Press Return three times"),
                   "built-in guide omitted the explicit triple-Return AI shortcut")
        let documents = HelpAndAboutDocuments(
            guideSimplifiedChinese: "# 使用说明\n\n## 查询\n\n- 本地优先。",
            guideEnglish: "# User Guide\n\n## Lookup\n\n- Local first.",
            privacy: "# Privacy\n\n不会自动上传词典。",
            license: "GNU GENERAL PUBLIC LICENSE\n<https://www.gnu.org/licenses/>",
            thirdPartyNotices: "# Third-Party Notices\n\nmdict-cpp — BSD-3-Clause"
        )
        let metadata = HelpAndAboutMetadata(
            applicationName: "LocalDictionary", version: "0.1", build: "1",
            copyright: "Copyright © 2026 Test Author"
        )
        let controller = HelpAndAboutWindowController(
            uiEnglish: false, metadata: metadata, documents: documents
        )
        guard let window = controller.window, let content = window.contentView,
              let topics = findView("help-about-topics", in: content) as? NSSegmentedControl,
              let textView = findView("help-about-content", in: content) as? NSTextView,
              let scroll = findView("help-about-scroll", in: content) as? NSScrollView,
              let close = findView("help-about-close", in: content) as? NSButton else {
            throw HelpSmokeError.failed("missing AppKit guide/legal controls")
        }
        content.layoutSubtreeIfNeeded()
        try expect(window.title == "使用说明与版权", "localized title")
        try expect(window.styleMask.contains(.resizable), "window must be resizable")
        try expect(window.minSize.width <= 540 && window.minSize.height <= 420,
                   "small-screen minimum size")
        try expect(!textView.isEditable && textView.isSelectable,
                   "document must be read-only and selectable")
        try expect(textView.string.contains("使用说明") &&
                   !textView.string.contains("# 使用说明"),
                   "guide headings must render without Markdown markers")
        try expect(close.title == "关闭", "close button")

        topics.selectedSegment = 1
        topics.sendAction(topics.action, to: topics.target)
        try expect(textView.string.contains("不会自动上传词典"), "privacy tab")
        topics.selectedSegment = 2
        topics.sendAction(topics.action, to: topics.target)
        try expect(textView.string.contains("GNU GENERAL PUBLIC LICENSE") &&
                   textView.string.contains("<https://www.gnu.org/licenses/>"),
                   "license tab must preserve verbatim legal text")
        topics.selectedSegment = 3
        topics.sendAction(topics.action, to: topics.target)
        try expect(textView.string.contains("mdict-cpp"), "third-party tab")
        try expect(!topics.hasAmbiguousLayout && !scroll.hasAmbiguousLayout &&
                   !close.hasAmbiguousLayout && scroll.frame.height >= 220 &&
                   content.bounds.contains(scroll.frame),
                   "key help-window controls are ambiguous or outside the scrollable layout")

        let english = HelpAndAboutWindowController(
            uiEnglish: true, metadata: metadata, documents: documents
        )
        try expect(english.window?.title == "User Guide & Legal", "English title")
        print("HelpAndAboutWindowSmoke PASS")
    }
}
