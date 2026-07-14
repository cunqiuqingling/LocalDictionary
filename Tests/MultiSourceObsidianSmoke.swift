import Foundation

@main
struct MultiSourceObsidianSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw SmokeError.invalidArguments }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let entries = try JSONDecoder().decode(
            [StructuredDictionaryEntry].self,
            from: Data(contentsOf: fixtureURL)
        )
        guard entries.count == 4 else { throw SmokeError.assertion("fixture count") }

        let store = ObsidianNoteStore()
        let noteURL = directory.appendingPathComponent("real-multi-source.md")
        try Data("# Temporary test note\n".utf8).write(to: noteURL, options: .atomic)
        var semanticHierarchyCount = 0
        for entry in entries {
            guard try store.save(entry, to: noteURL) == .saved,
                  try store.save(entry, to: noteURL) == .alreadySaved else {
                throw SmokeError.assertion("duplicate save")
            }
        }
        let content = try String(contentsOf: noteURL, encoding: .utf8)
        for entry in entries {
            guard content.components(separatedBy: "\n")
                .filter({ $0 == "## \(entry.headword)" }).count == 1 else {
                throw SmokeError.assertion("heading count")
            }
            for source in entry.sources {
                guard content.contains("### \(source.source)") else {
                    throw SmokeError.assertion("missing source section")
                }
            }
            if let century = entry.sources.first(where: {
                $0.source == "21世纪大英汉词典"
            }) {
                guard let sections = century.partOfSpeechSections,
                      !sections.isEmpty,
                      sections.allSatisfy({ !$0.senses.isEmpty }) else {
                    throw SmokeError.assertion("missing Century21 grouping model")
                }
                let block = ObsidianNoteStore.markdownBlock(for: entry, newline: "\n")
                guard let centuryBlock = sourceBlock("21世纪大英汉词典", in: block),
                      !centuryBlock.contains("- 词性："),
                      centuryBlock.split(separator: "\n").contains(where: {
                          $0.range(of: #"^  [0-9]+\. "#,
                                   options: .regularExpression) != nil
                      }) else {
                    throw SmokeError.assertion("Century21 Markdown grouping")
                }
            }
            let block = ObsidianNoteStore.markdownBlock(for: entry, newline: "\n")
            for source in entry.sources where
                source.source == "牛津高阶 8" || source.source == "新牛津英文" {
                guard let semantic = source.semanticEntry, semantic.hasContent else { continue }
                semanticHierarchyCount += 1
                guard !semantic.partOfSpeechSections.isEmpty,
                      let sourceMarkdown = sourceBlock(source.source, in: block),
                      sourceMarkdown.contains("#### "),
                      !sourceMarkdown.contains("- 词性：") else {
                    throw SmokeError.assertion(
                        "missing semantic hierarchy: \(entry.headword)/\(source.source)"
                    )
                }
                let exampleCount = sourceMarkdown.components(separatedBy: "\n")
                    .filter { $0.contains("- 例句：") }.count
                let senseCount = sourceMarkdown.components(separatedBy: "\n")
                    .filter {
                        $0.range(of: #"^\s*[0-9]+\.\s"#,
                                 options: .regularExpression) != nil
                    }.count
                guard exampleCount <= 3, senseCount <= 5 else {
                    throw SmokeError.assertion("semantic export limits")
                }
                guard !sourceMarkdown.contains("参见：") else {
                    throw SmokeError.assertion("unclassified cross-reference title")
                }
                let sectionDerivatives = semantic.partOfSpeechSections
                    .flatMap(\.derivatives)
                if !sectionDerivatives.isEmpty {
                    guard sourceMarkdown.contains("##### 派生") else {
                        throw SmokeError.assertion("POS derivative relationship")
                    }
                }
                if !semantic.derivatives.isEmpty {
                    guard sourceMarkdown.contains("#### 派生词") else {
                        throw SmokeError.assertion("derivative section")
                    }
                }
                if entry.headword.lowercased() == "prompt",
                   source.source == "牛津高阶 8" {
                    guard sourceMarkdown.contains(
                        "##### 派生名词（由形容词 prompt 派生）"
                    ) else {
                        throw SmokeError.assertion("promptness Markdown ownership")
                    }
                }
                if entry.headword.lowercased() == "charge",
                   source.source == "牛津高阶 8" {
                    guard sourceMarkdown.split(separator: "\n").contains(where: {
                        $0.range(of: #"^2\.\s"#, options: .regularExpression) != nil
                    }), !sourceMarkdown.contains("2..") else {
                        throw SmokeError.assertion("charge Markdown sense 2")
                    }
                }
            }
        }
        guard semanticHierarchyCount >= 2 else {
            throw SmokeError.assertion("semantic hierarchy fixtures")
        }
        guard !content.contains("<script"),
              !content.contains("class="),
              !content.contains(".mdx"),
              !content.contains(".sqlite"),
              !content.contains("<!-- LocalDictionary:") else {
            throw SmokeError.assertion("unsafe export content")
        }
        print("MultiSourceObsidianSmoke: 4/4 real entries passed")
    }

    private static func sourceBlock(_ source: String, in content: String) -> String? {
        guard let start = content.range(of: "### \(source)\n") else { return nil }
        let remainder = content[start.lowerBound...]
        if let next = remainder.dropFirst().range(of: "\n### ") {
            return String(remainder[..<next.lowerBound])
        }
        return String(remainder)
    }

    enum SmokeError: Error {
        case invalidArguments
        case assertion(String)
    }
}
