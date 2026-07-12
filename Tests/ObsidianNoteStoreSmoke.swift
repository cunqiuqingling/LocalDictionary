import Foundation

@main
struct ObsidianNoteStoreSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw SmokeError.invalidArguments }
        let entriesURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let workingDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workingDirectory,
                                        withIntermediateDirectories: true)

        let entries = try JSONDecoder().decode(
            [StructuredDictionaryEntry].self,
            from: Data(contentsOf: entriesURL)
        )
        guard entries.map({ ObsidianNoteStore.marker(for: $0.headword) }) == [
            "<!-- LocalDictionary: word=supercilious -->",
            "<!-- LocalDictionary: word=conscientious -->",
            "<!-- LocalDictionary: word=incredulous -->"
        ] else { throw SmokeError.assertionFailed("normalized markers") }

        let suiteName = "LocalDictionary.ObsidianNoteStoreSmoke"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SmokeError.assertionFailed("test defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let noteURL = workingDirectory.appendingPathComponent("temporary-note.md")
        try Data("# Temporary vocabulary\r\n".utf8).write(to: noteURL, options: .atomic)
        let store = ObsidianNoteStore(defaults: defaults)
        try store.rememberTarget(noteURL)

        let restartedStore = ObsidianNoteStore(defaults: defaults)
        guard restartedStore.targetURL == noteURL.standardizedFileURL else {
            throw SmokeError.assertionFailed("target path persistence")
        }

        for entry in entries {
            guard try restartedStore.save(entry) == .saved else {
                throw SmokeError.assertionFailed("initial save")
            }
        }
        guard try restartedStore.save(entries[0]) == .alreadySaved else {
            throw SmokeError.assertionFailed("duplicate detection")
        }

        let noteData = try Data(contentsOf: noteURL)
        guard let note = String(data: noteData, encoding: .utf8) else {
            throw SmokeError.assertionFailed("UTF-8 output")
        }
        for entry in entries {
            let marker = ObsidianNoteStore.marker(for: entry.headword)
            guard note.components(separatedBy: marker).count == 2,
                  try restartedStore.contains(headword: entry.headword) else {
                throw SmokeError.assertionFailed("saved marker state")
            }
        }
        guard note.range(of: "[\u{4E00}-\u{9FFF}]", options: .regularExpression) != nil,
              note.contains("/") && note.contains("- 例句：") else {
            throw SmokeError.assertionFailed("Chinese, phonetics, and examples")
        }
        guard !note.replacingOccurrences(of: "\r\n", with: "").contains("\n") else {
            throw SmokeError.assertionFailed("original CRLF style")
        }

        let unsaved = StructuredDictionaryEntry(headword: "prodigality",
                                                phonetics: [],
                                                partsOfSpeech: [],
                                                definitions: [],
                                                examples: [],
                                                source: "Oxford")
        guard try !restartedStore.contains(headword: unsaved.headword) else {
            throw SmokeError.assertionFailed("unsaved star state")
        }

        let missingURL = workingDirectory.appendingPathComponent("missing.md")
        try restartedStore.rememberTarget(missingURL)
        try expect(.targetUnavailable) { try restartedStore.save(entries[0]) }

        let readOnlyURL = workingDirectory.appendingPathComponent("read-only.md")
        let readOnlyOriginal = Data("Do not damage this file.\n".utf8)
        try readOnlyOriginal.write(to: readOnlyURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyURL.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644],
                                                ofItemAtPath: readOnlyURL.path) }
        try restartedStore.rememberTarget(readOnlyURL)
        try expect(.targetNotWritable) { try restartedStore.save(entries[0]) }
        guard try Data(contentsOf: readOnlyURL) == readOnlyOriginal else {
            throw SmokeError.assertionFailed("read-only file changed")
        }

        try expect(.invalidEntry) {
            try restartedStore.save(StructuredDictionaryEntry(headword: "",
                                                              phonetics: [],
                                                              partsOfSpeech: [],
                                                              definitions: [],
                                                              examples: [],
                                                              source: "Oxford"))
        }
        print("ObsidianNoteStoreSmoke: 10/10 passed")
    }

    private static func expect(_ expected: ObsidianNoteStoreError,
                               operation: () throws -> Any) throws {
        do {
            _ = try operation()
            throw SmokeError.assertionFailed("expected \(expected)")
        } catch let error as ObsidianNoteStoreError where error == expected {
            return
        }
    }

    enum SmokeError: Error {
        case invalidArguments
        case assertionFailed(String)
    }
}
