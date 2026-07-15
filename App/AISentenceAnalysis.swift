import Foundation

let aiSentencePromptVersion = 1

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
    }

    init(mode: String = "sentence_analysis", sourceText: String, translationZH: String,
         sentenceType: String = "", coreStructure: AISentenceCoreStructure = .init(),
         clauses: [AISentenceClause] = [], grammarPoints: [AISentenceGrammarPoint] = [],
         collocations: [AISentenceCollocation] = [],
         difficultExpressions: [AISentenceDifficultExpression] = [],
         paraphraseEN: String = "", learningNoteZH: String = "") {
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
        guard SentenceTextNormalizer.normalize(sourceText) == expected else {
            throw AIClientError.schemaInvalid(field: "source_text")
        }
        let translation = sentenceClean(translationZH, limit: 1_200)
        guard !translation.isEmpty else {
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
            learningNoteZH: sentenceClean(learningNoteZH, limit: 800)
        )
    }
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
