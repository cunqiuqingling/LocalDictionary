import AppKit
import Foundation
import NaturalLanguage

struct OfflineSentenceAnalysis: Equatable, Sendable {
    let title: String
    let subjectOrTopic: String
    let predicate: String
    let objectOrComplement: String
    let structureHints: [String]
    let expressions: [String]
    let confidence: String
}

protocol OfflineTextAnalyzing: Sendable {
    func analyze(sentence: String, language: QueryLanguage) -> OfflineSentenceAnalysis
}

enum LongTextSentenceTranslationState: Equatable, Sendable {
    case awaitingDirection
    case translating(OfflineTranslationPair)
    case translated(OfflineTranslationPair)
    case languagePackRequired(OfflineTranslationPair)
    case unsupported(OfflineTranslationPair)
    case failed(OfflineTranslationPair)
    case cancelled(OfflineTranslationPair?)
    case notNeeded

    var pair: OfflineTranslationPair? {
        switch self {
        case .translating(let pair), .translated(let pair),
             .languagePackRequired(let pair), .unsupported(let pair),
             .failed(let pair):
            return pair
        case .cancelled(let pair):
            return pair
        case .awaitingDirection, .notNeeded:
            return nil
        }
    }
}

struct SentenceDirectionGenerationGate: Sendable {
    private var values: [String: UInt64] = [:]

    mutating func begin(sentenceID: String) -> UInt64 {
        let next = (values[sentenceID] ?? 0) &+ 1
        values[sentenceID] = next
        return next
    }

    func accepts(sentenceID: String, generation: UInt64) -> Bool {
        values[sentenceID] == generation
    }

    mutating func invalidate(sentenceID: String) {
        _ = begin(sentenceID: sentenceID)
    }

    mutating func invalidateAll() {
        for sentenceID in Array(values.keys) {
            values[sentenceID, default: 0] &+= 1
        }
    }
}

struct LongTextSentence: Equatable, Sendable, Identifiable {
    let id: String
    let order: Int
    let paragraph: Int
    let sourceText: String
    let language: QueryLanguage
    var translatedText: String?
    var translationError: OfflineTranslationError?
    var translationState: LongTextSentenceTranslationState
    var basicAnalysis: OfflineSentenceAnalysis
}

struct OfflineVocabularyItem: Equatable, Sendable {
    let term: String
    let lemma: String
    let meaningOrSuggestion: String
    let source: String
    let score: Int
    let professional: Bool
}

struct LongTextAnalysisResult: Equatable, Sendable {
    let sourceText: String
    let sentences: [LongTextSentence]
    let vocabulary: [OfflineVocabularyItem]
    let requiresDirectionChoice: Bool
    let generatedAt: Date

    var completeTranslation: String {
        sentences.map { sentence in
            if let translated = sentence.translatedText { return translated }
            switch sentence.translationState {
            case .awaitingDirection: return "【请选择本句翻译方向】"
            case .translating: return "【本句正在翻译】"
            case .languagePackRequired: return "【本句需要准备系统语言包】"
            case .unsupported: return "【系统不支持本句所选方向】"
            case .failed: return "【本句基础翻译失败，可重试】"
            case .cancelled: return "【本句翻译已取消】"
            case .notNeeded: return sentence.sourceText
            case .translated: return "【本句基础翻译暂不可用】"
            }
        }
            .joined(separator: "\n")
    }

    func replacingSentence(_ replacement: LongTextSentence,
                           vocabulary replacementVocabulary: [OfflineVocabularyItem]? = nil)
        -> LongTextAnalysisResult {
        var updated = sentences
        guard let index = updated.firstIndex(where: { $0.id == replacement.id }) else {
            return self
        }
        updated[index] = replacement
        return LongTextAnalysisResult(
            sourceText: sourceText,
            sentences: updated,
            vocabulary: replacementVocabulary ?? vocabulary,
            requiresDirectionChoice: updated.contains {
                if case .awaitingDirection = $0.translationState { return true }
                return false
            },
            generatedAt: Date()
        )
    }

    func replacingVocabulary(_ replacement: [OfflineVocabularyItem])
        -> LongTextAnalysisResult {
        LongTextAnalysisResult(
            sourceText: sourceText,
            sentences: sentences,
            vocabulary: Array(replacement.prefix(OfflineVocabularySelector.maximumItems)),
            requiresDirectionChoice: requiresDirectionChoice,
            generatedAt: Date()
        )
    }
}

struct TranslationGlossaryEvidence: Equatable, Sendable {
    let suggestion: String
    let source: String
    let professional: Bool
}

protocol TranslationGlossaryService: Sendable {
    func evidence(for term: String, language: QueryLanguage) async
        -> TranslationGlossaryEvidence?
}

struct EmptyTranslationGlossaryService: TranslationGlossaryService {
    func evidence(for term: String, language: QueryLanguage) async
        -> TranslationGlossaryEvidence? { nil }
}

enum LongTextSegmenter {
    static func segment(_ source: String) -> [LongTextSentence] {
        let normalized = SentenceTextNormalizer.normalize(source)
        guard !normalized.isEmpty else { return [] }
        var output: [LongTextSentence] = []
        for (paragraphIndex, paragraph) in normalized.components(separatedBy: "\n\n").enumerated() {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            var values: [String] = []
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let value = String(paragraph[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { values.append(value) }
                return true
            }
            if values.isEmpty { values = [paragraph] }
            for value in values {
                let language = sentenceLanguage(value)
                let order = output.count
                let needsTranslation = containsTranslatableLanguage(value)
                let initialState: LongTextSentenceTranslationState
                let initialTranslation: String?
                if !needsTranslation {
                    initialState = .notNeeded
                    initialTranslation = value
                } else {
                    switch language {
                    case .english:
                        initialState = .translating(OfflineTranslationPair(
                            source: .english, target: .simplifiedChinese
                        ))
                    case .simplifiedChinese:
                        initialState = .translating(OfflineTranslationPair(
                            source: .simplifiedChinese, target: .english
                        ))
                    case .mixed, .undetermined:
                        initialState = .awaitingDirection
                    }
                    initialTranslation = nil
                }
                output.append(LongTextSentence(
                    id: String(format: "sentence-%04d", order + 1),
                    order: order,
                    paragraph: paragraphIndex,
                    sourceText: value,
                    language: language,
                    translatedText: initialTranslation,
                    translationError: nil,
                    translationState: initialState,
                    basicAnalysis: BasicSentenceAnalyzer().analyze(
                        sentence: value, language: language
                    )
                ))
            }
        }
        return output
    }

    static func sentenceLanguage(_ value: String) -> QueryLanguage {
        let classified = QueryIntentClassifier.classify(value).language
        if classified != .mixed && classified != .undetermined { return classified }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(value)
        switch recognizer.dominantLanguage {
        case .simplifiedChinese, .traditionalChinese: return .simplifiedChinese
        case .english: return .english
        default: return classified
        }
    }

    static func containsTranslatableLanguage(_ value: String) -> Bool {
        guard !looksLikeURL(value) else { return false }
        return value.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return false }
        return !trimmed.contains(where: \.isWhitespace)
    }
}

struct BasicSentenceAnalyzer: OfflineTextAnalyzing {
    func analyze(sentence: String, language: QueryLanguage) -> OfflineSentenceAnalysis {
        switch language {
        case .english: return analyzeEnglish(sentence)
        case .simplifiedChinese: return analyzeChinese(sentence)
        case .mixed, .undetermined:
            return OfflineSentenceAnalysis(
                title: "基础结构识别", subjectOrTopic: "未可靠识别",
                predicate: "未可靠识别", objectOrComplement: "未可靠识别",
                structureHints: ["语言方向不确定，需要选择方向或使用 AI 深度分析。"],
                expressions: [], confidence: "低"
            )
        }
    }

    private func analyzeEnglish(_ sentence: String) -> OfflineSentenceAnalysis {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = sentence
        var tokens: [(text: String, tag: NLTag?, range: Range<String.Index>)] = []
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word,
                             scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            tokens.append((String(sentence[range]), tag, range))
            return true
        }
        let verbIndex = tokens.firstIndex {
            $0.tag == .verb || $0.tag == .otherWord &&
                ["is", "are", "was", "were", "has", "have", "do", "does", "did"]
                    .contains($0.text.lowercased())
        }
        let subject = verbIndex.flatMap { index in
            cleanSpan(tokens.prefix(index).map(\.text).joined(separator: " "), maximumWords: 10)
        } ?? "可能未可靠识别"
        let predicate = verbIndex.map { tokens[$0].text } ?? "可能未可靠识别"
        let object = verbIndex.flatMap { index in
            cleanSpan(tokens.dropFirst(index + 1).map(\.text).joined(separator: " "),
                      maximumWords: 14)
        } ?? "可能未可靠识别"

        let lower = sentence.lowercased()
        var hints: [String] = ["主句候选已按首个主要谓语划分。"]
        if lower.contains(" and ") || lower.contains(" or ") ||
            lower.contains(" but ") { hints.append("包含并列结构。") }
        if ["which", "who", "whom", "whose", "that"].contains(where: {
            lower.contains(" \($0) ")
        }) { hints.append("可能包含定语从句。") }
        if ["because", "although", "while", "if", "unless", "when", "since"].contains(where: {
            lower.contains("\($0) ")
        }) { hints.append("可能包含状语从句。") }
        if lower.contains(" that ") { hints.append("that 可能引出名词性从句。") }
        if [" can ", " could ", " may ", " might ", " must ", " should ", " would "]
            .contains(where: lower.contains) { hints.append("包含情态动词。") }
        if [" not ", "n't ", " never ", " no "].contains(where: lower.contains) {
            hints.append("包含否定表达。")
        }
        if lower.range(of: #"\b(?:is|are|was|were|be|been|being)\s+\w+(?:ed|en)\b"#,
                       options: .regularExpression) != nil {
            hints.append("可能包含被动结构。")
        }
        if lower.contains(" have ") || lower.contains(" has ") || lower.contains(" had ") {
            hints.append("可能包含完成体。")
        }
        if lower.range(of: #"\bto\s+\w+ing?\b|\b\w+ing\b"#,
                       options: .regularExpression) != nil {
            hints.append("可能包含非谓语结构。")
        }
        if tokens.count > 24 { hints.append("句子含有较长修饰语，建议分层阅读。") }
        return OfflineSentenceAnalysis(
            title: "基础结构识别", subjectOrTopic: subject, predicate: predicate,
            objectOrComplement: object, structureHints: Array(hints.prefix(8)),
            expressions: importantEnglishExpressions(sentence), confidence:
                verbIndex == nil ? "低" : "中"
        )
    }

    private func analyzeChinese(_ sentence: String) -> OfflineSentenceAnalysis {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let predicateSignals = ["是", "有", "在", "需要", "可以", "应该", "导致", "表明",
                                "认为", "发现", "改善", "增加", "减少", "使用"]
        let predicate = predicateSignals.first(where: clean.contains) ?? "可能未可靠识别"
        let split = predicate == "可能未可靠识别"
            ? nil : clean.range(of: predicate)
        let topic = split.map { String(clean[..<$0.lowerBound]) }
            .flatMap { cleanSpan($0, maximumWords: 18) } ?? "可能未可靠识别"
        let object = split.map { String(clean[$0.upperBound...]) }
            .flatMap { cleanSpan($0, maximumWords: 24) } ?? "可能未可靠识别"
        var hints: [String] = ["按话题/核心谓语候选进行基础切分。"]
        if clean.contains("把") { hints.append("可能包含“把”字句。") }
        if clean.contains("被") { hints.append("可能包含“被”字句。") }
        if clean.contains("因为") || clean.contains("因此") { hints.append("包含因果提示。") }
        if clean.contains("但是") || clean.contains("然而") || clean.contains("却") {
            hints.append("包含转折提示。")
        }
        if clean.contains("如果") || clean.contains("只要") || clean.contains("除非") {
            hints.append("包含条件提示。")
        }
        if clean.contains("和") || clean.contains("以及") || clean.contains("并且") {
            hints.append("可能包含并列结构。")
        }
        if clean.range(of: #"(今天|昨天|目前|随后|期间|年|月|日)"#,
                       options: .regularExpression) != nil {
            hints.append("包含时间短语候选。")
        }
        if clean.range(of: #"(在|从|到)[^，。！？]{1,20}(中|内|上|下|里|外)"#,
                       options: .regularExpression) != nil {
            hints.append("包含地点或范围短语候选。")
        }
        return OfflineSentenceAnalysis(
            title: "基础结构识别", subjectOrTopic: topic, predicate: predicate,
            objectOrComplement: object, structureHints: Array(hints.prefix(8)),
            expressions: [], confidence: split == nil ? "低" : "中"
        )
    }

    private func importantEnglishExpressions(_ sentence: String) -> [String] {
        let lower = sentence.lowercased()
        return ["not only", "but also", "associated with", "result in", "rather than",
                "in order to", "as a result", "even though"]
            .filter(lower.contains)
    }

    private func cleanSpan(_ value: String, maximumWords: Int) -> String? {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        guard !parts.isEmpty else { return nil }
        let clipped = parts.prefix(maximumWords).joined(separator: " ")
        return parts.count > maximumWords ? clipped + "…" : clipped
    }
}

struct OfflineVocabularySelector: Sendable {
    static let maximumItems = 15

    func select(from sentences: [LongTextSentence],
                glossary: any TranslationGlossaryService) async -> [OfflineVocabularyItem] {
        var candidates: [(term: String, lemma: String, frequency: Int, score: Int)] = []
        let english = sentences.filter {
            $0.language == .english || $0.translationState.pair?.source == .english
        }.map(\.sourceText)
            .joined(separator: " ")
        if !english.isEmpty { candidates.append(contentsOf: englishCandidates(english)) }
        let chinese = sentences.filter {
            $0.language == .simplifiedChinese ||
                $0.translationState.pair?.source == .simplifiedChinese
        }.map(\.sourceText)
            .joined(separator: "")
        if !chinese.isEmpty { candidates.append(contentsOf: chineseCandidates(chinese)) }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.lemma < $1.lemma
        }
        var output: [OfflineVocabularyItem] = []
        var seen: Set<String> = []
        for candidate in candidates {
            guard output.count < Self.maximumItems, seen.insert(candidate.lemma).inserted else {
                continue
            }
            let language: QueryLanguage = candidate.term.unicodeScalars.contains {
                (0x3400...0x9FFF).contains($0.value)
            } ? .simplifiedChinese : .english
            let evidence = await glossary.evidence(for: candidate.term, language: language)
            output.append(OfflineVocabularyItem(
                term: candidate.term, lemma: candidate.lemma,
                meaningOrSuggestion: evidence?.suggestion ?? "本地词典暂无可靠释义",
                source: evidence?.source ?? "基础词法筛选",
                score: candidate.score + (evidence == nil ? 0 : 8),
                professional: evidence?.professional ?? false
            ))
        }
        return output.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.lemma < $1.lemma
        }.prefix(Self.maximumItems).map { $0 }
    }

    private func englishCandidates(_ text: String)
        -> [(term: String, lemma: String, frequency: Int, score: Int)] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var forms: [String: (term: String, count: Int)] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let term = String(text[range])
            let lower = term.lowercased()
            guard lower.count >= 4, lower.allSatisfy(\.isLetter),
                  !Self.englishStopwords.contains(lower) else { return true }
            let lemma = LocalSentenceGlossaryService.safeLemma(for: lower) ?? lower
            let old = forms[lemma] ?? (term, 0)
            forms[lemma] = (old.term, old.count + 1)
            return true
        }
        return forms.map { lemma, value in
            var difficulty = min(lemma.count, 14)
            if ["tion", "sion", "ment", "ity", "ology", "genic", "pharm", "clinical"]
                .contains(where: lemma.contains) { difficulty += 8 }
            if lemma.count >= 9 { difficulty += 5 }
            return (value.term, lemma, value.count,
                    difficulty + min(value.count, 4) * 2)
        }
    }

    private func chineseCandidates(_ text: String)
        -> [(term: String, lemma: String, frequency: Int, score: Int)] {
        let characters = text.filter { character in
            character.unicodeScalars.allSatisfy {
                (0x3400...0x4DBF).contains($0.value) ||
                    (0x4E00...0x9FFF).contains($0.value)
            }
        }
        let values = Array(characters)
        guard values.count >= 2 else { return [] }
        var counts: [String: Int] = [:]
        for length in 2...min(4, values.count) {
            for start in 0...(values.count - length) {
                let term = String(values[start..<(start + length)])
                guard !Self.chineseStopwords.contains(term) else { continue }
                counts[term, default: 0] += 1
            }
        }
        return counts.map { term, count in
            (term, term, count, term.count * 3 + min(count, 4) * 2)
        }
    }

    private static let englishStopwords: Set<String> = [
        "this", "that", "these", "those", "with", "from", "into", "have", "has", "had",
        "were", "was", "are", "and", "but", "for", "the", "not", "you", "your", "they",
        "their", "which", "when", "where", "what", "would", "could", "should", "there"
    ]
    private static let chineseStopwords: Set<String> = [
        "的是", "了的", "这个", "那个", "以及", "可以", "进行", "我们", "他们", "一个"
    ]
}

actor LongTextAnalysisPipeline {
    private let translation: OfflineTranslationCoordinator
    private let glossary: any TranslationGlossaryService
    private let vocabulary = OfflineVocabularySelector()

    init(translation: OfflineTranslationCoordinator,
         glossary: any TranslationGlossaryService = EmptyTranslationGlossaryService()) {
        self.translation = translation
        self.glossary = glossary
    }

    func analyze(_ source: String) async throws -> LongTextAnalysisResult {
        var sentences = LongTextSegmenter.segment(source)
        guard !sentences.isEmpty else { throw OfflineTranslationError.emptyInput }
        try Task.checkCancellation()

        let translatable = sentences.compactMap { sentence -> OfflineTranslationRequest? in
            guard case .translating(let pair) = sentence.translationState else { return nil }
            return OfflineTranslationRequest(id: sentence.id, sourceText: sentence.sourceText,
                                             pair: pair)
        }
        let groups = Dictionary(grouping: translatable, by: \.pair)
        var translatedByID: [String: OfflineTranslationResponse] = [:]
        var errorsByID: [String: OfflineTranslationError] = [:]
        for pair in groups.keys.sorted(by: { $0.source.rawValue < $1.source.rawValue }) {
            guard let requests = groups[pair] else { continue }
            // The system host is sequential. Isolating requests here preserves sentence-level
            // failure semantics without increasing actual TranslationSession concurrency.
            for request in requests {
                try Task.checkCancellation()
                do {
                    let responses = try await translation.translate([request])
                    guard let response = responses.first else {
                        errorsByID[request.id] = .invalidResponse
                        continue
                    }
                    translatedByID[response.id] = response
                } catch let error as OfflineTranslationError {
                    errorsByID[request.id] = error
                } catch is CancellationError {
                    throw OfflineTranslationError.cancelled
                } catch {
                    errorsByID[request.id] = .systemFailure
                }
            }
        }
        for index in sentences.indices {
            if let response = translatedByID[sentences[index].id] {
                sentences[index].translatedText = response.translatedText
                sentences[index].translationError = nil
                sentences[index].translationState = .translated(response.pair)
            } else if let error = errorsByID[sentences[index].id],
                      let pair = sentences[index].translationState.pair {
                sentences[index].translationError = error
                sentences[index].translationState = Self.state(for: error, pair: pair)
            }
        }
        let selected = await vocabulary.select(from: sentences, glossary: glossary)
        try Task.checkCancellation()
        return LongTextAnalysisResult(
            sourceText: SentenceTextNormalizer.normalize(source), sentences: sentences,
            vocabulary: Array(selected.prefix(OfflineVocabularySelector.maximumItems)),
            requiresDirectionChoice: sentences.contains {
                if case .awaitingDirection = $0.translationState { return true }
                return false
            },
            generatedAt: Date()
        )
    }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability {
        await translation.availability(for: pair)
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        try await translation.prepareLanguagePack(for: pair)
    }

    func translateSentence(in result: LongTextAnalysisResult,
                           sentenceID: String,
                           pair: OfflineTranslationPair) async throws
        -> LongTextAnalysisResult {
        guard let sentence = result.sentences.first(where: { $0.id == sentenceID }) else {
            throw OfflineTranslationError.emptyInput
        }
        let translated = try await translateSingleSentence(sentence, pair: pair)
        let intermediate = result.replacingSentence(translated)
        let selected = await selectVocabulary(from: intermediate.sentences)
        try Task.checkCancellation()
        return intermediate.replacingSentence(
            translated,
            vocabulary: selected
        )
    }

    func translateSingleSentence(_ source: LongTextSentence,
                                 pair: OfflineTranslationPair) async throws
        -> LongTextSentence {
        guard LongTextSegmenter.containsTranslatableLanguage(source.sourceText) else {
            throw OfflineTranslationError.emptyInput
        }
        try Task.checkCancellation()
        let request = OfflineTranslationRequest(
            id: source.id, sourceText: source.sourceText, pair: pair
        )
        let responses = try await translation.translate([request])
        guard let response = responses.first else {
            throw OfflineTranslationError.invalidResponse
        }
        var sentence = source
        sentence.translatedText = response.translatedText
        sentence.translationError = nil
        sentence.translationState = .translated(pair)
        return sentence
    }

    func selectVocabulary(from sentences: [LongTextSentence]) async
        -> [OfflineVocabularyItem] {
        let selected = await vocabulary.select(from: sentences, glossary: glossary)
        return Array(selected.prefix(OfflineVocabularySelector.maximumItems))
    }

    nonisolated static func state(for error: OfflineTranslationError,
                                  pair: OfflineTranslationPair)
        -> LongTextSentenceTranslationState {
        switch error {
        case .languagePackRequired: return .languagePackRequired(pair)
        case .unsupportedLanguagePair: return .unsupported(pair)
        case .cancelled: return .cancelled(pair)
        case .emptyInput, .hostUnavailable, .hostEnded, .invalidResponse, .systemFailure:
            return .failed(pair)
        }
    }
}

enum LongTextNativeAction: Equatable, Sendable {
    case translate(sentenceID: String, pair: OfflineTranslationPair, generation: UInt64)
    case prepareLanguagePack(sentenceID: String, pair: OfflineTranslationPair,
                             generation: UInt64)
}

enum LongTextActionRouter {
    static let maximumURLBytes = 256

    static func parse(_ url: URL, expectedGeneration: UInt64,
                      validSentenceIDs: Set<String>) -> LongTextNativeAction? {
        guard url.absoluteString.utf8.count <= maximumURLBytes,
              url.scheme == "localdictionary",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil,
              let host = url.host,
              ["translate-direction", "prepare-translation"].contains(host) else {
            return nil
        }
        let pathParts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathParts.count == 1 else { return nil }
        let sentenceID = String(pathParts[0])
        guard sentenceID.count <= 32, sentenceID.hasPrefix("sentence-"),
              sentenceID.dropFirst("sentence-".count).allSatisfy(\.isNumber),
              validSentenceIDs.contains(sentenceID),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 2 else { return nil }
        let grouped = Dictionary(grouping: items, by: \.name)
        guard grouped.count == 2,
              let targetValue = grouped["target"]?.singleValue,
              let generationValue = grouped["generation"]?.singleValue,
              let generation = UInt64(generationValue),
              generation == expectedGeneration else { return nil }
        let pair: OfflineTranslationPair
        switch targetValue {
        case OfflineTranslationLanguage.simplifiedChinese.rawValue:
            pair = OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        case OfflineTranslationLanguage.english.rawValue:
            pair = OfflineTranslationPair(source: .simplifiedChinese, target: .english)
        default:
            return nil
        }
        if host == "prepare-translation" {
            return .prepareLanguagePack(
                sentenceID: sentenceID, pair: pair, generation: generation
            )
        }
        return .translate(sentenceID: sentenceID, pair: pair, generation: generation)
    }
}

private extension Array where Element == URLQueryItem {
    var singleValue: String? {
        guard count == 1, let value = first?.value, !value.isEmpty else { return nil }
        return value
    }
}

final class LongTextResultFormatter {
    func format(
        _ result: LongTextAnalysisResult,
        aiBySentence: [String: NSAttributedString] = [:],
        queryGeneration: UInt64 = 0
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        heading("一、基础翻译", to: output)
        body(result.completeTranslation, size: 15, to: output)
        if result.requiresDirectionChoice {
            note("部分句子语言方向不确定；请选择方向后再翻译这些句子。", to: output)
        }

        heading("二、重点词汇（\(result.vocabulary.count)/15）", to: output)
        if result.vocabulary.isEmpty {
            note("没有足够可靠的重点词汇，不强行补足。", to: output)
        } else {
            for item in result.vocabulary {
                let professional = item.professional ? " · 专业词典建议" : ""
                body("• \(item.term) — \(item.meaningOrSuggestion)\n  来源：\(item.source)\(professional)",
                     size: 12.5, to: output)
            }
        }

        heading("三、逐句基础解析", to: output)
        for sentence in result.sentences {
            body("\(sentence.order + 1). \(sentence.sourceText)", size: 13.5,
                 weight: .semibold, to: output)
            body("基础翻译：\(translationLabel(for: sentence))", size: 12.5, to: output)
            directionControls(
                for: sentence, queryGeneration: queryGeneration, to: output
            )
            let analysis = sentence.basicAnalysis
            body("\(analysis.title)（置信度：\(analysis.confidence)）\n" +
                 "主语/话题：\(analysis.subjectOrTopic)\n" +
                 "主要谓语：\(analysis.predicate)\n" +
                 "宾语/补语：\(analysis.objectOrComplement)\n" +
                 analysis.structureHints.map { "• \($0)" }.joined(separator: "\n"),
                 size: 12, to: output)
            if let presentation = aiBySentence[sentence.id] {
                output.append(presentation)
            } else {
                aiLink(sentenceID: sentence.id, to: output)
            }
        }
        heading("四、AI 深度解析", to: output)
        note("可点击任一句的入口单独请求，或使用下方按钮逐句批量请求。只有明确点击后才会调用第三方 Provider。",
             to: output)
        return output
    }

    private func heading(_ value: String, to output: NSMutableAttributedString) {
        if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
        body(value, size: 15, weight: .bold, to: output)
    }

    private func body(_ value: String, size: CGFloat,
                      weight: NSFont.Weight = .regular,
                      to output: NSMutableAttributedString) {
        output.append(NSAttributedString(
            string: value + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                         .foregroundColor: NSColor.labelColor]
        ))
    }

    private func note(_ value: String, to output: NSMutableAttributedString) {
        output.append(NSAttributedString(
            string: value + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11.5),
                         .foregroundColor: NSColor.secondaryLabelColor]
        ))
    }

    private func aiLink(sentenceID: String, to output: NSMutableAttributedString) {
        guard let url = URL(string: "localdictionary://ai-sentence/\(sentenceID)") else {
            return
        }
        output.append(NSAttributedString(
            string: "AI 深度分析（本句）\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: url
            ]
        ))
    }

    private func translationLabel(for sentence: LongTextSentence) -> String {
        if let translated = sentence.translatedText { return translated }
        switch sentence.translationState {
        case .awaitingDirection: return "等待选择方向"
        case .translating: return "正在翻译…"
        case .languagePackRequired: return "需要准备 Apple 系统离线语言包"
        case .unsupported: return "系统不支持所选方向"
        case .failed: return "翻译失败，可重试或切换方向"
        case .cancelled: return "翻译已取消，可重试"
        case .notNeeded: return sentence.sourceText
        case .translated: return "暂不可用"
        }
    }

    private func directionControls(for sentence: LongTextSentence,
                                   queryGeneration: UInt64,
                                   to output: NSMutableAttributedString) {
        switch sentence.translationState {
        case .notNeeded:
            note("本句无需翻译。", to: output)
        case .translating(let pair):
            note("正在\(directionTitle(pair))…", to: output)
        case .languagePackRequired(let pair):
            actionLink(
                title: "准备\(directionTitle(pair))语言包",
                host: "prepare-translation",
                sentenceID: sentence.id,
                pair: pair,
                generation: queryGeneration,
                to: output
            )
            appendDirectionLinks(for: sentence.id, generation: queryGeneration, to: output)
        case .awaitingDirection:
            appendDirectionLinks(for: sentence.id, generation: queryGeneration, to: output)
        case .translated:
            if sentence.language == .mixed || sentence.language == .undetermined {
                appendDirectionLinks(
                    for: sentence.id, generation: queryGeneration, to: output
                )
            }
        case .unsupported, .failed, .cancelled:
            appendDirectionLinks(for: sentence.id, generation: queryGeneration, to: output)
        }
    }

    private func appendDirectionLinks(for sentenceID: String, generation: UInt64,
                                      to output: NSMutableAttributedString) {
        actionLink(
            title: "译为中文", host: "translate-direction", sentenceID: sentenceID,
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese),
            generation: generation, to: output
        )
        output.append(NSAttributedString(string: "  "))
        actionLink(
            title: "Translate to English / 译为英文",
            host: "translate-direction", sentenceID: sentenceID,
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english),
            generation: generation, to: output
        )
        output.append(NSAttributedString(string: "\n"))
    }

    private func actionLink(title: String, host: String, sentenceID: String,
                            pair: OfflineTranslationPair, generation: UInt64,
                            to output: NSMutableAttributedString) {
        var components = URLComponents()
        components.scheme = "localdictionary"
        components.host = host
        components.path = "/\(sentenceID)"
        components.queryItems = [
            URLQueryItem(name: "target", value: pair.target.rawValue),
            URLQueryItem(name: "generation", value: String(generation))
        ]
        guard let url = components.url else { return }
        output.append(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: url,
                .toolTip: title
            ]
        ))
    }

    private func directionTitle(_ pair: OfflineTranslationPair) -> String {
        pair.target == .simplifiedChinese ? "英译中" : "中译英"
    }
}
