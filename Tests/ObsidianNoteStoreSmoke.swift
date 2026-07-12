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

        let existingCandidateURL = workingDirectory.appendingPathComponent("existing-candidate.md")
        let existingCandidateOriginal = "Existing candidate content.\n"
        try Data(existingCandidateOriginal.utf8).write(to: existingCandidateURL, options: .atomic)
        guard try restartedStore.save(entries[0], to: existingCandidateURL) == .saved,
              restartedStore.targetURL == noteURL.standardizedFileURL else {
            throw SmokeError.assertionFailed("candidate save changed current target")
        }
        let existingCandidate = try String(contentsOf: existingCandidateURL, encoding: .utf8)
        guard existingCandidate.hasPrefix(existingCandidateOriginal),
              existingCandidate.contains(ObsidianNoteStore.marker(for: entries[0].headword)) else {
            throw SmokeError.assertionFailed("existing candidate append")
        }
        try restartedStore.rememberTarget(existingCandidateURL)

        let newNoteURL = workingDirectory.appendingPathComponent("new-note.md")
        try? fileManager.removeItem(at: newNoteURL)
        guard try restartedStore.createOrSave(entries[1], at: newNoteURL) == .saved,
              restartedStore.targetURL == existingCandidateURL.standardizedFileURL else {
            throw SmokeError.assertionFailed("new note changed current target early")
        }
        let newNote = try String(contentsOf: newNoteURL, encoding: .utf8)
        guard newNote.hasPrefix(ObsidianNoteStore.marker(for: entries[1].headword)),
              !newNote.hasPrefix("# ") else {
            throw SmokeError.assertionFailed("new note first entry")
        }
        try restartedStore.rememberTarget(newNoteURL)
        guard try restartedStore.contains(headword: entries[1].headword) else {
            throw SmokeError.assertionFailed("new note saved state")
        }

        let confirmedExistingURL = workingDirectory.appendingPathComponent("confirmed-existing.md")
        let confirmedOriginal = "Keep this original text.\n"
        try Data(confirmedOriginal.utf8).write(to: confirmedExistingURL, options: .atomic)
        guard try restartedStore.createOrSave(entries[2], at: confirmedExistingURL) == .saved else {
            throw SmokeError.assertionFailed("confirmed existing save")
        }
        let confirmed = try String(contentsOf: confirmedExistingURL, encoding: .utf8)
        guard confirmed.hasPrefix(confirmedOriginal),
              confirmed.contains(ObsidianNoteStore.marker(for: entries[2].headword)) else {
            throw SmokeError.assertionFailed("confirmed existing content preserved")
        }

        let missingURL = workingDirectory.appendingPathComponent("missing.md")
        try expect(.targetUnavailable) { try restartedStore.save(entries[0], to: missingURL) }
        guard restartedStore.targetURL == newNoteURL.standardizedFileURL else {
            throw SmokeError.assertionFailed("missing candidate changed current target")
        }

        let readOnlyURL = workingDirectory.appendingPathComponent("read-only.md")
        let readOnlyOriginal = Data("Do not damage this file.\n".utf8)
        try readOnlyOriginal.write(to: readOnlyURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyURL.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644],
                                                ofItemAtPath: readOnlyURL.path) }
        try expect(.targetNotWritable) { try restartedStore.save(entries[0], to: readOnlyURL) }
        guard try Data(contentsOf: readOnlyURL) == readOnlyOriginal else {
            throw SmokeError.assertionFailed("read-only file changed")
        }
        guard restartedStore.targetURL == newNoteURL.standardizedFileURL else {
            throw SmokeError.assertionFailed("read-only candidate changed current target")
        }

        try expect(.invalidEntry) {
            try restartedStore.save(StructuredDictionaryEntry(headword: "",
                                                              phonetics: [],
                                                              partsOfSpeech: [],
                                                              definitions: [],
                                                              examples: [],
                                                              source: "Oxford"))
        }
        print("ObsidianNoteStoreSmoke: 16/16 passed")
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
