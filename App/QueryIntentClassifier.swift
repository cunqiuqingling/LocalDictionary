import Foundation

enum QueryIntent: Equatable {
    case word
    case phrase
    case sentence
    case textTooLong
}

enum QueryLanguage: String, Codable, Equatable, Sendable {
    case english
    case simplifiedChinese
    case mixed
    case undetermined
}

enum QueryIntentRejectionReason: Equatable {
    case none
    case empty
    case mostlyNonEnglish
    case characterLimit
    case wordLimit
    case multipleParagraphs
    case tooManySentences
}

struct QueryIntentClassification: Equatable {
    let intent: QueryIntent
    let normalizedText: String
    let englishWordCount: Int
    let rejectionReason: QueryIntentRejectionReason
    let shouldAttemptLocalLookupFirst: Bool
    let language: QueryLanguage
    let sentenceCount: Int
    let paragraphCount: Int

    var isLongForm: Bool {
        intent == .sentence && (sentenceCount > 1 || paragraphCount > 1 ||
            normalizedText.count > 280)
    }

    var isChineseLookup: Bool {
        (intent == .word || intent == .phrase) && language == .simplifiedChinese
    }
}

enum SentenceTextNormalizer {
    // 12,000 composed characters bounds duplicate String/NLTokenizer storage to a few
    // hundred KiB for normal UTF-8/UTF-16 text while admitting the required 1,000-character
    // analysis case. The UI never accepts an unbounded document.
    static let maximumCharacters = 12_000
    static let maximumLexicalTokens = 4_000

    static func normalize(_ source: String) -> String {
        let canonical = source.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        var currentLines: [String] = []
        for rawLine in canonical.components(separatedBy: "\n") {
            let line = collapseWhitespace(rawLine)
            if line.isEmpty {
                if !currentLines.isEmpty {
                    paragraphs.append(currentLines.joined(separator: " "))
                    currentLines.removeAll(keepingCapacity: true)
                }
            } else {
                currentLines.append(line)
            }
        }
        if !currentLines.isEmpty { paragraphs.append(currentLines.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func collapseWhitespace(_ source: String) -> String {
        var output = ""
        var pendingSpace = false
        for character in source {
            if character.isWhitespace {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace { output.append(" ") }
                output.append(character)
                pendingSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum QueryIntentClassifier {
    static func classify(_ source: String) -> QueryIntentClassification {
        let normalized = SentenceTextNormalizer.normalize(source)
        guard !normalized.isEmpty else { return rejected(normalized, reason: .empty) }
        guard normalized.count <= SentenceTextNormalizer.maximumCharacters else {
            return rejected(normalized, reason: .characterLimit)
        }

        let words = englishWords(in: normalized)
        let cjkCount = normalized.unicodeScalars.filter(Self.isCJK).count
        let language = languageProfile(englishLetters: words.reduce(0) { $0 + $1.count },
                                       cjkCount: cjkCount)
        let lexicalCount = words.count + cjkLexicalEstimate(normalized)
        guard lexicalCount <= SentenceTextNormalizer.maximumLexicalTokens else {
            return rejected(normalized, wordCount: words.count, reason: .wordLimit,
                            language: language)
        }
        guard words.count > 0 || cjkCount > 0 else {
            return rejected(normalized, wordCount: words.count, reason: .mostlyNonEnglish,
                            language: .undetermined)
        }

        let sentences = max(1, independentSentenceCount(in: normalized))
        let paragraphs = max(1, normalized.components(separatedBy: "\n\n").count)

        if language == .english, words.count == 1, paragraphs == 1,
           !hasTerminalSentencePunctuation(normalized) {
            return accepted(.word, normalized, words.count, language, sentences, paragraphs,
                            localFirst: true)
        }
        if language == .simplifiedChinese, paragraphs == 1,
           !hasTerminalSentencePunctuation(normalized), cjkCount <= 4,
           !containsSentenceSignal(normalized) {
            return accepted(.word, normalized, words.count, language, sentences, paragraphs,
                            localFirst: false)
        }

        let sentenceLike: Bool
        switch language {
        case .english:
            sentenceLike = paragraphs > 1 || sentences > 1 ||
                (words.count >= 6 && (hasTerminalSentencePunctuation(normalized) ||
                    hasFiniteVerbSignal(words)) &&
                    !looksLikeTitleOrTerm(words, text: normalized,
                                          terminalPunctuation:
                                            hasTerminalSentencePunctuation(normalized)))
        case .simplifiedChinese:
            sentenceLike = paragraphs > 1 || sentences > 1 || cjkCount > 12 ||
                hasTerminalSentencePunctuation(normalized) || containsSentenceSignal(normalized)
        case .mixed:
            sentenceLike = paragraphs > 1 || sentences > 1 ||
                hasTerminalSentencePunctuation(normalized) || lexicalCount >= 6
        case .undetermined:
            sentenceLike = false
        }

        if sentenceLike {
            return accepted(.sentence, normalized, words.count, language, sentences, paragraphs,
                            localFirst: language == .english && words.count <= 10 &&
                                paragraphs == 1 && sentences == 1)
        }
        return accepted(.phrase, normalized, words.count, language, sentences, paragraphs,
                        localFirst: language == .english)
    }

    static func englishWords(in source: String) -> [String] {
        var result: [String] = []
        var current = ""
        let apostrophes: Set<Character> = ["'", "’"]
        for character in source {
            if character.isASCIIEnglishLetter {
                current.append(character)
            } else if (apostrophes.contains(character) || character == "-") && !current.isEmpty {
                current.append(character)
            } else {
                finishWord(&current, into: &result)
            }
        }
        finishWord(&current, into: &result)
        return result
    }

    private static func accepted(_ intent: QueryIntent, _ normalized: String, _ wordCount: Int,
                                 _ language: QueryLanguage, _ sentenceCount: Int,
                                 _ paragraphCount: Int, localFirst: Bool)
        -> QueryIntentClassification {
        QueryIntentClassification(intent: intent, normalizedText: normalized,
                                  englishWordCount: wordCount, rejectionReason: .none,
                                  shouldAttemptLocalLookupFirst: localFirst,
                                  language: language, sentenceCount: sentenceCount,
                                  paragraphCount: paragraphCount)
    }

    private static func rejected(_ normalized: String, wordCount: Int = 0,
                                 reason: QueryIntentRejectionReason,
                                 language: QueryLanguage = .undetermined)
        -> QueryIntentClassification {
        QueryIntentClassification(intent: .textTooLong, normalizedText: normalized,
                                  englishWordCount: wordCount, rejectionReason: reason,
                                  shouldAttemptLocalLookupFirst: false,
                                  language: language, sentenceCount: 0, paragraphCount: 0)
    }

    private static func finishWord(_ current: inout String, into result: inout [String]) {
        while let last = current.last, last == "-" || last == "'" || last == "’" {
            current.removeLast()
        }
        if !current.isEmpty { result.append(current) }
        current = ""
    }

    private static func languageProfile(englishLetters: Int, cjkCount: Int) -> QueryLanguage {
        if englishLetters > 0 && cjkCount > 0 { return .mixed }
        if cjkCount > 0 { return .simplifiedChinese }
        if englishLetters > 0 { return .english }
        return .undetermined
    }

    private static func cjkLexicalEstimate(_ source: String) -> Int {
        let count = source.unicodeScalars.filter(isCJK).count
        return count == 0 ? 0 : max(1, (count + 1) / 2)
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func independentSentenceCount(in source: String) -> Int {
        var count = 0
        var inTerminator = false
        for character in source {
            let terminal = ".?!。？！".contains(character)
            if terminal && !inTerminator { count += 1 }
            inTerminator = terminal
        }
        return count
    }

    private static func hasTerminalSentencePunctuation(_ source: String) -> Bool {
        guard let last = source.last else { return false }
        return ".?!。？！”’\"".contains(last) &&
            source.contains { ".?!。？！".contains($0) }
    }

    private static func containsSentenceSignal(_ source: String) -> Bool {
        ["是", "有", "在", "把", "被", "因为", "但是", "如果", "虽然", "需要",
         "可以", "应该", "已经", "正在", "不会"].contains { source.contains($0) }
    }

    private static func hasFiniteVerbSignal(_ words: [String]) -> Bool {
        let auxiliaries: Set<String> = [
            "am", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did",
            "can", "could", "may", "might", "must", "shall", "should", "will", "would"
        ]
        let pronouns: Set<String> = [
            "i", "you", "he", "she", "it", "we", "they", "this", "that", "who", "which"
        ]
        let lower = words.map { $0.lowercased() }
        if lower.contains(where: auxiliaries.contains) { return true }
        if lower.contains(where: { $0.hasSuffix("ed") && $0.count > 4 }) { return true }
        return lower.count >= 8 &&
            lower.prefix(4).contains(where: pronouns.contains) &&
            lower.dropFirst().contains(where: { $0.hasSuffix("s") && $0.count > 3 })
    }

    private static func looksLikeTitleOrTerm(_ words: [String], text: String,
                                             terminalPunctuation: Bool) -> Bool {
        guard !terminalPunctuation, words.count <= 16 else { return false }
        let capitalized = words.filter { $0.first?.isUppercase == true }.count
        let titleLike = Double(capitalized) / Double(words.count) >= 0.65
        return titleLike && !text.contains(",") && !text.contains(";") && !text.contains(":")
    }
}

struct AIQueryGenerationGate {
    private(set) var generation: UInt64 = 0

    mutating func beginQuery() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ candidate: UInt64) -> Bool { candidate == generation }
}

private extension Character {
    var isASCIIEnglishLetter: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }
}
