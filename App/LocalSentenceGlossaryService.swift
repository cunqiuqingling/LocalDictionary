import Foundation
import NaturalLanguage

struct LocalGlossaryLookupResult: Equatable {
    let partOfSpeech: String
    let definitions: [String]
    let source: String
}

struct LocalGlossaryDictionarySource {
    let name: String
    let priority: Int
    let lookup: (String) -> LocalGlossaryLookupResult?
}

struct LocalSentenceGlossaryEntry: Equatable {
    let surface: String
    let lookupTerm: String
    let partOfSpeech: String
    let definitions: [String]
    let source: String
    let isPhrase: Bool

    var displayTerm: String {
        surface.caseInsensitiveCompare(lookupTerm) == .orderedSame
            ? surface : "\(surface) → \(lookupTerm)"
    }
}

struct LocalSentenceGlossary: Equatable {
    let sourceText: String
    let entries: [LocalSentenceGlossaryEntry]
    let candidateQueryCount: Int

    var hasEntries: Bool { !entries.isEmpty }
}

actor LocalSentenceGlossaryService {
    static let maximumPhraseCandidates = 24
    static let maximumCandidateQueries = 40
    static let maximumEntries = 12

    private struct Token {
        let surface: String
        let normalized: String
        let index: Int
    }

    private struct PhraseCandidate {
        let surface: String
        let lookup: String
        let tokenIndices: Set<Int>
        let score: Int
    }

    private let sources: [LocalGlossaryDictionarySource]

    init(sources: [LocalGlossaryDictionarySource]) {
        self.sources = sources.sorted { $0.priority < $1.priority }
    }

    func analyze(sentence: String) async -> LocalSentenceGlossary {
        let normalizedSentence = SentenceTextNormalizer.normalize(sentence)
        let tokens = Self.tokens(in: normalizedSentence)
        guard !normalizedSentence.isEmpty, !tokens.isEmpty else {
            return LocalSentenceGlossary(sourceText: normalizedSentence,
                                         entries: [], candidateQueryCount: 0)
        }

        var queryCount = 0
        var entries: [LocalSentenceGlossaryEntry] = []
        var coveredTokenIndices: Set<Int> = []
        var seenTerms: Set<String> = []

        for candidate in Self.phraseCandidates(from: tokens) {
            guard !Task.isCancelled,
                  queryCount < Self.maximumCandidateQueries,
                  entries.count < Self.maximumEntries else { break }
            guard candidate.tokenIndices.isDisjoint(with: coveredTokenIndices),
                  let hit = lookup(candidate.lookup,
                                   queryCount: &queryCount,
                                   maximumSources: 2),
                  let entry = Self.entry(surface: candidate.surface,
                                         lookupTerm: candidate.lookup,
                                         hit: hit,
                                         isPhrase: true) else { continue }
            let key = candidate.lookup.lowercased()
            guard seenTerms.insert(key).inserted else { continue }
            entries.append(entry)
            coveredTokenIndices.formUnion(candidate.tokenIndices)
        }

        for token in Self.prioritizedWordTokens(tokens, covered: coveredTokenIndices) {
            guard !Task.isCancelled,
                  queryCount < Self.maximumCandidateQueries,
                  entries.count < Self.maximumEntries else { break }
            let normalized = token.normalized.lowercased()
            guard seenTerms.insert(normalized).inserted else { continue }
            if let hit = lookup(normalized, queryCount: &queryCount),
               let entry = Self.entry(surface: token.surface,
                                      lookupTerm: normalized,
                                      hit: hit,
                                      isPhrase: false) {
                entries.append(entry)
                continue
            }
            guard queryCount < Self.maximumCandidateQueries,
                  let lemma = Self.safeLemma(for: normalized),
                  lemma != normalized else { continue }
            guard let lemmaHit = lookup(lemma, queryCount: &queryCount),
                  let entry = Self.entry(surface: token.surface,
                                         lookupTerm: lemma,
                                         hit: lemmaHit,
                                         isPhrase: false) else { continue }
            entries.append(entry)
        }

        return LocalSentenceGlossary(sourceText: normalizedSentence,
                                     entries: Array(entries.prefix(Self.maximumEntries)),
                                     candidateQueryCount: queryCount)
    }

    private func lookup(_ term: String, queryCount: inout Int,
                        maximumSources: Int? = nil) -> LocalGlossaryLookupResult? {
        let candidates = maximumSources.map { Array(sources.prefix($0)) } ?? sources
        for source in candidates {
            guard !Task.isCancelled,
                  queryCount < Self.maximumCandidateQueries else { return nil }
            queryCount += 1
            if let hit = source.lookup(term),
               !Self.uniqueChinese(hit.definitions, maximum: 1).isEmpty {
                return hit
            }
        }
        return nil
    }

    private static func entry(surface: String, lookupTerm: String,
                              hit: LocalGlossaryLookupResult,
                              isPhrase: Bool) -> LocalSentenceGlossaryEntry? {
        let definitions = uniqueChinese(hit.definitions, maximum: 2)
        guard !definitions.isEmpty else { return nil }
        return LocalSentenceGlossaryEntry(
            surface: clean(surface, limit: 160),
            lookupTerm: clean(lookupTerm, limit: 160),
            partOfSpeech: clean(hit.partOfSpeech, limit: 60),
            definitions: definitions,
            source: clean(hit.source, limit: 80),
            isPhrase: isPhrase
        )
    }

    private static func phraseCandidates(from tokens: [Token]) -> [PhraseCandidate] {
        guard tokens.count >= 2 else { return [] }
        var candidates: [PhraseCandidate] = []
        let maximumWindows = 96
        for start in tokens.indices {
            for length in 2...5 where start + length <= tokens.count {
                guard candidates.count < maximumWindows else { break }
                let slice = Array(tokens[start..<(start + length)])
                let contentCount = slice.filter { !stopwords.contains($0.normalized) }.count
                let hasConnector = slice.contains { phraseConnectors.contains($0.normalized) }
                guard contentCount >= 2 || (contentCount >= 1 && hasConnector) else { continue }
                let lookup = slice.map(\.normalized).joined(separator: " ")
                var score = contentCount * 3 + length
                if length == 2 && contentCount == 2 { score += 6 }
                if hasConnector { score += 4 }
                if slice.contains(where: { hasAcademicSuffix($0.normalized) }) { score += 3 }
                if ["associated with", "result in", "found to", "not only", "but also"]
                    .contains(where: lookup.contains) { score += 8 }
                candidates.append(PhraseCandidate(
                    surface: slice.map(\.surface).joined(separator: " "),
                    lookup: lookup,
                    tokenIndices: Set(slice.map(\.index)),
                    score: score
                ))
            }
            if candidates.count >= maximumWindows { break }
        }
        let budgets = [5: 1, 4: 1, 3: 3, 2: 5]
        var selected: [PhraseCandidate] = []
        for length in stride(from: 5, through: 2, by: -1) {
            let ranked = candidates.filter { $0.tokenIndices.count == length }.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.tokenIndices.min() ?? 0) < ($1.tokenIndices.min() ?? 0)
            }
            selected.append(contentsOf: ranked.prefix(budgets[length] ?? 0))
        }
        return Array(selected.prefix(maximumPhraseCandidates))
    }

    private static func prioritizedWordTokens(_ tokens: [Token],
                                              covered: Set<Int>) -> [Token] {
        var seen: Set<String> = []
        return tokens.filter { token in
            let value = token.normalized
            guard !covered.contains(token.index),
                  !stopwords.contains(value),
                  value.count >= 3,
                  seen.insert(value).inserted else { return false }
            return true
        }.sorted {
            let lhs = wordPriority($0.normalized)
            let rhs = wordPriority($1.normalized)
            if lhs != rhs { return lhs > rhs }
            return $0.index < $1.index
        }
    }

    private static func wordPriority(_ word: String) -> Int {
        var score = min(word.count, 12)
        if hasAcademicSuffix(word) { score += 6 }
        if word.count >= 8 { score += 3 }
        return score
    }

    private static func hasAcademicSuffix(_ word: String) -> Bool {
        ["tion", "sion", "ment", "ity", "ive", "ous", "ally", "ically", "ology", "genic"]
            .contains(where: word.hasSuffix)
    }

    static func safeLemma(for word: String) -> String? {
        let normalized = word.lowercased()
        guard normalized.count >= 4 else { return nil }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = normalized
        let (lemmaTag, _) = tagger.tag(at: normalized.startIndex,
                                      unit: .word,
                                      scheme: .lemma)
        if let lemma = lemmaTag?.rawValue.lowercased(),
           lemma != normalized,
           lemma.count >= 3,
           lemma.allSatisfy({ $0.isASCIIEnglishLetter }) {
            return lemma
        }

        if normalized.hasSuffix("ied"), normalized.count > 4 {
            return String(normalized.dropLast(3)) + "y"
        }
        if normalized.hasSuffix("ed"), normalized.count > 5 {
            var base = String(normalized.dropLast(2))
            if base.count >= 4, base.last == base.dropLast().last,
               let last = base.last, !"aeiou".contains(last) {
                base.removeLast()
            }
            return base
        }
        if normalized.hasSuffix("ing"), normalized.count > 6 {
            var base = String(normalized.dropLast(3))
            if base.count >= 4, base.last == base.dropLast().last,
               let last = base.last, !"aeiou".contains(last) {
                base.removeLast()
            }
            return base
        }
        if normalized.hasSuffix("ies"), normalized.count > 4 {
            return String(normalized.dropLast(3)) + "y"
        }
        if normalized.hasSuffix("es"), normalized.count > 4 {
            if ["ses", "xes", "zes", "ches", "shes"].contains(where: normalized.hasSuffix) {
                return String(normalized.dropLast(2))
            }
            return String(normalized.dropLast())
        }
        if normalized.hasSuffix("s"), !normalized.hasSuffix("ss"), normalized.count > 4 {
            return String(normalized.dropLast())
        }
        return nil
    }

    private static func tokens(in sentence: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func finish() {
            while let last = current.last, last == "-" || last == "'" || last == "’" {
                current.removeLast()
            }
            guard !current.isEmpty else { return }
            tokens.append(Token(surface: current,
                                normalized: current.lowercased(),
                                index: tokens.count))
            current = ""
        }
        for character in sentence {
            if character.isASCIIEnglishLetter {
                current.append(character)
            } else if (character == "-" || character == "'" || character == "’") && !current.isEmpty {
                current.append(character)
            } else {
                finish()
            }
        }
        finish()
        return tokens
    }

    private static func uniqueChinese(_ values: [String], maximum: Int) -> [String] {
        var result: [String] = []
        for value in values {
            let cleaned = clean(value, limit: 180)
            guard !cleaned.isEmpty, containsCJK(cleaned), !result.contains(cleaned) else { continue }
            result.append(cleaned)
            if result.count == maximum { break }
        }
        return result
    }

    private static func clean(_ value: String, limit: Int) -> String {
        String(SentenceTextNormalizer.normalize(value).prefix(limit))
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    private static let phraseConnectors: Set<String> = [
        "be", "been", "being", "to", "in", "on", "of", "with", "for", "as", "by", "from"
    ]

    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "to", "and", "or", "but", "as", "at", "by", "for", "from",
        "in", "into", "on", "onto", "with", "without", "was", "were", "is", "are", "am", "be",
        "been", "being", "do", "does", "did", "have", "has", "had", "i", "you", "he", "she",
        "it", "we", "they", "this", "that", "these", "those", "which", "who", "whom", "whose",
        "not", "only", "also", "very", "every", "my", "your", "his", "her", "our", "their"
    ]
}

private extension Character {
    var isASCIIEnglishLetter: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }
}
