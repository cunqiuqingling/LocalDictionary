import Foundation

enum QueryIntent: Equatable {
    case word
    case phrase
    case sentence
    case textTooLong
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
}

enum SentenceTextNormalizer {
    static let maximumCharacters = 800
    static let maximumEnglishWords = 120

    static func normalize(_ source: String) -> String {
        var output = ""
        var hasPendingSpace = false
        for character in source.precomposedStringWithCanonicalMapping {
            if character.isWhitespace {
                hasPendingSpace = !output.isEmpty
            } else {
                if hasPendingSpace { output.append(" ") }
                output.append(character)
                hasPendingSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum QueryIntentClassifier {
    static func classify(_ source: String) -> QueryIntentClassification {
        let normalized = SentenceTextNormalizer.normalize(source)
        guard !normalized.isEmpty else {
            return rejected(normalized, reason: .empty)
        }
        guard normalized.count <= SentenceTextNormalizer.maximumCharacters else {
            return rejected(normalized, reason: .characterLimit)
        }
        guard !hasMultipleParagraphs(source) else {
            return rejected(normalized, reason: .multipleParagraphs)
        }

        let words = englishWords(in: normalized)
        guard words.count <= SentenceTextNormalizer.maximumEnglishWords else {
            return rejected(normalized, wordCount: words.count, reason: .wordLimit)
        }
        guard isPrimarilyEnglish(normalized), !words.isEmpty else {
            return rejected(normalized, wordCount: words.count, reason: .mostlyNonEnglish)
        }
        guard independentSentenceCount(in: normalized) <= 3 else {
            return rejected(normalized, wordCount: words.count, reason: .tooManySentences)
        }

        if words.count == 1 {
            return QueryIntentClassification(intent: .word,
                                             normalizedText: normalized,
                                             englishWordCount: 1,
                                             rejectionReason: .none,
                                             shouldAttemptLocalLookupFirst: true)
        }

        let terminalPunctuation = hasTerminalSentencePunctuation(normalized)
        let finiteVerbSignal = hasFiniteVerbSignal(words)
        let looksLikeSentence = words.count >= 6 &&
            (terminalPunctuation || finiteVerbSignal) &&
            !looksLikeTitleOrTerm(words, text: normalized, terminalPunctuation: terminalPunctuation)

        if looksLikeSentence {
            return QueryIntentClassification(intent: .sentence,
                                             normalizedText: normalized,
                                             englishWordCount: words.count,
                                             rejectionReason: .none,
                                             shouldAttemptLocalLookupFirst: words.count <= 10)
        }
        return QueryIntentClassification(intent: .phrase,
                                         normalizedText: normalized,
                                         englishWordCount: words.count,
                                         rejectionReason: .none,
                                         shouldAttemptLocalLookupFirst: true)
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

    private static func finishWord(_ current: inout String, into result: inout [String]) {
        while let last = current.last, last == "-" || last == "'" || last == "’" {
            current.removeLast()
        }
        if !current.isEmpty { result.append(current) }
        current = ""
    }

    private static func rejected(_ normalized: String,
                                 wordCount: Int = 0,
                                 reason: QueryIntentRejectionReason) -> QueryIntentClassification {
        QueryIntentClassification(intent: .textTooLong,
                                  normalizedText: normalized,
                                  englishWordCount: wordCount,
                                  rejectionReason: reason,
                                  shouldAttemptLocalLookupFirst: false)
    }

    private static func hasMultipleParagraphs(_ source: String) -> Bool {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var sawContent = false
        var sawBlankAfterContent = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if sawContent { sawBlankAfterContent = true }
            } else {
                if sawBlankAfterContent { return true }
                sawContent = true
            }
        }
        return false
    }

    private static func isPrimarilyEnglish(_ source: String) -> Bool {
        var asciiEnglishLetters = 0
        var allLetters = 0
        for scalar in source.unicodeScalars where CharacterSet.letters.contains(scalar) {
            allLetters += 1
            if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
                asciiEnglishLetters += 1
            }
        }
        guard allLetters > 0 else { return false }
        return Double(asciiEnglishLetters) / Double(allLetters) >= 0.55
    }

    private static func independentSentenceCount(in source: String) -> Int {
        var count = 0
        var inTerminator = false
        for character in source {
            let terminal = character == "." || character == "?" || character == "!"
                || character == "。" || character == "？" || character == "！"
            if terminal && !inTerminator { count += 1 }
            inTerminator = terminal
        }
        return count
    }

    private static func hasTerminalSentencePunctuation(_ source: String) -> Bool {
        guard let last = source.last else { return false }
        return [".", "?", "!", "。", "？", "！", "”", "’", "\""]
            .contains(last) && source.contains { $0 == "." || $0 == "?" || $0 == "!" }
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
        if lower.count >= 8,
           lower.prefix(4).contains(where: pronouns.contains),
           lower.dropFirst().contains(where: { $0.hasSuffix("s") && $0.count > 3 }) {
            return true
        }
        return false
    }

    private static func looksLikeTitleOrTerm(_ words: [String], text: String,
                                             terminalPunctuation: Bool) -> Bool {
        guard !terminalPunctuation, words.count <= 16 else { return false }
        let capitalized = words.filter { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }.count
        let titleLike = Double(capitalized) / Double(words.count) >= 0.65
        let containsClausePunctuation = text.contains(",") || text.contains(";") || text.contains(":")
        return titleLike && !containsClausePunctuation
    }
}

struct AIQueryGenerationGate {
    private(set) var generation: UInt64 = 0

    mutating func beginQuery() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

private extension Character {
    var isASCIIEnglishLetter: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }
}
