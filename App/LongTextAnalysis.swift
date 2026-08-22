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

extension OfflineSentenceAnalysis {
    static let waitingForStudyText = OfflineSentenceAnalysis(
        title: "学习文本尚未生成",
        subjectOrTopic: "—", predicate: "—", objectOrComplement: "—",
        structureHints: ["生成 English 学习文本后可进行结构分析。"],
        expressions: [], confidence: "—"
    )
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
    var translationSource: OfflineTranslationSource? = nil
    var translationError: OfflineTranslationError?
    var translationState: LongTextSentenceTranslationState
    var basicAnalysis: OfflineSentenceAnalysis
    var studyText: StudyText? = nil
    var offlineVersions: [OfflineSentenceTranslationVersion] = []
}

struct OfflineSentenceTranslationVersion: Equatable, Sendable {
    let outputRole: OfflineTranslationOutputRole
    let pair: OfflineTranslationPair
    let isPrimary: Bool
    var translatedText: String?
    var translationSource: OfflineTranslationSource?
    var translationError: OfflineTranslationError?
    var state: LongTextSentenceTranslationState
}

enum LongTextAISentenceState: Equatable, Sendable {
    case idle
    case loading
    case success
    case partial
    case failed(String)
    case cancelled
}

struct LongTextAITranslationDisplay: Equatable, Sendable {
    let translation: String
    let providerDisplayName: String
    let model: String
    let fromCache: Bool
    let isPartial: Bool
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
        let roles = Set(sentences.flatMap(\.offlineVersions).map(\.outputRole))
        if roles.contains(.learningVersion), roles.contains(.nativeVersion) {
            let preferences = LanguagePreferencesStore.shared.load()
            return "\(preferences.learningLanguage.chineseName)\n" +
                renderedVersion(.learningVersion) + "\n\n" +
                "\(preferences.nativeLanguage.chineseName)\n" +
                renderedVersion(.nativeVersion)
        }
        return sentences.map { sentence in
            if let version = sentence.offlineVersions.first {
                return Self.rendered(version, sourceText: sentence.sourceText)
            }
            if sentence.translationSource == .appleSystem,
               let translated = sentence.translatedText,
               !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return translated
            }
            return Self.rendered(state: sentence.translationState,
                                 sourceText: sentence.sourceText)
        }.joined(separator: "\n")
    }

    var offlineDirectionSummary: String {
        let roles = Set(sentences.flatMap(\.offlineVersions).map(\.outputRole))
        if roles.contains(.learningVersion), roles.contains(.nativeVersion) {
            return "检测到中英混合文本，提供双语版本"
        }
        guard let pair = sentences.lazy.flatMap(\.offlineVersions).first?.pair else {
            return "翻译方向尚未确定"
        }
        return "翻译方向：\(pair.source.languageIdentifier.chineseName) → " +
            pair.target.languageIdentifier.chineseName
    }

    private func renderedVersion(_ role: OfflineTranslationOutputRole) -> String {
        sentences.map { sentence in
            guard let version = sentence.offlineVersions.first(where: {
                $0.outputRole == role
            }) else { return "Apple 系统离线翻译当前不可用。" }
            return Self.rendered(version, sourceText: sentence.sourceText)
        }.joined(separator: "\n")
    }

    private static func rendered(_ version: OfflineSentenceTranslationVersion,
                                 sourceText: String) -> String {
        if version.translationSource == .appleSystem ||
            version.translationSource == .sourceBilingualGlossary,
           let translated = version.translatedText,
           !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return translated
        }
        return rendered(state: version.state, sourceText: sourceText)
    }

    private static func rendered(state: LongTextSentenceTranslationState,
                                 sourceText: String) -> String {
        switch state {
        case .awaitingDirection: return "请选择本句的 Apple 翻译方向。"
        case .translating: return "Apple 系统离线翻译正在处理。"
        case .notNeeded: return sourceText
        case .languagePackRequired, .unsupported, .failed, .cancelled, .translated:
            return "Apple 系统离线翻译当前不可用。"
        }
    }

    var translationProviderLabel: String {
        let sources = Set(sentences.flatMap(\.offlineVersions).compactMap(\.translationSource))
        return sources.contains(.sourceBilingualGlossary)
            ? "Apple 系统离线翻译；混合词表中文侧采用原文已有词义"
            : "Apple 系统离线翻译"
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

extension LocalSentenceGlossaryService: TranslationGlossaryService {
    func evidence(for term: String, language: QueryLanguage) async
        -> TranslationGlossaryEvidence? {
        guard language == .english,
              let evidence = await translationEvidence(for: term) else { return nil }
        return TranslationGlossaryEvidence(
            suggestion: evidence.suggestion,
            source: evidence.source,
            professional: evidence.professional
        )
    }
}

enum LongTextSegmenter {
    static func segment(_ source: String) -> [LongTextSentence] {
        let normalized = SentenceTextNormalizer.normalize(source)
        guard !normalized.isEmpty else { return [] }
        let preferences = LanguagePreferencesStore.shared.load()
        let rootContext = LanguageContext.make(
            classification: QueryIntentClassifier.classify(normalized),
            preferences: preferences
        )
        let rootBidirectionalPlan: OfflineTranslationPlan? =
            rootContext.isMixed || rootContext.queryRelation == .unsupported
                ? OfflineTranslationPlan.make(context: rootContext) : nil
        var output: [LongTextSentence] = []
        for (paragraphIndex, paragraph) in normalized.components(separatedBy: "\n\n").enumerated() {
            var values: [String] = []
            if isBilingualGlossaryParagraph(paragraph) {
                values = [paragraph]
            } else {
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = paragraph
                tokenizer.enumerateTokens(
                    in: paragraph.startIndex..<paragraph.endIndex
                ) { range, _ in
                    let value = String(paragraph[range])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { values.append(value) }
                    return true
                }
            }
            if values.isEmpty { values = [paragraph] }
            for value in values {
                let language = sentenceLanguage(value)
                let context = LanguageContext.make(
                    classification: QueryIntentClassifier.classify(value),
                    preferences: preferences
                )
                let order = output.count
                let needsTranslation = containsTranslatableLanguage(value)
                let initialState: LongTextSentenceTranslationState
                let initialTranslation: String?
                let plan = rootBidirectionalPlan ?? OfflineTranslationPlan.make(context: context)
                let offlineVersions: [OfflineSentenceTranslationVersion]
                if !needsTranslation {
                    initialState = .notNeeded
                    initialTranslation = value
                    offlineVersions = []
                } else {
                    if let plan,
                       let primaryOperation = plan.operations.first(where: {
                           $0.outputRole == plan.primaryOutputRole
                       }) {
                        offlineVersions = plan.operations.map { operation in
                            return OfflineSentenceTranslationVersion(
                                outputRole: operation.outputRole, pair: operation.pair,
                                isPrimary: operation.outputRole == plan.primaryOutputRole,
                                translatedText: nil,
                                translationSource: nil, translationError: nil,
                                state: .translating(operation.pair)
                            )
                        }
                        initialState = .translating(primaryOperation.pair)
                        initialTranslation = nil
                    } else {
                        initialState = .awaitingDirection
                        offlineVersions = []
                        initialTranslation = nil
                    }
                }
                let studyText = context.isPureLearning
                    ? StudyText(text: value, language: preferences.learningLanguage,
                                origin: .originalQuery)
                    : nil
                let basicAnalysis = studyText.map {
                    BasicSentenceAnalyzer().analyze(
                        sentence: $0.text,
                        language: preferences.learningLanguage.queryLanguage
                    )
                } ?? .waitingForStudyText
                output.append(LongTextSentence(
                    id: String(format: "sentence-%04d", order + 1),
                    order: order,
                    paragraph: paragraphIndex,
                    sourceText: value,
                    language: language,
                    translatedText: initialTranslation,
                    translationSource: nil,
                    translationError: nil,
                    translationState: initialState,
                    basicAnalysis: basicAnalysis,
                    studyText: studyText,
                    offlineVersions: offlineVersions
                ))
            }
        }
        return output
    }

    /// NLP sentence tokenizers treat `a.`, `n.` and `vi.` as sentence endings. In copied bilingual
    /// glossary rows that would detach a headword/POS fragment from its Chinese gloss and make the
    /// Chinese side look like a failed Apple translation. Preserve only structurally clear,
    /// bounded glossary paragraphs as one translation unit.
    private static func isBilingualGlossaryParagraph(_ value: String) -> Bool {
        BilingualGlossaryDetector.isStructuredGlossary(value)
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

extension LanguageContext {
    var offlineTranslationPair: OfflineTranslationPair? {
        guard let plan = OfflineTranslationPlan.make(context: self) else { return nil }
        return plan.operations.first { $0.outputRole == plan.primaryOutputRole }?.pair
    }
}

/// Projects one canonical AI learning-language translation back onto the source sentence rows.
/// The translation remains the sole authority: no second provider request is made and Apple
/// output is never substituted. A one-row source deliberately keeps the complete translation,
/// even when the provider used several target-language sentences for natural wording.
enum AIStudyTextProjector {
    static func project(
        translation: String,
        onto sourceSentences: [LongTextSentence],
        learningLanguage: LanguageIdentifier
    ) -> [String: StudyText]? {
        let normalized = SentenceTextNormalizer.normalize(translation)
        guard !sourceSentences.isEmpty,
              TargetLanguageValidator.validate(
                normalized, targetLanguage: learningLanguage
              ).isTargetLanguage else { return nil }
        if sourceSentences.count == 1,
           let study = StudyText(
            text: normalized, language: learningLanguage, origin: .aiTranslation
           ) {
            return [sourceSentences[0].id: study]
        }

        let targetSegments = LongTextSegmenter.segment(normalized).map(\.sourceText).filter {
            TargetLanguageValidator.validate($0, targetLanguage: learningLanguage)
                .isTargetLanguage
        }
        guard targetSegments.count >= sourceSentences.count else { return nil }
        var projected: [String: StudyText] = [:]
        var targetIndex = 0
        var remainingSourceWeight = sourceSentences.reduce(0) {
            $0 + max(1, $1.sourceText.count)
        }
        for (index, source) in sourceSentences.enumerated() {
            let remainingSources = sourceSentences.count - index
            let remainingTargets = targetSegments.count - targetIndex
            let take: Int
            if remainingSources == 1 {
                take = remainingTargets
            } else {
                let proportional = Int((Double(remainingTargets) *
                    Double(max(1, source.sourceText.count)) /
                    Double(max(1, remainingSourceWeight))).rounded())
                take = min(max(1, proportional), remainingTargets - (remainingSources - 1))
            }
            let text = targetSegments[targetIndex..<(targetIndex + take)]
                .joined(separator: " ")
            guard let study = StudyText(
                text: text, language: learningLanguage, origin: .aiTranslation
            ) else { return nil }
            projected[source.id] = study
            targetIndex += take
            remainingSourceWeight -= max(1, source.sourceText.count)
        }
        return projected.count == sourceSentences.count ? projected : nil
    }
}

/// Keeps the two user-triggered AI views aligned without creating another cache or
/// provider request. Complete sentence-level natural translations can become the
/// current query's native-language translation and are then reused by deep translation.
enum CanonicalNativeAITranslation {
    static func compose(
        sourceSentences: [LongTextSentence],
        translationsBySentenceID: [String: String],
        nativeLanguage: LanguageIdentifier
    ) -> String? {
        guard !sourceSentences.isEmpty else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(sourceSentences.count)
        for sentence in sourceSentences {
            guard let value = translationsBySentenceID[sentence.id] else { return nil }
            let normalized = SentenceTextNormalizer.normalize(value)
            guard !normalized.isEmpty,
                  TargetLanguageValidator.validate(
                    normalized, targetLanguage: nativeLanguage
                  ).isTargetLanguage else { return nil }
            parts.append(normalized)
        }
        let joined = parts.joined(separator: "\n")
        return TargetLanguageValidator.validate(
            joined, targetLanguage: nativeLanguage
        ).isTargetLanguage ? joined : nil
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
        if let comma = sentence.firstIndex(of: ",") {
            let prefix = String(sentence[..<comma])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mainClause = String(sentence[sentence.index(after: comma)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixWords = prefix.split(whereSeparator: \.isWhitespace)
            if prefix.lowercased().hasPrefix("to "),
               (2...20).contains(prefixWords.count), !mainClause.isEmpty {
                let main = analyzeEnglish(mainClause)
                return OfflineSentenceAnalysis(
                    title: main.title,
                    subjectOrTopic: main.subjectOrTopic,
                    predicate: main.predicate,
                    objectOrComplement: main.objectOrComplement,
                    structureHints: Array((["句首 To… 为目的性不定式短语，不作为主句主语或谓语。"] +
                        main.structureHints).prefix(8)),
                    expressions: importantEnglishExpressions(sentence),
                    confidence: main.predicate == "可能未可靠识别" ? "低" : main.confidence
                )
            }
            if let first = prefixWords.first?.lowercased(), first.hasSuffix("ing"),
               (2...20).contains(prefixWords.count), !mainClause.isEmpty {
                let main = analyzeEnglish(mainClause)
                guard main.predicate.lowercased() != first else {
                    return OfflineSentenceAnalysis(
                        title: "基础结构识别", subjectOrTopic: "未能可靠识别",
                        predicate: "未能可靠识别主句谓语",
                        objectOrComplement: "未能可靠识别",
                        structureHints: ["句首 V-ing 片段可能是分词短语，不将其强行作为主句谓语。"],
                        expressions: importantEnglishExpressions(sentence), confidence: "低"
                    )
                }
                return OfflineSentenceAnalysis(
                    title: main.title,
                    subjectOrTopic: main.subjectOrTopic,
                    predicate: main.predicate,
                    objectOrComplement: main.objectOrComplement,
                    structureHints: Array(([
                        "句首 V-ing… 为分词短语/附加成分，不作为主句谓语。"
                    ] + main.structureHints).prefix(8)),
                    expressions: importantEnglishExpressions(sentence),
                    confidence: main.predicate == "可能未可靠识别" ? "低" : main.confidence
                )
            }
        }
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
    static let maximumCandidateLookups = 40

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
        var lookupCount = 0
        for candidate in candidates {
            guard lookupCount < Self.maximumCandidateLookups,
                  seen.insert(candidate.lemma).inserted else {
                continue
            }
            lookupCount += 1
            let language: QueryLanguage = candidate.term.unicodeScalars.contains {
                (0x3400...0x9FFF).contains($0.value)
            } ? .simplifiedChinese : .english
            if let properNoun = Self.contextualProperNoun(for: candidate.term) {
                output.append(OfflineVocabularyItem(
                    term: candidate.term,
                    lemma: candidate.lemma,
                    meaningOrSuggestion: properNoun,
                    source: "上下文专有名词识别",
                    score: candidate.score + 40,
                    professional: false
                ))
                continue
            }
            let evidence = await glossary.evidence(
                for: candidate.term,
                language: language
            )
            if let evidence {
                output.append(OfflineVocabularyItem(
                    term: candidate.term,
                    lemma: candidate.lemma,
                    meaningOrSuggestion: evidence.suggestion,
                    source: evidence.source,
                    score: candidate.score + 20 + (evidence.professional ? 12 : 0),
                    professional: evidence.professional
                ))
            } else if Self.isProfessionalKeyTerm(candidate.lemma) {
                output.append(OfflineVocabularyItem(
                    term: candidate.term,
                    lemma: candidate.lemma,
                    meaningOrSuggestion: "未在当前本地词典中找到释义",
                    source: "当前本地词典",
                    score: candidate.score,
                    professional: true
                ))
            }
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

    private static func isProfessionalKeyTerm(_ lemma: String) -> Bool {
        let lower = lemma.lowercased()
        return ["clinical", "pharmac", "renal", "antibiotic", "glacier", "inflation",
                "correlation", "causation", "confidence", "statistical", "algorithm",
                "hypothesis", "pathology", "cardio", "neuro", "immun", "genomic"]
            .contains(where: lower.contains)
    }

    private static func contextualProperNoun(for term: String) -> String? {
        guard term.first?.isUppercase == true else { return nil }
        switch term.lowercased() {
        case "brazil": return "巴西（国家；专有名词）"
        default: return nil
        }
    }

    private static let englishStopwords: Set<String> = [
        "this", "that", "these", "those", "with", "from", "into", "have", "has", "had",
        "were", "was", "are", "and", "but", "for", "the", "not", "you", "your", "they",
        "their", "which", "when", "where", "what", "would", "could", "should", "there",
        "because", "although", "every", "neither", "either", "both", "each", "any",
        "some", "all", "than", "then", "also", "only", "still", "just", "even",
        "completely", "really", "quite", "rather"
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
        var sentences = Self.initialResult(for: source).sentences
        guard !sentences.isEmpty else { throw OfflineTranslationError.emptyInput }
        try Task.checkCancellation()

        let translatable = sentences.flatMap { sentence in
            sentence.offlineVersions.compactMap {
                version -> OfflineTranslationRequest? in
                guard case .translating = version.state else { return nil }
                return OfflineTranslationRequest(
                    id: sentence.id + "#" + version.outputRole.rawValue,
                    sourceText: sentence.sourceText, pair: version.pair,
                    outputRole: version.outputRole
                )
            }
        }
        let groups = Dictionary(grouping: translatable, by: \.pair)
        var translatedByID: [String: OfflineTranslationResponse] = [:]
        var errorsByID: [String: OfflineTranslationError] = [:]
        for pair in groups.keys.sorted(by: { $0.source.rawValue < $1.source.rawValue }) {
            guard let requests = groups[pair] else { continue }
            try Task.checkCancellation()
            do {
                let responses = try await translation.translate(requests)
                for response in responses { translatedByID[response.id] = response }
            } catch let error as OfflineTranslationError {
                if requests.count > 1,
                   error == .systemFailure || error == .invalidResponse ||
                    error == .noOpTranslation || error == .wrongTargetLanguage {
                    // A bad/no-op segment must not discard the other valid rows in the same
                    // English or Chinese version. Retry each row once through the same bounded
                    // coordinator so successful rows remain visible and only the bad row keeps
                    // its typed terminal state. The opposite mixed direction is already isolated.
                    let retry = try await translateIndividually(requests)
                    translatedByID.merge(retry.responses) { _, latest in latest }
                    errorsByID.merge(retry.errors) { _, latest in latest }
                } else {
                    for request in requests { errorsByID[request.id] = error }
                }
            } catch is CancellationError {
                throw OfflineTranslationError.cancelled
            } catch {
                for request in requests { errorsByID[request.id] = .systemFailure }
            }
        }
        for index in sentences.indices {
            for versionIndex in sentences[index].offlineVersions.indices {
                let role = sentences[index].offlineVersions[versionIndex].outputRole
                let requestID = sentences[index].id + "#" + role.rawValue
                if let response = translatedByID[requestID] {
                    sentences[index].offlineVersions[versionIndex].translatedText =
                        response.translatedText
                    sentences[index].offlineVersions[versionIndex].translationSource =
                        response.source
                    sentences[index].offlineVersions[versionIndex].translationError = nil
                    sentences[index].offlineVersions[versionIndex].state = .translated(response.pair)
                    if role == .learningVersion, response.source == .appleSystem,
                       let study = StudyText(
                        text: response.translatedText,
                        language: LanguagePreferencesStore.shared.load().learningLanguage,
                        origin: .appleTranslation
                       ) {
                        sentences[index].studyText = study
                        sentences[index].basicAnalysis = BasicSentenceAnalyzer().analyze(
                            sentence: study.text, language: study.language.queryLanguage
                        )
                    }
                } else if let error = errorsByID[requestID] {
                    let pair = sentences[index].offlineVersions[versionIndex].pair
                    if role == .nativeVersion,
                       pair.target == .simplifiedChinese,
                       error == .noOpTranslation || error == .wrongTargetLanguage,
                       let projection = BilingualGlossaryDetector
                        .simplifiedChineseProjection(sentences[index].sourceText) {
                        sentences[index].offlineVersions[versionIndex].translatedText = projection
                        sentences[index].offlineVersions[versionIndex].translationSource =
                            .sourceBilingualGlossary
                        sentences[index].offlineVersions[versionIndex].translationError = nil
                        sentences[index].offlineVersions[versionIndex].state = .translated(pair)
                        ManualEvidenceRecorder.shared.record(
                            "mixedGlossaryNativeProjection",
                            strings: [
                                "offlineOutputRole": role.rawValue,
                                "translationTargetLanguage": pair.target.rawValue,
                                "appleTerminalReason": String(describing: error),
                                "resultKind": "safeSourceGlossProjection"
                            ],
                            integers: [
                                "sourceLength": Int64(sentences[index].sourceText.count),
                                "projectedLength": Int64(projection.count)
                            ]
                        )
                    } else {
                        sentences[index].offlineVersions[versionIndex].translationError = error
                        sentences[index].offlineVersions[versionIndex].state =
                            Self.state(for: error, pair: pair)
                    }
                }
                if sentences[index].offlineVersions[versionIndex].isPrimary {
                    let primary = sentences[index].offlineVersions[versionIndex]
                    sentences[index].translatedText = primary.translatedText
                    sentences[index].translationSource = primary.translationSource
                    sentences[index].translationError = primary.translationError
                    sentences[index].translationState = primary.state
                }
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

    private func translateIndividually(
        _ requests: [OfflineTranslationRequest]
    ) async throws -> (
        responses: [String: OfflineTranslationResponse],
        errors: [String: OfflineTranslationError]
    ) {
        typealias Outcome = (
            id: String,
            response: OfflineTranslationResponse?,
            error: OfflineTranslationError?
        )
        var responses: [String: OfflineTranslationResponse] = [:]
        var errors: [String: OfflineTranslationError] = [:]
        var next = 0
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            func enqueue(_ request: OfflineTranslationRequest) {
                group.addTask { [translation] in
                    do {
                        let values = try await translation.translate([request])
                        guard let response = values.first else {
                            return (request.id, nil, .invalidResponse)
                        }
                        return (request.id, response, nil)
                    } catch is CancellationError {
                        throw OfflineTranslationError.cancelled
                    } catch let error as OfflineTranslationError {
                        if error == .cancelled { throw error }
                        return (request.id, nil, error)
                    } catch {
                        return (request.id, nil, .systemFailure)
                    }
                }
            }
            while next < requests.count, next < 2 {
                enqueue(requests[next])
                next += 1
            }
            while let outcome = try await group.next() {
                if let response = outcome.response {
                    responses[outcome.id] = response
                } else {
                    errors[outcome.id] = outcome.error ?? .systemFailure
                }
                if next < requests.count {
                    enqueue(requests[next])
                    next += 1
                }
            }
        }
        return (responses, errors)
    }

    nonisolated static func initialResult(for source: String) -> LongTextAnalysisResult {
        let sentences = LongTextSegmenter.segment(source)
        return LongTextAnalysisResult(
            sourceText: SentenceTextNormalizer.normalize(source),
            sentences: sentences,
            vocabulary: [],
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
            id: source.id, sourceText: source.sourceText, pair: pair,
            outputRole: pair.target.languageIdentifier ==
                LanguagePreferencesStore.shared.load().learningLanguage
                ? .learningVersion : .nativeVersion
        )
        let responses = try await translation.translate([request])
        guard let response = responses.first else {
            throw OfflineTranslationError.invalidResponse
        }
        var sentence = source
        sentence.translatedText = response.translatedText
        sentence.translationSource = response.source
        sentence.translationError = nil
        sentence.translationState = .translated(pair)
        let role = response.outputRole ?? (pair.target.languageIdentifier ==
            LanguagePreferencesStore.shared.load().learningLanguage
            ? .learningVersion : .nativeVersion)
        let replacement = OfflineSentenceTranslationVersion(
            outputRole: role, pair: pair, isPrimary: true,
            translatedText: response.translatedText, translationSource: response.source,
            translationError: nil, state: .translated(pair)
        )
        if let index = sentence.offlineVersions.firstIndex(where: {
            $0.outputRole == role
        }) {
            sentence.offlineVersions[index] = replacement
        } else {
            sentence.offlineVersions.append(replacement)
        }
        if response.source == .appleSystem,
           pair.target.languageIdentifier ==
            LanguagePreferencesStore.shared.load().learningLanguage,
           let study = StudyText(
            text: response.translatedText,
            language: LanguagePreferencesStore.shared.load().learningLanguage,
            origin: .appleTranslation
           ) {
            sentence.studyText = study
            sentence.basicAnalysis = BasicSentenceAnalyzer().analyze(
                sentence: study.text, language: study.language.queryLanguage
            )
        }
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
        case .emptyInput, .hostUnavailable, .hostEnded, .invalidResponse, .noOpTranslation,
             .wrongTargetLanguage,
             .systemFailure,
             .preparationIncomplete, .deadlineExceeded:
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
        aiSentenceStates: [String: LongTextAISentenceState] = [:],
        deepTranslation: LongTextAITranslationDisplay? = nil,
        deepTranslationStatus: String? = nil,
        queryGeneration: UInt64 = 0
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        heading(t("一、离线基础翻译", "1. Offline Base Translation"), to: output)
        note(t("来源：", "Source: ") + result.translationProviderLabel, to: output)
        note(result.offlineDirectionSummary, to: output)
        body(result.completeTranslation, size: 15, to: output)
        if result.requiresDirectionChoice {
            note("部分句子语言方向不确定；请选择方向后再翻译这些句子。", to: output)
        }

        heading(t("二、重点词汇（\(result.vocabulary.count)/15）",
                  "2. Key Vocabulary (\(result.vocabulary.count)/15)"), to: output)
        if result.vocabulary.isEmpty {
            note("没有足够可靠的重点词汇，不强行补足。", to: output)
        } else {
            for item in result.vocabulary {
                let professional = item.professional ? " · 专业词典建议" : ""
                body("• \(item.term) — \(item.meaningOrSuggestion)\n  来源：\(item.source)\(professional)",
                     size: 12.5, to: output)
            }
        }

        heading(t("三、基础结构分析", "3. Basic Structure Analysis"), to: output)
        note(t("本节只分析 English 学习文本；不会把中文原文冒充学习对象。",
               "This section analyzes only English study text; the native-language source is never treated as the study object."),
             to: output)
        for sentence in result.sentences {
            body("\(sentence.order + 1). " + t("原文：", "Source: ") + sentence.sourceText,
                 size: 13.5,
                 weight: .semibold, to: output)
            if let study = sentence.studyText {
                body(t("学习文本：", "Study text: ") + study.text, size: 13.5,
                     weight: .medium, to: output)
            } else {
                note(t("生成 English 学习文本后可进行结构分析。",
                       "Generate English study text before running structure analysis."),
                     to: output)
            }
            let analysis = sentence.basicAnalysis
            body("\(analysis.title)（置信度：\(analysis.confidence)）\n" +
                 "主语/话题：\(analysis.subjectOrTopic)\n" +
                 "主要谓语：\(analysis.predicate)\n" +
                 "宾语/补语：\(analysis.objectOrComplement)\n" +
                 analysis.structureHints.map { "• \($0)" }.joined(separator: "\n"),
                 size: 12, to: output)
            directionControls(
                for: sentence, queryGeneration: queryGeneration, to: output
            )
        }

        heading(t("四、AI 深度翻译", "4. AI Deep Translation"),
                color: .systemPurple, to: output)
        if let deepTranslation {
            note("来源：\(deepTranslation.providerDisplayName) · \(deepTranslation.model)" +
                 (deepTranslation.fromCache ? " · 来自独立翻译缓存" : ""), to: output)
            body(deepTranslation.translation, size: 14.5, to: output)
        } else if let deepTranslationStatus, !deepTranslationStatus.isEmpty {
            note(deepTranslationStatus, to: output)
        } else {
            note("尚未请求。仅点击“AI 深度翻译”后才会把当前长文本发送给第三方 Provider。",
                 to: output)
        }

        heading(t("五、逐句 AI 深度分析", "5. Sentence-by-Sentence AI Analysis"),
                color: .systemPurple, to: output)
        note(t("学习对象：English · 解释语言：简体中文。每句拥有独立状态和缓存。",
               "Study language: English · Explanation language: Simplified Chinese. Each sentence has independent state and cache."),
             to: output)
        for sentence in result.sentences {
            body("\(sentence.order + 1). \(sentence.sourceText)", size: 13.5,
                 weight: .semibold, to: output)
            if let presentation = aiBySentence[sentence.id] {
                output.append(presentation)
            } else {
                switch aiSentenceStates[sentence.id] ?? .idle {
                case .loading:
                    note("AI 深度分析：正在请求…", to: output)
                case .failed(let reason):
                    note("AI 深度分析失败：\(reason)", to: output)
                    aiLink(sentenceID: sentence.id, title: "重试本句 AI 深度分析", to: output)
                case .cancelled:
                    note("AI 深度分析已取消。", to: output)
                    aiLink(sentenceID: sentence.id, title: "重新分析本句", to: output)
                case .idle, .success, .partial:
                    aiLink(sentenceID: sentence.id, title: "AI 深度分析（本句）", to: output)
                }
            }
        }
        return output
    }

    private func t(_ simplifiedChinese: String, _ english: String) -> String {
        LanguagePreferencesStore.shared.load().resolvedUILanguage == .english
            ? english : simplifiedChinese
    }

    private func heading(_ value: String, color: NSColor = .labelColor,
                         to output: NSMutableAttributedString) {
        if output.length > 0 {
            output.append(NSAttributedString(
                string: "\n", attributes: [.foregroundColor: NSColor.labelColor]
            ))
        }
        output.append(NSAttributedString(
            string: value + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold),
                         .foregroundColor: color]
        ))
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

    private func aiLink(sentenceID: String, title: String,
                        to output: NSMutableAttributedString) {
        guard let url = URL(string: "localdictionary://ai-sentence/\(sentenceID)") else {
            return
        }
        output.append(NSAttributedString(
            string: title + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: url
            ]
        ))
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
                title: "下载 Apple 离线翻译语言包（英语 ⇄ 中文）",
                host: "prepare-translation",
                sentenceID: sentence.id,
                pair: pair,
                generation: queryGeneration,
                to: output
            )
            note("由 macOS 管理；首次准备可能联网；不会调用 AI Provider，也不属于开放资源中心。",
                 to: output)
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
        output.append(NSAttributedString(
            string: "  ", attributes: [.foregroundColor: NSColor.labelColor]
        ))
        actionLink(
            title: "Translate to English / 译为英文",
            host: "translate-direction", sentenceID: sentenceID,
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english),
            generation: generation, to: output
        )
        output.append(NSAttributedString(
            string: "\n", attributes: [.foregroundColor: NSColor.labelColor]
        ))
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
