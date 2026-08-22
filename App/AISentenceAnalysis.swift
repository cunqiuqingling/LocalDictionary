import Foundation

let aiSentencePromptVersion = 6
let aiTextTranslationPromptVersion = 5

struct AITranslationCacheIdentity: Equatable, Hashable, Sendable {
    static let currentSchemaVersion = 6

    let nativeLanguage: LanguageIdentifier
    let learningLanguage: LanguageIdentifier
    let explanationLanguage: LanguageIdentifier
    let queryRelation: QueryLanguageRelation
    let dominantLanguage: LanguageIdentifier?
    let translationTargetLanguage: LanguageIdentifier
    let studyLanguage: LanguageIdentifier
    let promptVersion: Int
    let cacheSchemaVersion: Int

    init(context: LanguageContext, targetLanguage: LanguageIdentifier) {
        nativeLanguage = context.nativeLanguage
        learningLanguage = context.learningLanguage
        explanationLanguage = context.explanationLanguage
        queryRelation = context.queryRelation
        dominantLanguage = context.dominantLanguage
        translationTargetLanguage = targetLanguage
        studyLanguage = context.studyTextLanguage
        promptVersion = aiTextTranslationPromptVersion
        cacheSchemaVersion = Self.currentSchemaVersion
    }

    var cacheComponents: [String] {
        [
            nativeLanguage.rawValue,
            learningLanguage.rawValue,
            explanationLanguage.rawValue,
            queryRelation.rawValue,
            dominantLanguage?.rawValue ?? "undetermined",
            translationTargetLanguage.rawValue,
            studyLanguage.rawValue,
            String(promptVersion),
            String(cacheSchemaVersion)
        ]
    }
}

enum AIExplanationMode: String, Codable, Sendable {
    case word
    case sentence
}

struct AISentenceCoreStructure: Codable, Equatable, Sendable {
    var subject: String
    var predicate: String
    var objectOrComplement: String
    var structureSummaryZH: String

    enum CodingKeys: String, CodingKey {
        case subject
        case predicate
        case objectOrComplement = "object_or_complement"
        case structureSummaryZH = "structure_summary_zh"
    }

    init(subject: String = "", predicate: String = "", objectOrComplement: String = "",
         structureSummaryZH: String = "") {
        self.subject = subject
        self.predicate = predicate
        self.objectOrComplement = objectOrComplement
        self.structureSummaryZH = structureSummaryZH
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        subject = try values.decodeIfPresent(String.self, forKey: .subject) ?? ""
        predicate = try values.decodeIfPresent(String.self, forKey: .predicate) ?? ""
        objectOrComplement = try values.decodeIfPresent(String.self,
                                                        forKey: .objectOrComplement) ?? ""
        structureSummaryZH = try values.decodeIfPresent(String.self,
                                                        forKey: .structureSummaryZH) ?? ""
    }
}

struct AISentenceClause: Codable, Equatable, Sendable {
    var text: String
    var type: String
    var functionZH: String
    var translationZH: String

    enum CodingKeys: String, CodingKey {
        case text, type
        case functionZH = "function_zh"
        case translationZH = "translation_zh"
    }

    init(text: String, type: String, functionZH: String, translationZH: String) {
        self.text = text
        self.type = type
        self.functionZH = functionZH
        self.translationZH = translationZH
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
        functionZH = try values.decodeIfPresent(String.self, forKey: .functionZH) ?? ""
        translationZH = try values.decodeIfPresent(String.self, forKey: .translationZH) ?? ""
    }
}

struct AISentenceGrammarPoint: Codable, Equatable, Sendable {
    var fragment: String
    var grammarName: String
    var explanationZH: String
    var pattern: String

    enum CodingKeys: String, CodingKey {
        case fragment, pattern
        case grammarName = "grammar_name"
        case explanationZH = "explanation_zh"
    }

    init(fragment: String = "", grammarName: String = "", explanationZH: String = "",
         pattern: String = "") {
        self.fragment = fragment
        self.grammarName = grammarName
        self.explanationZH = explanationZH
        self.pattern = pattern
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fragment = try values.decodeIfPresent(String.self, forKey: .fragment) ?? ""
        grammarName = try values.decodeIfPresent(String.self, forKey: .grammarName) ?? ""
        explanationZH = try values.decodeIfPresent(String.self, forKey: .explanationZH) ?? ""
        pattern = try values.decodeIfPresent(String.self, forKey: .pattern) ?? ""
    }
}

struct AISentenceCollocation: Codable, Equatable, Sendable {
    var expression: String
    var meaningZH: String
    var pattern: String
    var exampleEN: String
    var exampleZH: String

    enum CodingKeys: String, CodingKey {
        case expression, pattern
        case meaningZH = "meaning_zh"
        case exampleEN = "example_en"
        case exampleZH = "example_zh"
    }

    init(expression: String = "", meaningZH: String = "", pattern: String = "",
         exampleEN: String = "", exampleZH: String = "") {
        self.expression = expression
        self.meaningZH = meaningZH
        self.pattern = pattern
        self.exampleEN = exampleEN
        self.exampleZH = exampleZH
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        expression = try values.decodeIfPresent(String.self, forKey: .expression) ?? ""
        meaningZH = try values.decodeIfPresent(String.self, forKey: .meaningZH) ?? ""
        pattern = try values.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        exampleEN = try values.decodeIfPresent(String.self, forKey: .exampleEN) ?? ""
        exampleZH = try values.decodeIfPresent(String.self, forKey: .exampleZH) ?? ""
    }
}

struct AISentenceDifficultExpression: Codable, Equatable, Sendable {
    var expression: String
    var meaningZH: String
    var usageZH: String

    enum CodingKeys: String, CodingKey {
        case expression
        case meaningZH = "meaning_zh"
        case usageZH = "usage_zh"
    }

    init(expression: String = "", meaningZH: String = "", usageZH: String = "") {
        self.expression = expression
        self.meaningZH = meaningZH
        self.usageZH = usageZH
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        expression = try values.decodeIfPresent(String.self, forKey: .expression) ?? ""
        meaningZH = try values.decodeIfPresent(String.self, forKey: .meaningZH) ?? ""
        usageZH = try values.decodeIfPresent(String.self, forKey: .usageZH) ?? ""
    }
}

struct AISentenceAnalysis: Codable, Equatable, Sendable {
    var mode: String
    var sourceText: String
    var translationZH: String
    var sentenceType: String
    var coreStructure: AISentenceCoreStructure
    var clauses: [AISentenceClause]
    var grammarPoints: [AISentenceGrammarPoint]
    var collocations: [AISentenceCollocation]
    var difficultExpressions: [AISentenceDifficultExpression]
    var paraphraseEN: String
    var learningNoteZH: String
    var rawFallbackText: String?
    var responseParseMode: AIResponseParseMode

    enum CodingKeys: String, CodingKey {
        case mode, clauses, collocations
        case sourceText = "source_text"
        case translationZH = "translation_zh"
        case sentenceType = "sentence_type"
        case coreStructure = "core_structure"
        case grammarPoints = "grammar_points"
        case difficultExpressions = "difficult_expressions"
        case paraphraseEN = "paraphrase_en"
        case learningNoteZH = "learning_note_zh"
        case rawFallbackText = "raw_fallback_text"
        case responseParseMode = "response_parse_mode"
    }

    init(mode: String = "sentence_analysis", sourceText: String, translationZH: String,
         sentenceType: String = "", coreStructure: AISentenceCoreStructure = .init(),
         clauses: [AISentenceClause] = [], grammarPoints: [AISentenceGrammarPoint] = [],
         collocations: [AISentenceCollocation] = [],
         difficultExpressions: [AISentenceDifficultExpression] = [],
         paraphraseEN: String = "", learningNoteZH: String = "",
         rawFallbackText: String? = nil,
         responseParseMode: AIResponseParseMode = .strictJSON) {
        self.mode = mode
        self.sourceText = sourceText
        self.translationZH = translationZH
        self.sentenceType = sentenceType
        self.coreStructure = coreStructure
        self.clauses = clauses
        self.grammarPoints = grammarPoints
        self.collocations = collocations
        self.difficultExpressions = difficultExpressions
        self.paraphraseEN = paraphraseEN
        self.learningNoteZH = learningNoteZH
        self.rawFallbackText = rawFallbackText
        self.responseParseMode = responseParseMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "sentence_analysis"
        sourceText = try values.decodeIfPresent(String.self, forKey: .sourceText) ?? ""
        translationZH = try values.decodeIfPresent(String.self, forKey: .translationZH) ?? ""
        sentenceType = try values.decodeIfPresent(String.self, forKey: .sentenceType) ?? ""
        coreStructure = try values.decodeIfPresent(
            AISentenceCoreStructure.self, forKey: .coreStructure
        ) ?? .init()
        clauses = try values.decodeIfPresent([AISentenceClause].self, forKey: .clauses) ?? []
        grammarPoints = try values.decodeIfPresent(
            [AISentenceGrammarPoint].self, forKey: .grammarPoints
        ) ?? []
        collocations = try values.decodeIfPresent(
            [AISentenceCollocation].self, forKey: .collocations
        ) ?? []
        difficultExpressions = try values.decodeIfPresent(
            [AISentenceDifficultExpression].self, forKey: .difficultExpressions
        ) ?? []
        paraphraseEN = try values.decodeIfPresent(String.self, forKey: .paraphraseEN) ?? ""
        learningNoteZH = try values.decodeIfPresent(String.self, forKey: .learningNoteZH) ?? ""
        rawFallbackText = try values.decodeIfPresent(String.self, forKey: .rawFallbackText)
        responseParseMode = try values.decodeIfPresent(
            AIResponseParseMode.self, forKey: .responseParseMode
        ) ?? .strictJSON
    }

    func validated(expectedSourceText: String) throws -> AISentenceAnalysis {
        let expected = SentenceTextNormalizer.normalize(expectedSourceText)
        guard mode == "sentence_analysis" else {
            throw AIClientError.schemaInvalid(field: "mode")
        }
        guard !expected.isEmpty,
              expected.count <= SentenceTextNormalizer.maximumCharacters else {
            throw AIClientError.invalidRequest()
        }
        let returnedSource = SentenceTextNormalizer.normalize(sourceText)
        guard returnedSource.isEmpty || returnedSource == expected else {
            throw AIClientError.schemaInvalid(field: "source_text")
        }
        let translation = sentenceClean(translationZH, limit: 1_200)
        let fallbackCandidate = rawFallbackText.map(AIProviderResponseTextSanitizer.clean) ?? ""
        let fallback = AIProviderResponseTextSanitizer.isReadable(fallbackCandidate)
            ? fallbackCandidate : ""
        guard !translation.isEmpty || !fallback.isEmpty else {
            throw AIClientError.schemaInvalid(field: "translation_zh")
        }

        let cleanCore = AISentenceCoreStructure(
            subject: sentenceClean(coreStructure.subject, limit: 300),
            predicate: sentenceClean(coreStructure.predicate, limit: 300),
            objectOrComplement: sentenceClean(coreStructure.objectOrComplement, limit: 400),
            structureSummaryZH: sentenceClean(coreStructure.structureSummaryZH, limit: 700)
        )
        let allowedClauseTypes: Set<String> = [
            "main", "subordinate", "relative", "participial", "other"
        ]
        let cleanClauses = clauses.prefix(12).compactMap { item -> AISentenceClause? in
            let text = sentenceClean(item.text, limit: 700)
            let function = sentenceClean(item.functionZH, limit: 500)
            let translation = sentenceClean(item.translationZH, limit: 700)
            guard !text.isEmpty, !function.isEmpty || !translation.isEmpty else { return nil }
            let type = item.type.lowercased()
            return AISentenceClause(text: text,
                                    type: allowedClauseTypes.contains(type) ? type : "other",
                                    functionZH: function,
                                    translationZH: translation)
        }
        let cleanGrammar = grammarPoints.prefix(12).compactMap { item -> AISentenceGrammarPoint? in
            let name = sentenceClean(item.grammarName, limit: 180)
            let explanation = sentenceClean(item.explanationZH, limit: 600)
            guard !name.isEmpty, !explanation.isEmpty else { return nil }
            return AISentenceGrammarPoint(
                fragment: sentenceClean(item.fragment, limit: 500),
                grammarName: name,
                explanationZH: explanation,
                pattern: sentenceClean(item.pattern, limit: 300)
            )
        }
        let cleanCollocations = collocations.prefix(10).compactMap { item -> AISentenceCollocation? in
            let expression = sentenceClean(item.expression, limit: 200)
            let meaning = sentenceClean(item.meaningZH, limit: 300)
            guard !expression.isEmpty, !meaning.isEmpty else { return nil }
            return AISentenceCollocation(
                expression: expression,
                meaningZH: meaning,
                pattern: sentenceClean(item.pattern, limit: 300),
                exampleEN: sentenceClean(item.exampleEN, limit: 500),
                exampleZH: sentenceClean(item.exampleZH, limit: 500)
            )
        }
        let cleanDifficult = difficultExpressions.prefix(10).compactMap {
            item -> AISentenceDifficultExpression? in
            let expression = sentenceClean(item.expression, limit: 200)
            let meaning = sentenceClean(item.meaningZH, limit: 300)
            guard !expression.isEmpty, !meaning.isEmpty else { return nil }
            return AISentenceDifficultExpression(
                expression: expression,
                meaningZH: meaning,
                usageZH: sentenceClean(item.usageZH, limit: 500)
            )
        }
        return AISentenceAnalysis(
            sourceText: expected,
            translationZH: translation,
            sentenceType: sentenceClean(sentenceType, limit: 160),
            coreStructure: cleanCore,
            clauses: cleanClauses,
            grammarPoints: cleanGrammar,
            collocations: cleanCollocations,
            difficultExpressions: cleanDifficult,
            paraphraseEN: sentenceClean(paraphraseEN, limit: 1_000),
            learningNoteZH: sentenceClean(learningNoteZH, limit: 800),
            rawFallbackText: fallback.isEmpty ? nil : fallback,
            responseParseMode: responseParseMode
        )
    }
}

struct AITextTranslation: Codable, Equatable, Sendable {
    var sourceText: String
    var translation: String
    var rawFallbackText: String?
    var responseParseMode: AIResponseParseMode

    enum CodingKeys: String, CodingKey {
        case sourceText = "source_text"
        case translation
        case translationZH = "translation_zh"
        case rawFallbackText = "raw_fallback_text"
        case responseParseMode = "response_parse_mode"
    }

    init(sourceText: String, translation: String, rawFallbackText: String? = nil,
         responseParseMode: AIResponseParseMode = .strictJSON) {
        self.sourceText = sourceText
        self.translation = translation
        self.rawFallbackText = rawFallbackText
        self.responseParseMode = responseParseMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceText = try values.decodeIfPresent(String.self, forKey: .sourceText) ?? ""
        let primary = try values.decodeIfPresent(String.self, forKey: .translation)
        let chinese = try values.decodeIfPresent(String.self, forKey: .translationZH)
        translation = primary ?? chinese ?? ""
        rawFallbackText = try values.decodeIfPresent(String.self, forKey: .rawFallbackText)
        responseParseMode = try values.decodeIfPresent(
            AIResponseParseMode.self, forKey: .responseParseMode
        ) ?? .strictJSON
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceText, forKey: .sourceText)
        try values.encode(translation, forKey: .translation)
        try values.encodeIfPresent(rawFallbackText, forKey: .rawFallbackText)
        try values.encode(responseParseMode, forKey: .responseParseMode)
    }

    func validated(expectedSourceText: String) throws -> AITextTranslation {
        let expected = SentenceTextNormalizer.normalize(expectedSourceText)
        guard !expected.isEmpty,
              expected.count <= SentenceTextNormalizer.maximumCharacters else {
            throw AIClientError.invalidRequest()
        }
        let returned = SentenceTextNormalizer.normalize(sourceText)
        guard returned.isEmpty || returned == expected else {
            throw AIClientError.schemaInvalid(field: "source_text")
        }
        let cleanTranslation = String(
            SentenceTextNormalizer.normalize(translation).prefix(16_000)
        )
        let fallbackCandidate = rawFallbackText.map(AIProviderResponseTextSanitizer.clean) ?? ""
        let fallback = AIProviderResponseTextSanitizer.isReadable(fallbackCandidate)
            ? fallbackCandidate : ""
        guard !cleanTranslation.isEmpty || !fallback.isEmpty else {
            throw AIClientError.schemaInvalid(field: "translation")
        }
        return AITextTranslation(
            sourceText: expected,
            translation: cleanTranslation,
            rawFallbackText: fallback.isEmpty ? nil : fallback,
            responseParseMode: responseParseMode
        )
    }
}

struct AITextTranslationPresentation: Sendable {
    let result: AITextTranslation
    let providerDisplayName: String
    let model: String
    let fromCache: Bool
    var providerID: UUID? = nil
    var targetLanguage: LanguageIdentifier? = nil
    var cacheIdentityHash: String? = nil
    var promptVersion: Int = aiTextTranslationPromptVersion
    var cacheSchemaVersion: Int = AITranslationCacheIdentity.currentSchemaVersion
}

struct AISentenceAnalysisPresentation: Sendable {
    let analysis: AISentenceAnalysis
    let providerDisplayName: String
    let model: String
    let fromCache: Bool
    var providerID: UUID? = nil
}

private func sentenceClean(_ value: String, limit: Int) -> String {
    String(SentenceTextNormalizer.normalize(value).prefix(limit))
}
