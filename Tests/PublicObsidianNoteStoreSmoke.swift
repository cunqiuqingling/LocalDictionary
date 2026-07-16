import Foundation

private enum PublicObsidianSmokeError: Error {
    case failed(String)
}

@main
private struct PublicObsidianNoteStoreSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw PublicObsidianSmokeError.failed("missing isolated working directory")
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let suiteName = "LocalDictionary.PublicObsidianSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PublicObsidianSmokeError.failed("cannot create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let noteURL = root.appendingPathComponent("synthetic-note.md")
        try Data("# Synthetic vocabulary\r\n".utf8).write(to: noteURL, options: .atomic)

        let store = ObsidianNoteStore(defaults: defaults)
        try store.rememberTarget(noteURL)

        let entry = StructuredDictionaryEntry(
            headword: "sample",
            phonetics: ["/ˈsæmpəl/"],
            partsOfSpeech: ["noun"],
            definitions: ["合成测试条目"],
            examples: ["This is a synthetic example."],
            source: "Synthetic Dictionary"
        )

        guard try store.save(entry) == .saved,
              try store.save(entry) == .alreadySaved,
              try store.contains(headword: "SAMPLE") else {
            throw PublicObsidianSmokeError.failed("save or duplicate detection failed")
        }

        let content = try String(contentsOf: noteURL, encoding: .utf8)
        guard content.contains("## sample\r\n"),
              content.contains("### Synthetic Dictionary\r\n"),
              content.contains("合成测试条目"),
              content.contains("This is a synthetic example."),
              !content.contains("<!-- LocalDictionary:") else {
            throw PublicObsidianSmokeError.failed("Markdown output is incomplete or unsafe")
        }

        guard !ObsidianNoteStore.containsEntry(
            in: "```markdown\n## hidden\n```\n",
            headword: "hidden"
        ), ObsidianNoteStore.containsEntry(in: "## Mother-in-Law's\n",
                                           headword: "mother-in-law's") else {
            throw PublicObsidianSmokeError.failed("heading detection boundary failed")
        }

        let restarted = ObsidianNoteStore(defaults: defaults)
        guard restarted.targetURL == noteURL.standardizedFileURL,
              try restarted.contains(headword: entry.headword) else {
            throw PublicObsidianSmokeError.failed("isolated target persistence failed")
        }

        print("Public Obsidian note-store smoke passed")
    }
}
