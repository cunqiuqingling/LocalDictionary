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
        guard entries.map({ ObsidianNoteStore.legacyMarker(for: $0.headword) }) == [
            "<!-- LocalDictionary: word=supercilious -->",
            "<!-- LocalDictionary: word=conscientious -->",
            "<!-- LocalDictionary: word=incredulous -->"
        ] else { throw SmokeError.assertionFailed("normalized markers") }

        let promptEntry = StructuredDictionaryEntry(
            headword: "prompt",
            phonetics: ["/prɒmpt/"],
            partsOfSpeech: ["noun"],
            definitions: ["提示"],
            examples: ["The prompt appeared on screen."],
            source: "Oxford"
        )
        let promptBlock = ObsidianNoteStore.markdownBlock(for: promptEntry, newline: "\n")
        guard promptBlock.hasPrefix("## prompt\n"),
              !promptBlock.contains("<!-- LocalDictionary:") else {
            throw SmokeError.assertionFailed("new format has no marker")
        }
        guard ObsidianNoteStore.containsEntry(in: "## Prompt\n", headword: "prompt"),
              ObsidianNoteStore.containsEntry(
                in: ObsidianNoteStore.legacyMarker(for: "prompt"),
                headword: "prompt"
              ) else {
            throw SmokeError.assertionFailed("heading and legacy compatibility")
        }
        let legacyAndHeading = ObsidianNoteStore.legacyMarker(for: "prompt") + "\n\n## prompt\n"
        let markerRemoved = legacyAndHeading.replacingOccurrences(
            of: ObsidianNoteStore.legacyMarker(for: "prompt"),
            with: ""
        )
        guard ObsidianNoteStore.containsEntry(in: markerRemoved, headword: "prompt") else {
            throw SmokeError.assertionFailed("heading survives legacy marker removal")
        }
        guard !ObsidianNoteStore.containsEntry(
            in: "```markdown\n## prompt\n```\n",
            headword: "prompt"
        ), !ObsidianNoteStore.containsEntry(in: "### prompt\n", headword: "prompt"),
           !ObsidianNoteStore.containsEntry(in: "Body prompt and `## prompt`.\n",
                                            headword: "prompt"),
           !ObsidianNoteStore.containsEntry(in: "## prompt details\n", headword: "prompt") else {
            throw SmokeError.assertionFailed("non-heading exclusions")
        }
        guard ObsidianNoteStore.containsEntry(in: "## Mother-in-Law's\n",
                                              headword: "mother-in-law's"),
              !ObsidianNoteStore.containsEntry(in: "    ## prompt\n", headword: "prompt") else {
            throw SmokeError.assertionFailed("headword punctuation and indented code")
        }

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

        let promptURL = workingDirectory.appendingPathComponent("prompt-rules.md")
        try Data().write(to: promptURL, options: .atomic)
        guard try restartedStore.save(promptEntry, to: promptURL) == .saved,
              try restartedStore.save(promptEntry, to: promptURL) == .alreadySaved else {
            throw SmokeError.assertionFailed("heading duplicate save")
        }
        let savedPrompt = try String(contentsOf: promptURL, encoding: .utf8)
        guard !savedPrompt.contains("<!-- LocalDictionary:"),
              exactHeadingCount("prompt", in: savedPrompt) == 1 else {
            throw SmokeError.assertionFailed("prompt written once without marker")
        }

        let noteData = try Data(contentsOf: noteURL)
        guard let note = String(data: noteData, encoding: .utf8) else {
            throw SmokeError.assertionFailed("UTF-8 output")
        }
        for entry in entries {
            guard exactHeadingCount(entry.headword, in: note) == 1,
                  try restartedStore.contains(headword: entry.headword) else {
                throw SmokeError.assertionFailed("saved heading state")
            }
        }
        guard !note.contains("<!-- LocalDictionary:") else {
            throw SmokeError.assertionFailed("new entries contain legacy marker")
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
              exactHeadingCount(entries[0].headword, in: existingCandidate) == 1 else {
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
        guard newNote.hasPrefix("## \(entries[1].headword)"),
              !newNote.contains("<!-- LocalDictionary:"),
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
              exactHeadingCount(entries[2].headword, in: confirmed) == 1 else {
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
        print("ObsidianNoteStoreSmoke: 26/26 passed")
    }

    private static func exactHeadingCount(_ headword: String, in content: String) -> Int {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { $0 == "## \(headword)" }
            .count
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
