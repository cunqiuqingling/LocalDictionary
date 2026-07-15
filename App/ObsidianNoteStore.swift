import Foundation

struct StructuredPartOfSpeechSense: Codable, Equatable {
    let definition: String
    let labels: [String]
    let examples: [String]
    let number: Int
    let indentationLevel: Int
}

struct StructuredPartOfSpeechSection: Codable, Equatable {
    let partOfSpeech: String
    let senses: [StructuredPartOfSpeechSense]
}

struct StructuredSemanticExample: Codable, Equatable {
    let english: String
    let translations: [String]
}

struct StructuredSemanticRelationGroup: Codable, Equatable {
    let kind: String
    let title: String
    let values: [String]
}

struct StructuredSemanticSense: Codable, Equatable {
    let number: String
    let labels: [String]
    let definitionEnglish: String
    let definitionChinese: [String]
    let grammarPatterns: [String]
    let examples: [StructuredSemanticExample]
    let relations: [StructuredSemanticRelationGroup]
    let subsenses: [StructuredSemanticSense]
}

struct StructuredSemanticDerivative: Codable, Equatable {
    let headword: String
    let partOfSpeech: String
    let pronunciations: [String]
    let summary: String
    let sourceHeadword: String
    let sourcePartOfSpeech: String
}

struct StructuredSemanticPartOfSpeechSection: Codable, Equatable {
    let partOfSpeech: String
    let pronunciations: [String]
    let grammarLabels: [String]
    let senses: [StructuredSemanticSense]
    let relations: [StructuredSemanticRelationGroup]
    let derivatives: [StructuredSemanticDerivative]
}

struct StructuredSemanticEntry: Codable, Equatable {
    let inflections: [String]
    let partOfSpeechSections: [StructuredSemanticPartOfSpeechSection]
    let entryLevelRelations: [StructuredSemanticRelationGroup]
    let derivatives: [StructuredSemanticDerivative]

    var hasContent: Bool {
        !inflections.isEmpty || !partOfSpeechSections.isEmpty ||
            !entryLevelRelations.isEmpty || !derivatives.isEmpty
    }
}

struct StructuredDictionarySource: Codable, Equatable {
    let phonetics: [String]
    let partsOfSpeech: [String]
    let definitions: [String]
    let examples: [String]
    let source: String
    let partOfSpeechSections: [StructuredPartOfSpeechSection]?
    let semanticEntry: StructuredSemanticEntry?

    init(phonetics: [String],
         partsOfSpeech: [String],
         definitions: [String],
         examples: [String],
         source: String,
         partOfSpeechSections: [StructuredPartOfSpeechSection]? = nil,
         semanticEntry: StructuredSemanticEntry? = nil) {
        self.phonetics = phonetics
        self.partsOfSpeech = partsOfSpeech
        self.definitions = definitions
        self.examples = examples
        self.source = source
        self.partOfSpeechSections = partOfSpeechSections
        self.semanticEntry = semanticEntry
    }
}

struct StructuredDictionaryEntry: Codable, Equatable {
    let headword: String
    let phonetics: [String]
    let partsOfSpeech: [String]
    let definitions: [String]
    let examples: [String]
    let source: String
    let partOfSpeechSections: [StructuredPartOfSpeechSection]?
    let semanticEntry: StructuredSemanticEntry?
    let additionalSources: [StructuredDictionarySource]?

    init(headword: String,
         phonetics: [String],
         partsOfSpeech: [String],
         definitions: [String],
         examples: [String],
         source: String,
         partOfSpeechSections: [StructuredPartOfSpeechSection]? = nil,
         semanticEntry: StructuredSemanticEntry? = nil,
         additionalSources: [StructuredDictionarySource]? = nil) {
        self.headword = headword
        self.phonetics = phonetics
        self.partsOfSpeech = partsOfSpeech
        self.definitions = definitions
        self.examples = examples
        self.source = source
        self.partOfSpeechSections = partOfSpeechSections
        self.semanticEntry = semanticEntry
        self.additionalSources = additionalSources
    }

    init(headword: String, sources: [StructuredDictionarySource]) {
        let first = sources.first ?? StructuredDictionarySource(
            phonetics: [],
            partsOfSpeech: [],
            definitions: [],
            examples: [],
            source: ""
        )
        self.init(headword: headword,
                  phonetics: first.phonetics,
                  partsOfSpeech: first.partsOfSpeech,
                  definitions: first.definitions,
                  examples: first.examples,
                  source: first.source,
                  partOfSpeechSections: first.partOfSpeechSections,
                  semanticEntry: first.semanticEntry,
                  additionalSources: sources.count > 1 ? Array(sources.dropFirst()) : nil)
    }

    var sources: [StructuredDictionarySource] {
        var values: [StructuredDictionarySource] = []
        if !Self.singleLine(source).isEmpty {
            values.append(StructuredDictionarySource(
                phonetics: phonetics,
                partsOfSpeech: partsOfSpeech,
                definitions: definitions,
                examples: examples,
                source: source,
                partOfSpeechSections: partOfSpeechSections,
                semanticEntry: semanticEntry
            ))
        }
        values.append(contentsOf: additionalSources ?? [])
        return values
    }

    var isValid: Bool {
        !Self.singleLine(headword).isEmpty
    }

    fileprivate static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ObsidianNoteSaveResult: Equatable {
    case saved
    case alreadySaved
}

struct AIExplanationNoteSection: Equatable {
    let headword: String
    let markdown: String

    var isValid: Bool {
        !StructuredDictionaryEntry.singleLine(headword).isEmpty &&
            markdown.hasPrefix("### AI 双语解释")
    }
}

struct InlineLookupNoteItem: Equatable {
    let selectedText: String
    let normalizedText: String
    let kind: String
    let quickLines: [String]
    let expandedLines: [String]
    let source: String
    let provider: String?
    let model: String?

    var identity: String {
        let normalized = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return "\(kind.lowercased())|\(normalized)"
    }

    var isValid: Bool {
        !identity.hasSuffix("|") && !quickLines.isEmpty
    }
}

struct VocabularyNoteSaveContent: Equatable {
    let headword: String
    let localEntry: StructuredDictionaryEntry?
    let aiSection: AIExplanationNoteSection?
    let inlineSupplements: [InlineLookupNoteItem]

    init(headword: String, localEntry: StructuredDictionaryEntry?,
         aiSection: AIExplanationNoteSection?,
         inlineSupplements: [InlineLookupNoteItem] = []) {
        self.headword = headword
        self.localEntry = localEntry
        self.aiSection = aiSection
        self.inlineSupplements = inlineSupplements.filter(\.isValid)
    }

    var isValid: Bool {
        let expected = Self.normalized(headword)
        guard !expected.isEmpty else { return false }
        let localMatches = localEntry.map {
            $0.isValid && Self.normalized($0.headword) == expected
        } ?? false
        let aiMatches = aiSection.map {
            $0.isValid && Self.normalized($0.headword) == expected
        } ?? false
        return localMatches || aiMatches
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

enum VocabularyNoteSaveResult: Equatable {
    case localSaved
    case localAlreadySaved
    case savedWithAI
    case aiAddedToExistingEntry
    case aiAlreadyPresent
}

struct SentenceNoteSaveContent: Equatable {
    let sourceText: String
    let title: String
    let aiSectionMarkdown: String?
    let glossarySectionMarkdown: String?
    let inlineSupplements: [InlineLookupNoteItem]

    init(sourceText: String, title: String, aiSectionMarkdown: String?,
         glossarySectionMarkdown: String?,
         inlineSupplements: [InlineLookupNoteItem] = []) {
        self.sourceText = sourceText
        self.title = title
        self.aiSectionMarkdown = aiSectionMarkdown
        self.glossarySectionMarkdown = glossarySectionMarkdown
        self.inlineSupplements = inlineSupplements.filter(\.isValid)
    }

    var isValid: Bool {
        !Self.normalizedSentence(sourceText).isEmpty &&
            (validAISection || validGlossarySection || !inlineSupplements.isEmpty)
    }

    var validAISection: Bool {
        aiSectionMarkdown?.hasPrefix("### AI 解析") == true
    }

    var validGlossarySection: Bool {
        glossarySectionMarkdown?.hasPrefix("### 本地词语参考") == true
    }

    static func normalizedSentence(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

enum SentenceNoteSaveResult: Equatable {
    case saved
    case alreadySaved
    case aiAddedToExistingSentence
    case aiAlreadyPresent
}

enum ObsidianNoteStoreError: LocalizedError, Equatable {
    case targetNotSelected
    case invalidTarget
    case targetUnavailable
    case targetNotWritable
    case targetNotUTF8
    case invalidEntry
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .targetNotSelected:
            return "尚未选择 Obsidian Markdown 笔记。"
        case .invalidTarget:
            return "目标必须是一个 Markdown（.md）文件。"
        case .targetUnavailable:
            return "目标笔记已移动或不存在，请重新选择。"
        case .targetNotWritable:
            return "目标笔记为只读或没有写入权限，请重新选择。"
        case .targetNotUTF8:
            return "目标笔记不是有效的 UTF-8 文件，未进行写入。"
        case .invalidEntry:
            return "当前没有可以保存的有效词条。"
        case .writeFailed:
            return "写入失败，原笔记未被替换。请重新选择或检查权限。"
        }
    }
}

final class ObsidianNoteStore {
    static let targetPathDefaultsKey = "ObsidianMarkdownTargetPath"

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var targetURL: URL? {
        guard let path = defaults.string(forKey: Self.targetPathDefaultsKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func rememberTarget(_ url: URL) throws {
        let target = url.standardizedFileURL
        guard target.isFileURL,
              target.pathExtension.lowercased() == "md" else {
            throw ObsidianNoteStoreError.invalidTarget
        }
        defaults.set(target.path, forKey: Self.targetPathDefaultsKey)
    }

    func contains(headword: String) throws -> Bool {
        guard let targetURL else { throw ObsidianNoteStoreError.targetNotSelected }
        let target = try validatedTarget(targetURL, requireWritable: false)
        let data = try readData(from: target)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ObsidianNoteStoreError.targetNotUTF8
        }
        return Self.containsEntry(in: content, headword: headword)
    }

    func save(_ entry: StructuredDictionaryEntry) throws -> ObsidianNoteSaveResult {
        guard let targetURL else { throw ObsidianNoteStoreError.targetNotSelected }
        return try save(entry, to: targetURL)
    }

    func save(_ content: VocabularyNoteSaveContent) throws -> VocabularyNoteSaveResult {
        guard let targetURL else { throw ObsidianNoteStoreError.targetNotSelected }
        return try save(content, to: targetURL)
    }

    func contains(sentence sourceText: String) throws -> Bool {
        guard let targetURL else { throw ObsidianNoteStoreError.targetNotSelected }
        let target = try validatedTarget(targetURL, requireWritable: false)
        let data = try readData(from: target)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ObsidianNoteStoreError.targetNotUTF8
        }
        return Self.containsSentence(in: content, sourceText: sourceText)
    }

    func save(_ content: SentenceNoteSaveContent) throws -> SentenceNoteSaveResult {
        guard let targetURL else { throw ObsidianNoteStoreError.targetNotSelected }
        return try save(content, to: targetURL)
    }

    func save(_ content: SentenceNoteSaveContent,
              to candidateURL: URL) throws -> SentenceNoteSaveResult {
        guard content.isValid else { throw ObsidianNoteStoreError.invalidEntry }
        let target = try validatedTarget(candidateURL, requireWritable: true)
        let originalData = try readData(from: target)
        guard let original = String(data: originalData, encoding: .utf8) else {
            throw ObsidianNoteStoreError.targetNotUTF8
        }
        let newline = Self.newlineSequence(in: original)
        let updated: String
        let result: SentenceNoteSaveResult
        if let range = Self.sentenceEntryRange(in: original,
                                               sourceText: content.sourceText) {
            let existingEntry = String(original[range])
            var replacement = existingEntry
            var didAddAI = false
            if content.validAISection && !Self.containsSentenceAISection(in: existingEntry) {
                let ai = Self.markdown(content.aiSectionMarkdown!, using: newline)
                replacement = Self.insertingSentenceAISection(ai,
                                                              into: replacement,
                                                              newline: newline)
                didAddAI = true
            }
            let merged = Self.mergingInlineSupplements(content.inlineSupplements,
                                                       into: replacement,
                                                       newline: newline)
            replacement = merged.content
            if didAddAI || merged.changed {
                if range.upperBound < original.endIndex {
                    replacement = Self.ensuringBlankLineSuffix(replacement, newline: newline)
                }
                var mutable = original
                mutable.replaceSubrange(range, with: replacement)
                updated = mutable
                result = didAddAI ? .aiAddedToExistingSentence : .alreadySaved
            } else {
                return content.validAISection ? .aiAlreadyPresent : .alreadySaved
            }
        } else {
            let block = Self.sentenceMarkdownBlock(for: content, newline: newline)
            updated = Self.appendingMarkdownBlock(block, to: original, newline: newline)
            result = .saved
        }
        try writeAtomically(updated, to: target)
        return result
    }

    func save(_ content: VocabularyNoteSaveContent,
              to candidateURL: URL) throws -> VocabularyNoteSaveResult {
        guard content.isValid else { throw ObsidianNoteStoreError.invalidEntry }
        if content.aiSection == nil, content.inlineSupplements.isEmpty,
           let localEntry = content.localEntry {
            switch try save(localEntry, to: candidateURL) {
            case .saved: return .localSaved
            case .alreadySaved: return .localAlreadySaved
            }
        }
        if let aiSection = content.aiSection {
            guard aiSection.isValid,
                  Self.normalizedHeadword(aiSection.headword) ==
                    Self.normalizedHeadword(content.headword) else {
                throw ObsidianNoteStoreError.invalidEntry
            }
        }

        let target = try validatedTarget(candidateURL, requireWritable: true)
        let originalData = try readData(from: target)
        guard let original = String(data: originalData, encoding: .utf8) else {
            throw ObsidianNoteStoreError.targetNotUTF8
        }
        let newline = Self.newlineSequence(in: original)
        let updated: String
        let result: VocabularyNoteSaveResult
        if let range = Self.entryRange(in: original, headword: content.headword) {
            let existingEntry = String(original[range])
            var replacement = existingEntry
            var didAddAI = false
            if let aiSection = content.aiSection, !Self.containsAISection(in: existingEntry) {
                let aiMarkdown = Self.markdown(aiSection.markdown, using: newline)
                replacement = Self.appendingMarkdownBlock(aiMarkdown,
                                                           to: replacement,
                                                           newline: newline)
                didAddAI = true
            }
            let merged = Self.mergingInlineSupplements(content.inlineSupplements,
                                                       into: replacement,
                                                       newline: newline)
            replacement = merged.content
            guard didAddAI || merged.changed else {
                return content.aiSection != nil ? .aiAlreadyPresent : .localAlreadySaved
            }
            if range.upperBound < original.endIndex {
                replacement = Self.ensuringBlankLineSuffix(replacement, newline: newline)
            }
            var mutable = original
            mutable.replaceSubrange(range, with: replacement)
            updated = mutable
            result = didAddAI ? .aiAddedToExistingEntry : .localSaved
        } else {
            let entryBlock = Self.combinedMarkdownBlock(for: content, newline: newline)
            updated = Self.appendingMarkdownBlock(entryBlock, to: original, newline: newline)
            result = content.aiSection == nil ? .localSaved : .savedWithAI
        }
        try writeAtomically(updated, to: target)
        return result
    }

    func save(_ entry: StructuredDictionaryEntry,
              to candidateURL: URL) throws -> ObsidianNoteSaveResult {
        guard entry.isValid else { throw ObsidianNoteStoreError.invalidEntry }
        let target = try validatedTarget(candidateURL, requireWritable: true)
        let originalData = try readData(from: target)
        guard let original = String(data: originalData, encoding: .utf8) else {
            throw ObsidianNoteStoreError.targetNotUTF8
        }

        guard !Self.containsEntry(in: original, headword: entry.headword) else {
            return .alreadySaved
        }

        let newline = Self.newlineSequence(in: original)
        let block = Self.markdownBlock(for: entry, newline: newline)
        let separator: String
        if original.isEmpty {
            separator = ""
        } else if original.hasSuffix(newline + newline) {
            separator = ""
        } else if original.hasSuffix(newline) {
            separator = newline
        } else {
            separator = newline + newline
        }

        guard let updatedData = (original + separator + block).data(using: .utf8) else {
            throw ObsidianNoteStoreError.writeFailed
        }
        do {
            try updatedData.write(to: target, options: .atomic)
        } catch {
            throw ObsidianNoteStoreError.writeFailed
        }
        return .saved
    }

    func createOrSave(_ entry: StructuredDictionaryEntry,
                      at candidateURL: URL) throws -> ObsidianNoteSaveResult {
        guard entry.isValid else { throw ObsidianNoteStoreError.invalidEntry }
        let target = candidateURL.standardizedFileURL
        guard target.isFileURL, target.pathExtension.lowercased() == "md" else {
            throw ObsidianNoteStoreError.invalidTarget
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw ObsidianNoteStoreError.invalidTarget }
            return try save(entry, to: target)
        }

        let parent = target.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: parent.path) else {
            throw ObsidianNoteStoreError.targetNotWritable
        }
        let block = Self.markdownBlock(for: entry, newline: "\n")
        guard let data = block.data(using: .utf8) else {
            throw ObsidianNoteStoreError.writeFailed
        }
        let temporary = parent.appendingPathComponent(
            ".\(target.lastPathComponent).localdictionary-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.linkItem(at: temporary, to: target)
        } catch {
            throw ObsidianNoteStoreError.writeFailed
        }
        return .saved
    }

    func createOrSave(_ content: VocabularyNoteSaveContent,
                      at candidateURL: URL) throws -> VocabularyNoteSaveResult {
        guard content.isValid else { throw ObsidianNoteStoreError.invalidEntry }
        if content.aiSection == nil, content.inlineSupplements.isEmpty,
           let localEntry = content.localEntry {
            switch try createOrSave(localEntry, at: candidateURL) {
            case .saved: return .localSaved
            case .alreadySaved: return .localAlreadySaved
            }
        }
        if let aiSection = content.aiSection {
            guard aiSection.isValid,
                  Self.normalizedHeadword(aiSection.headword) ==
                    Self.normalizedHeadword(content.headword) else {
                throw ObsidianNoteStoreError.invalidEntry
            }
        }
        let target = candidateURL.standardizedFileURL
        guard target.isFileURL, target.pathExtension.lowercased() == "md" else {
            throw ObsidianNoteStoreError.invalidTarget
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw ObsidianNoteStoreError.invalidTarget }
            return try save(content, to: target)
        }
        let parent = target.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: parent.path) else {
            throw ObsidianNoteStoreError.targetNotWritable
        }
        let block = Self.combinedMarkdownBlock(for: content, newline: "\n")
        guard let data = block.data(using: .utf8) else {
            throw ObsidianNoteStoreError.writeFailed
        }
        let temporary = parent.appendingPathComponent(
            ".\(target.lastPathComponent).localdictionary-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.linkItem(at: temporary, to: target)
        } catch {
            throw ObsidianNoteStoreError.writeFailed
        }
        return content.aiSection == nil ? .localSaved : .savedWithAI
    }

    func createOrSave(_ content: SentenceNoteSaveContent,
                      at candidateURL: URL) throws -> SentenceNoteSaveResult {
        guard content.isValid else { throw ObsidianNoteStoreError.invalidEntry }
        let target = candidateURL.standardizedFileURL
        guard target.isFileURL, target.pathExtension.lowercased() == "md" else {
            throw ObsidianNoteStoreError.invalidTarget
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw ObsidianNoteStoreError.invalidTarget }
            return try save(content, to: target)
        }
        let parent = target.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: parent.path) else {
            throw ObsidianNoteStoreError.targetNotWritable
        }
        let block = Self.sentenceMarkdownBlock(for: content, newline: "\n")
        guard let data = block.data(using: .utf8) else {
            throw ObsidianNoteStoreError.writeFailed
        }
        let temporary = parent.appendingPathComponent(
            ".\(target.lastPathComponent).localdictionary-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.linkItem(at: temporary, to: target)
        } catch {
            throw ObsidianNoteStoreError.writeFailed
        }
        return .saved
    }

    static func containsEntry(in content: String, headword: String) -> Bool {
        let expected = normalizedHeadword(headword)
        guard !expected.isEmpty else { return false }
        if containsLegacyMarker(in: content, normalizedHeadword: expected) {
            return true
        }

        var activeFence: (character: Character, length: Int)?
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in lines {
            if let fence = activeFence {
                if isClosingFence(line, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = openingFence(in: line) {
                activeFence = fence
                continue
            }
            guard let heading = levelTwoHeading(in: line) else { continue }
            if normalizedHeadword(heading) == expected { return true }
        }
        return false
    }

    static func containsSentence(in content: String, sourceText: String) -> Bool {
        sentenceEntryRange(in: content, sourceText: sourceText) != nil
    }

    static func legacyMarker(for headword: String) -> String {
        "<!-- LocalDictionary: word=\(normalizedHeadword(headword)) -->"
    }

    static func markdownBlock(for entry: StructuredDictionaryEntry,
                              newline: String) -> String {
        let headword = singleLine(entry.headword)
        var lines = ["## \(headword)", ""]
        for sourceEntry in entry.sources {
            let source = singleLine(sourceEntry.source)
            guard !source.isEmpty else { continue }
            let phonetics = uniqueNonempty(sourceEntry.phonetics, maximum: 4)
            let partsOfSpeech = uniqueNonempty(sourceEntry.partsOfSpeech, maximum: 8)
            let definitions = uniqueNonempty(sourceEntry.definitions, maximum: 5)
            let examples = uniqueNonempty(sourceEntry.examples, maximum: 3)
            let groupedSections = limitedPartOfSpeechSections(
                sourceEntry.partOfSpeechSections ?? [],
                maximumSenses: 5
            )
            let semanticEntry = sourceEntry.semanticEntry
            guard !phonetics.isEmpty || !partsOfSpeech.isEmpty ||
                    !definitions.isEmpty || !examples.isEmpty ||
                    !groupedSections.isEmpty || semanticEntry?.hasContent == true else { continue }

            lines.append("### \(source)")
            lines.append("")
            if !phonetics.isEmpty {
                lines.append("- 音标：\(phonetics.joined(separator: "；"))")
            }
            if let semanticEntry, semanticEntry.hasContent {
                appendSemanticEntry(semanticEntry, to: &lines)
            } else if groupedSections.isEmpty {
                if !partsOfSpeech.isEmpty {
                    lines.append("- 词性：\(partsOfSpeech.joined(separator: ", "))")
                }
                if !definitions.isEmpty {
                    let definitionLabel = source == "词根词缀" ? "构词" :
                        (source == "英中医学辞海" ? "定义" : "释义")
                    lines.append("- \(definitionLabel)：")
                    lines.append(contentsOf: definitions.map { "  - \($0)" })
                }
                if !examples.isEmpty {
                    lines.append("- 例句：")
                    lines.append(contentsOf: examples.map { "  - \($0)" })
                }
            } else {
                for section in groupedSections {
                    let partOfSpeech = singleLine(section.partOfSpeech)
                    lines.append(partOfSpeech.isEmpty ? "- 释义：" : "- \(partOfSpeech)")
                    for sense in section.senses {
                        let definition = singleLine(sense.definition)
                        guard !definition.isEmpty else { continue }
                        let indentation = String(repeating: "  ",
                                                 count: max(1, sense.indentationLevel + 1))
                        if sense.number > 0 {
                            lines.append("\(indentation)\(sense.number). \(definition)")
                        } else {
                            lines.append("\(indentation)- \(definition)")
                        }
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: newline)
    }

    private static func appendSemanticEntry(_ entry: StructuredSemanticEntry,
                                            to lines: inout [String]) {
        let inflections = uniqueNonempty(entry.inflections, maximum: 12)
        if !inflections.isEmpty {
            lines.append("- 词形：\(inflections.joined(separator: "；"))")
        }
        var remainingSenses = 5
        var remainingExamples = 3
        for section in entry.partOfSpeechSections where remainingSenses > 0 {
            let partOfSpeech = singleLine(section.partOfSpeech)
            if !partOfSpeech.isEmpty {
                lines.append("")
                lines.append("#### \(partOfSpeech)")
                lines.append("")
            }
            let grammarLabels = uniqueNonempty(section.grammarLabels, maximum: 6)
            if !grammarLabels.isEmpty {
                lines.append("- 语法：\(grammarLabels.joined(separator: "；"))")
            }
            for sense in section.senses where remainingSenses > 0 {
                appendSemanticSense(sense, to: &lines, indentation: "",
                                    remainingSenses: &remainingSenses,
                                    remainingExamples: &remainingExamples)
            }
            appendSemanticRelations(section.relations, to: &lines, indentation: "- ")
            appendSemanticDerivatives(section.derivatives, entryLevel: false, to: &lines)
        }
        appendSemanticDerivatives(entry.derivatives, entryLevel: true, to: &lines)
        appendSemanticRelations(entry.entryLevelRelations, to: &lines, indentation: "- ")
    }

    private static func appendSemanticSense(_ sense: StructuredSemanticSense,
                                            to lines: inout [String],
                                            indentation: String,
                                            remainingSenses: inout Int,
                                            remainingExamples: inout Int) {
        guard remainingSenses > 0 else { return }
        let english = singleLine(sense.definitionEnglish)
        let chinese = uniqueNonempty(sense.definitionChinese, maximum: 4)
        guard !english.isEmpty || !chinese.isEmpty else { return }
        remainingSenses -= 1
        let number = singleLine(sense.number)
        let lead = number.isEmpty ? "-" : (number.hasSuffix(".") ? number : "\(number).")
        let primary = english.isEmpty ? chinese[0] : english
        lines.append("\(indentation)\(lead) \(primary)")
        let remainingChinese = english.isEmpty ? Array(chinese.dropFirst()) : chinese
        for value in remainingChinese {
            lines.append("\(indentation)   - 中文释义：\(value)")
        }
        let labels = uniqueNonempty(sense.labels, maximum: 4)
        if !labels.isEmpty {
            lines.append("\(indentation)   - 标签：\(labels.joined(separator: "；"))")
        }
        let grammar = uniqueNonempty(sense.grammarPatterns, maximum: 4)
        if !grammar.isEmpty {
            lines.append("\(indentation)   - 语法：\(grammar.joined(separator: "；"))")
        }
        for example in sense.examples where remainingExamples > 0 {
            let englishExample = singleLine(example.english)
            guard !englishExample.isEmpty else { continue }
            lines.append("\(indentation)   - 例句：\(englishExample)")
            if let translation = uniqueNonempty(example.translations, maximum: 1).first {
                lines.append("\(indentation)     - \(translation)")
            }
            remainingExamples -= 1
        }
        appendSemanticRelations(sense.relations, to: &lines,
                                indentation: "\(indentation)   - ")
        for subsense in sense.subsenses where remainingSenses > 0 {
            appendSemanticSense(subsense, to: &lines,
                                indentation: indentation + "   ",
                                remainingSenses: &remainingSenses,
                                remainingExamples: &remainingExamples)
        }
    }

    private static func appendSemanticRelations(
        _ relations: [StructuredSemanticRelationGroup],
        to lines: inout [String],
        indentation: String
    ) {
        for relation in relations {
            let title = singleLine(relation.title)
            let values = uniqueNonempty(relation.values, maximum: 5)
            guard !title.isEmpty, !values.isEmpty else { continue }
            lines.append("\(indentation)\(title)：\(values.joined(separator: "；"))")
        }
    }

    private static func appendSemanticDerivatives(
        _ derivatives: [StructuredSemanticDerivative],
        entryLevel: Bool,
        to lines: inout [String]
    ) {
        let usable = derivatives.filter { !singleLine($0.headword).isEmpty }
        guard !usable.isEmpty else { return }
        if entryLevel {
            lines.append("")
            lines.append("#### 派生词")
            lines.append("")
        }
        for derivative in usable.prefix(8) {
            if !entryLevel {
                lines.append("")
                lines.append("##### \(derivativeHeading(derivative))")
                lines.append("")
            }
            var metadata: [String] = []
            let part = singleLine(derivative.partOfSpeech)
            if !part.isEmpty { metadata.append(part) }
            metadata.append(contentsOf: uniqueNonempty(derivative.pronunciations, maximum: 2))
            let suffix = metadata.isEmpty ? "" : "：" + metadata.joined(separator: "；")
            lines.append("- \(singleLine(derivative.headword))\(suffix)")
            let summary = singleLine(derivative.summary)
            if !summary.isEmpty { lines.append("  - \(summary)") }
        }
    }

    private static func derivativeHeading(
        _ derivative: StructuredSemanticDerivative
    ) -> String {
        let derivedPart = localizedPartOfSpeech(derivative.partOfSpeech)
        let sourcePart = localizedPartOfSpeech(derivative.sourcePartOfSpeech)
        let kind = derivedPart.isEmpty ? "派生词" : "派生\(derivedPart)"
        let sourceWord = singleLine(derivative.sourceHeadword)
        guard !sourcePart.isEmpty, !sourceWord.isEmpty else { return kind }
        return "\(kind)（由\(sourcePart) \(sourceWord) 派生）"
    }

    private static func localizedPartOfSpeech(_ source: String) -> String {
        let value = singleLine(source).lowercased()
        let mappings = [
            ("adjective", "形容词"), ("adverb", "副词"),
            ("noun", "名词"), ("verb", "动词"),
            ("pronoun", "代词"), ("preposition", "介词"),
            ("conjunction", "连词"), ("determiner", "限定词")
        ]
        if let mapped = mappings.first(where: { value.contains($0.0) })?.1 {
            return mapped
        }
        if value.hasPrefix("adj.") || value == "adj" { return "形容词" }
        if value.hasPrefix("adv.") || value == "adv" { return "副词" }
        if value.hasPrefix("n.") || value == "n" { return "名词" }
        if value.hasPrefix("v.") || value == "v" { return "动词" }
        return singleLine(source)
    }

    private static func limitedPartOfSpeechSections(
        _ sections: [StructuredPartOfSpeechSection],
        maximumSenses: Int
    ) -> [StructuredPartOfSpeechSection] {
        guard maximumSenses > 0 else { return [] }
        var selected = Array(repeating: [StructuredPartOfSpeechSense](),
                             count: sections.count)
        var remaining = maximumSenses
        var senseIndex = 0
        while remaining > 0 {
            var added = false
            for index in sections.indices where sections[index].senses.count > senseIndex {
                selected[index].append(sections[index].senses[senseIndex])
                remaining -= 1
                added = true
                if remaining == 0 { break }
            }
            if !added { break }
            senseIndex += 1
        }
        return sections.indices.compactMap { index in
            guard !selected[index].isEmpty else { return nil }
            return StructuredPartOfSpeechSection(
                partOfSpeech: sections[index].partOfSpeech,
                senses: selected[index]
            )
        }
    }

    private func validatedTarget(_ candidateURL: URL, requireWritable: Bool) throws -> URL {
        let target = candidateURL.standardizedFileURL
        guard target.isFileURL, target.pathExtension.lowercased() == "md" else {
            throw ObsidianNoteStoreError.invalidTarget
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ObsidianNoteStoreError.targetUnavailable
        }
        if requireWritable && !fileManager.isWritableFile(atPath: target.path) {
            throw ObsidianNoteStoreError.targetNotWritable
        }
        return target
    }

    private func readData(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ObsidianNoteStoreError.targetUnavailable
        }
    }

    private func writeAtomically(_ content: String, to url: URL) throws {
        guard let data = content.data(using: .utf8) else {
            throw ObsidianNoteStoreError.writeFailed
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ObsidianNoteStoreError.writeFailed
        }
    }

    private static func combinedMarkdownBlock(
        for content: VocabularyNoteSaveContent,
        newline: String
    ) -> String {
        let localBlock: String
        if let entry = content.localEntry, entry.isValid {
            localBlock = markdownBlock(for: entry, newline: newline)
        } else {
            localBlock = "## \(singleLine(content.headword))"
        }
        var output = localBlock
        if let aiSection = content.aiSection {
            output = appendingMarkdownBlock(markdown(aiSection.markdown, using: newline),
                                            to: output,
                                            newline: newline)
        }
        return mergingInlineSupplements(content.inlineSupplements,
                                        into: output,
                                        newline: newline).content
    }

    private static func sentenceMarkdownBlock(for content: SentenceNoteSaveContent,
                                              newline: String) -> String {
        var lines = [
            "## \(singleLine(content.title))",
            "",
            "### 原句",
            ""
        ]
        lines.append(contentsOf: blockquoteLines(for: content.sourceText))
        var block = lines.joined(separator: newline)
        if content.validAISection, let ai = content.aiSectionMarkdown {
            block = appendingMarkdownBlock(markdown(ai, using: newline),
                                            to: block,
                                            newline: newline)
        }
        if content.validGlossarySection, let glossary = content.glossarySectionMarkdown {
            block = appendingMarkdownBlock(markdown(glossary, using: newline),
                                            to: block,
                                            newline: newline)
        }
        return mergingInlineSupplements(content.inlineSupplements,
                                        into: block,
                                        newline: newline).content
    }

    private static func mergingInlineSupplements(
        _ items: [InlineLookupNoteItem], into content: String, newline: String
    ) -> (content: String, changed: Bool) {
        let incoming = items.filter(\.isValid)
        guard !incoming.isEmpty else { return (content, false) }
        var lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var sectionStart = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) ==
            "### 应用内划词补充" }
        var changed = false
        if sectionStart == nil {
            while lines.last?.isEmpty == true { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("### 应用内划词补充")
            lines.append("")
            sectionStart = lines.count - 2
            changed = true
        }
        guard let start = sectionStart else { return (content, false) }
        var sectionEnd = lines.count
        if start + 1 < lines.count {
            for index in (start + 1)..<lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("### ") && !trimmed.hasPrefix("#### ") {
                    sectionEnd = index
                    break
                }
            }
        }

        for item in incoming {
            let blocks = inlineItemBlocks(in: lines, sectionStart: start, sectionEnd: sectionEnd)
            if let block = blocks.first(where: { $0.identity == item.identity }) {
                guard !item.expandedLines.isEmpty,
                      !lines[block.range].contains(where: {
                        $0.trimmingCharacters(in: .whitespaces) == "##### 了解更多"
                      }) else { continue }
                var insertion = ["", "##### 了解更多", ""]
                insertion.append(contentsOf: item.expandedLines.map(safeMarkdownLine))
                lines.insert(contentsOf: insertion, at: block.range.upperBound)
                sectionEnd += insertion.count
                changed = true
                continue
            }
            let blockLines = inlineMarkdownLines(for: item)
            var insertion = blockLines
            if sectionEnd > 0, !lines[sectionEnd - 1].isEmpty { insertion.insert("", at: 0) }
            lines.insert(contentsOf: insertion, at: sectionEnd)
            sectionEnd += insertion.count
            changed = true
        }
        let normalized = lines.joined(separator: "\n")
        return (newline == "\n" ? normalized
                : normalized.replacingOccurrences(of: "\n", with: newline), changed)
    }

    private struct InlineItemBlock {
        let identity: String
        let range: Range<Int>
    }

    private static func inlineItemBlocks(in lines: [String], sectionStart: Int,
                                         sectionEnd: Int) -> [InlineItemBlock] {
        guard sectionStart + 1 < sectionEnd else { return [] }
        var starts: [Int] = []
        for index in (sectionStart + 1)..<sectionEnd where
            lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("#### ") &&
            !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("##### ") {
            starts.append(index)
        }
        return starts.enumerated().compactMap { offset, start -> InlineItemBlock? in
            let end = offset + 1 < starts.count ? starts[offset + 1] : sectionEnd
            var kind = ""
            var selected = ""
            for line in lines[start..<end] {
                let clean = line.trimmingCharacters(in: .whitespaces)
                if clean.hasPrefix("- 类型：") { kind = String(clean.dropFirst(5)) }
                if clean.hasPrefix("- 选中内容：") { selected = String(clean.dropFirst(7)) }
            }
            let normalized = selected.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard !kind.isEmpty, !normalized.isEmpty else { return nil }
            return InlineItemBlock(identity: "\(kind.lowercased())|\(normalized)",
                                   range: start..<end)
        }
    }

    private static func inlineMarkdownLines(for item: InlineLookupNoteItem) -> [String] {
        var lines = [
            "#### \(safeInlineHeading(item.selectedText))",
            "",
            "- 类型：\(safeMarkdownLine(item.kind))",
            "- 选中内容：\(safeMarkdownLine(item.normalizedText))"
        ]
        lines.append(contentsOf: item.quickLines.map(safeMarkdownLine))
        if !item.source.isEmpty { lines.append("- 来源：\(safeMarkdownLine(item.source))") }
        if let provider = item.provider, !provider.isEmpty {
            let model = item.model?.isEmpty == false ? " · \(safeMarkdownLine(item.model!))" : ""
            lines.append("- AI 来源：\(safeMarkdownLine(provider))\(model)")
        }
        if !item.expandedLines.isEmpty {
            lines += ["", "##### 了解更多", ""]
            lines.append(contentsOf: item.expandedLines.map(safeMarkdownLine))
        }
        lines.append("")
        return lines
    }

    private static func safeInlineHeading(_ value: String) -> String {
        let clean = safeMarkdownLine(value).replacingOccurrences(of: "#", with: "")
        guard clean.count > 56 else { return clean }
        return String(clean.prefix(55)) + "…"
    }

    private static func safeMarkdownLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blockquoteLines(for sourceText: String) -> [String] {
        let sentence = SentenceNoteSaveContent.normalizedSentence(sourceText)
        guard !sentence.isEmpty else { return [] }
        let maximumLineLength = 76
        var lines: [String] = []
        var current = ""
        for word in sentence.split(separator: " ").map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maximumLineLength {
                current += " " + word
            } else {
                lines.append("> " + current)
                current = word
            }
        }
        if !current.isEmpty { lines.append("> " + current) }
        return lines
    }

    private static func insertingSentenceAISection(_ aiSection: String,
                                                   into entry: String,
                                                   newline: String) -> String {
        if let localSectionStart = levelThreeSectionStart(in: entry,
                                                          title: "本地词语参考") {
            let prefix = String(entry[..<localSectionStart])
            let suffix = String(entry[localSectionStart...])
            let withAI = appendingMarkdownBlock(aiSection, to: prefix, newline: newline)
            return ensuringBlankLineSuffix(withAI, newline: newline) + suffix
        }
        return appendingMarkdownBlock(aiSection, to: entry, newline: newline)
    }

    private static func markdown(_ value: String, using newline: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return newline == "\n" ? normalized
            : normalized.replacingOccurrences(of: "\n", with: newline)
    }

    private static func appendingMarkdownBlock(_ block: String,
                                               to content: String,
                                               newline: String) -> String {
        guard !content.isEmpty else { return block }
        if content.hasSuffix(newline + newline) { return content + block }
        if content.hasSuffix(newline) { return content + newline + block }
        return content + newline + newline + block
    }

    private static func ensuringBlankLineSuffix(_ content: String,
                                                newline: String) -> String {
        if content.hasSuffix(newline + newline) { return content }
        if content.hasSuffix(newline) { return content + newline }
        return content + newline + newline
    }

    private struct MarkdownLine {
        let content: String
        let start: String.Index
    }

    private static func entryRange(in content: String,
                                   headword: String) -> Range<String.Index>? {
        let expected = normalizedHeadword(headword)
        guard !expected.isEmpty else { return nil }
        var activeFence: (character: Character, length: Int)?
        var entryStart: String.Index?
        for line in markdownLines(in: content) {
            if let fence = activeFence {
                if isClosingFence(line.content, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = openingFence(in: line.content) {
                activeFence = fence
                continue
            }
            guard let heading = levelTwoHeading(in: line.content) else { continue }
            if let entryStart {
                return entryStart..<line.start
            }
            if normalizedHeadword(heading) == expected {
                entryStart = line.start
            }
        }
        guard let entryStart else { return nil }
        return entryStart..<content.endIndex
    }

    private static func sentenceEntryRange(in content: String,
                                           sourceText: String) -> Range<String.Index>? {
        let expected = SentenceNoteSaveContent.normalizedSentence(sourceText)
        guard !expected.isEmpty else { return nil }
        let lines = markdownLines(in: content)
        var activeFence: (character: Character, length: Int)?
        var candidateStart: String.Index?
        for line in lines {
            if let fence = activeFence {
                if isClosingFence(line.content, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = openingFence(in: line.content) {
                activeFence = fence
                continue
            }
            guard levelTwoHeading(in: line.content) != nil else { continue }
            if let start = candidateStart {
                let range = start..<line.start
                if sentenceSourceText(in: String(content[range])) == expected {
                    return range
                }
            }
            candidateStart = line.start
        }
        guard let start = candidateStart else { return nil }
        let range = start..<content.endIndex
        return sentenceSourceText(in: String(content[range])) == expected ? range : nil
    }

    private static func sentenceSourceText(in entry: String) -> String? {
        var activeFence: (character: Character, length: Int)?
        var waitingForQuote = false
        var quoteParts: [String] = []
        for line in markdownLines(in: entry) {
            if let fence = activeFence {
                if isClosingFence(line.content, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = openingFence(in: line.content) {
                activeFence = fence
                continue
            }
            if !waitingForQuote {
                if levelThreeHeading(in: line.content)?
                    .precomposedStringWithCanonicalMapping == "原句" {
                    waitingForQuote = true
                }
                continue
            }
            if line.content.trimmingCharacters(in: .whitespaces).isEmpty {
                if quoteParts.isEmpty { continue }
                break
            }
            guard let quote = blockquoteContent(in: line.content) else { break }
            quoteParts.append(quote)
        }
        guard !quoteParts.isEmpty else { return nil }
        return SentenceNoteSaveContent.normalizedSentence(quoteParts.joined(separator: " "))
    }

    private static func blockquoteContent(in line: String) -> String? {
        guard let content = contentAfterMarkdownIndent(in: line),
              content.first == ">" else { return nil }
        return content.dropFirst()
            .drop(while: { $0 == " " || $0 == "\t" })
            .trimmingCharacters(in: .whitespaces)
    }

    private static func containsSentenceAISection(in entry: String) -> Bool {
        levelThreeSectionStart(in: entry, title: "AI 解析") != nil
    }

    private static func levelThreeSectionStart(in content: String,
                                               title: String) -> String.Index? {
        var activeFence: (character: Character, length: Int)?
        let expected = title.precomposedStringWithCanonicalMapping
        for line in markdownLines(in: content) {
            if let fence = activeFence {
                if isClosingFence(line.content, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = openingFence(in: line.content) {
                activeFence = fence
                continue
            }
            if levelThreeHeading(in: line.content)?
                .precomposedStringWithCanonicalMapping == expected {
                return line.start
            }
        }
        return nil
    }

    private static func containsAISection(in entry: String) -> Bool {
        var activeFence: (character: Character, length: Int)?
        for line in markdownLines(in: entry) {
            if let fence = activeFence {
                if isClosingFence(line.content, fence: fence) { activeFence = nil }
                continue
            }
            if let fence = openingFence(in: line.content) {
                activeFence = fence
                continue
            }
            guard let heading = levelThreeHeading(in: line.content) else { continue }
            if heading.precomposedStringWithCanonicalMapping == "AI 双语解释" { return true }
        }
        return false
    }

    private static func markdownLines(in content: String) -> [MarkdownLine] {
        var lines: [MarkdownLine] = []
        var cursor = content.startIndex
        let scalars = content.unicodeScalars
        while cursor < content.endIndex {
            let start = cursor
            while cursor < content.endIndex,
                  scalars[cursor].value != 0x0A, scalars[cursor].value != 0x0D {
                cursor = scalars.index(after: cursor)
            }
            lines.append(MarkdownLine(content: String(content[start..<cursor]), start: start))
            if cursor < content.endIndex, scalars[cursor].value == 0x0D {
                cursor = scalars.index(after: cursor)
                if cursor < content.endIndex, scalars[cursor].value == 0x0A {
                    cursor = scalars.index(after: cursor)
                }
            } else if cursor < content.endIndex {
                cursor = scalars.index(after: cursor)
            }
        }
        return lines
    }

    private static func uniqueNonempty(_ values: [String], maximum: Int) -> [String] {
        var result: [String] = []
        for value in values {
            let clean = singleLine(value)
            guard !clean.isEmpty, !result.contains(clean) else { continue }
            result.append(clean)
            if result.count == maximum { break }
        }
        return result
    }

    private static func singleLine(_ value: String) -> String {
        StructuredDictionaryEntry.singleLine(value)
    }

    private static func normalizedHeadword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func containsLegacyMarker(in content: String,
                                             normalizedHeadword: String) -> Bool {
        let prefix = "<!-- LocalDictionary: word="
        let suffix = " -->"
        var searchStart = content.startIndex
        while searchStart < content.endIndex,
              let prefixRange = content.range(of: prefix,
                                              range: searchStart..<content.endIndex),
              let suffixRange = content.range(of: suffix,
                                              range: prefixRange.upperBound..<content.endIndex) {
            let value = String(content[prefixRange.upperBound..<suffixRange.lowerBound])
            if self.normalizedHeadword(value) == normalizedHeadword { return true }
            searchStart = suffixRange.upperBound
        }
        return false
    }

    private static func levelTwoHeading(in line: String) -> String? {
        guard let content = contentAfterMarkdownIndent(in: line),
              content.hasPrefix("##") else { return nil }
        let afterHashes = content.dropFirst(2)
        guard let first = afterHashes.first,
              first == " " || first == "\t" else { return nil }
        let heading = afterHashes.drop(while: { $0 == " " || $0 == "\t" })
            .trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    private static func levelThreeHeading(in line: String) -> String? {
        guard let content = contentAfterMarkdownIndent(in: line),
              content.hasPrefix("###") else { return nil }
        let afterHashes = content.dropFirst(3)
        guard let first = afterHashes.first,
              first == " " || first == "\t" else { return nil }
        let heading = afterHashes.drop(while: { $0 == " " || $0 == "\t" })
            .trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    private static func openingFence(in line: String) -> (character: Character, length: Int)? {
        guard let content = contentAfterMarkdownIndent(in: line),
              let character = content.first,
              character == "`" || character == "~" else { return nil }
        let length = content.prefix(while: { $0 == character }).count
        return length >= 3 ? (character, length) : nil
    }

    private static func isClosingFence(_ line: String,
                                       fence: (character: Character, length: Int)) -> Bool {
        guard let content = contentAfterMarkdownIndent(in: line),
              content.first == fence.character else { return false }
        let runLength = content.prefix(while: { $0 == fence.character }).count
        guard runLength >= fence.length else { return false }
        return content.dropFirst(runLength)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    private static func contentAfterMarkdownIndent(in line: String) -> Substring? {
        var index = line.startIndex
        var spaces = 0
        while index < line.endIndex, line[index] == " " {
            spaces += 1
            guard spaces <= 3 else { return nil }
            index = line.index(after: index)
        }
        return line[index...]
    }

    private static func newlineSequence(in content: String) -> String {
        if content.contains("\r\n") { return "\r\n" }
        if content.contains("\r") { return "\r" }
        return "\n"
    }
}
