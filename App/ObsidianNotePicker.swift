import AppKit
import UniformTypeIdentifiers

final class ObsidianNotePicker {
    private(set) var isChoosing = false

    func chooseTarget(for store: ObsidianNoteStore) -> Bool {
        guard !isChoosing else { return false }
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

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try store.rememberTarget(url)
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法选择目标笔记"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }
}
