import AppKit
import UniformTypeIdentifiers

@MainActor
final class ObsidianNotePicker {
    private(set) var isChoosing = false

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
