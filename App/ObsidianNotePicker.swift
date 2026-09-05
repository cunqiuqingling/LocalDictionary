import AppKit
import UniformTypeIdentifiers

@MainActor
final class ObsidianNotePicker {
    private(set) var isChoosing = false
    private let isObsidianInstalled: () -> Bool
    private let showMissingObsidian: () -> Void

    init(isObsidianInstalled: @escaping () -> Bool = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }, showMissingObsidian: @escaping () -> Void = {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "请下载obsidian笔记库后进行收藏"
        alert.informativeText = "安装并打开 Obsidian，创建或打开一个笔记库，再点击星号选择库中的 Markdown 笔记。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }) {
        self.isObsidianInstalled = isObsidianInstalled
        self.showMissingObsidian = showMissingObsidian
    }

    // Resolve on each action so installing Obsidian does not require restarting this app.
    func ensureObsidianAvailable() -> Bool {
        if isObsidianInstalled() { return true }
        showMissingObsidian()
        return false
    }

    func chooseTarget(for store: ObsidianNoteStore) -> Bool {
        guard let url = chooseExistingNote(initialDirectory: store.targetURL?.deletingLastPathComponent()) else {
            return false
        }
        do {
            try store.rememberTarget(url)
            return true
        } catch {
            showSelectionError(error)
            return false
        }
    }

    func chooseExistingNote(initialDirectory: URL?) -> URL? {
        guard ensureObsidianAvailable() else { return nil }
        guard !isChoosing else { return nil }
        isChoosing = true
        defer { isChoosing = false }

        let panel = NSOpenPanel()
        panel.title = "选择 Obsidian 笔记"
        panel.message = "选择一个用于保存词条的 Markdown 文件。"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = validDirectory(initialDirectory)

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseNewNote(initialDirectory: URL?) -> URL? {
        guard ensureObsidianAvailable() else { return nil }
        guard !isChoosing else { return nil }
        isChoosing = true
        defer { isChoosing = false }

        let panel = NSSavePanel()
        panel.title = "新建 Obsidian 笔记"
        panel.message = "选择 Markdown 笔记的名称和保存位置。"
        panel.prompt = "保存"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Vocabulary.md"
        panel.isExtensionHidden = false
        panel.directoryURL = validDirectory(initialDirectory)

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func validDirectory(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    private func showSelectionError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法选择目标笔记"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
