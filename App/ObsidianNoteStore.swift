import Foundation

struct StructuredDictionaryEntry: Codable, Equatable {
    let headword: String
    let phonetics: [String]
    let partsOfSpeech: [String]
    let definitions: [String]
    let examples: [String]
    let source: String

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

    static func legacyMarker(for headword: String) -> String {
        "<!-- LocalDictionary: word=\(normalizedHeadword(headword)) -->"
    }

    static func markdownBlock(for entry: StructuredDictionaryEntry,
                              newline: String) -> String {
        let headword = singleLine(entry.headword)
        let phonetics = uniqueNonempty(entry.phonetics, maximum: 4)
        let partsOfSpeech = uniqueNonempty(entry.partsOfSpeech, maximum: 8)
        let definitions = uniqueNonempty(entry.definitions, maximum: 5)
        let examples = uniqueNonempty(entry.examples, maximum: 3)
        let source = singleLine(entry.source)

        var lines = ["## \(headword)", ""]
        if !phonetics.isEmpty {
            lines.append("- 音标：\(phonetics.joined(separator: "；"))")
        }
        if !partsOfSpeech.isEmpty {
            lines.append("- 词性：\(partsOfSpeech.joined(separator: ", "))")
        }
        if !definitions.isEmpty {
            lines.append("- 释义：")
            lines.append(contentsOf: definitions.map { "  - \($0)" })
        }
        if !examples.isEmpty {
            lines.append("- 例句：")
            lines.append(contentsOf: examples.map { "  - \($0)" })
        }
        if !source.isEmpty {
            lines.append("- 来源：\(source)")
        }
        lines.append("")
        return lines.joined(separator: newline)
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
