import Foundation

struct AIServiceAvailability: Sendable {
    let isEnabled: Bool
    let isConfigured: Bool
    let automaticSentenceAnalysisEnabled: Bool
    let configuration: AIProviderConfiguration
    let configurations: [AIProviderConfiguration]
}

struct AIExplanationPresentation: Sendable {
    let explanation: AIExplanation
    let providerDisplayName: String
    let model: String
    let fromCache: Bool
    var providerID: UUID? = nil
}

struct AIProviderCompatibilityReport: Sendable {
    let providerDisplayName: String
    let model: String
    let responseCapability: AIProviderResponseCapability
    let wordParseMode: AIResponseParseMode
    let hasRecommendedEnglish: Bool
    let sentenceParseMode: AIResponseParseMode

    var summary: String {
        let recommendation = hasRecommendedEnglish ? "中文查词推荐英文：可用" : "中文查词推荐英文：未结构化返回"
        let capability: String
        switch responseCapability {
        case .supportsStructuredOutput: capability = "结构化输出"
        case .supportsJSONMode: capability = "JSON 模式"
        case .plainTextOnly: capability = "指令 + 容错解析"
        }
        return "传输/模型：可用；响应模式：\(capability)；" +
            "单词解析：\(wordParseMode.displayName)；\(recommendation)；" +
            "句子解析：\(sentenceParseMode.displayName)"
    }
}

struct AIProviderRequestFailure: LocalizedError {
    let providerID: UUID
    let providerDisplayName: String
    let model: String
    let underlying: Error

    var errorDescription: String? {
        "\(providerDisplayName) · \(model)：\(underlying.localizedDescription)"
    }
}

struct AIConfiguredProviderIdentity: Equatable, Sendable {
    let providerID: UUID
    let model: String
}

final class AIExplanationService: @unchecked Sendable {
    private let profileManager: AIProviderProfileManager
    private let cache: AIExplanationCache
    private let clientFactory: @Sendable () -> AIProviderClient

    init(configurationStore: AIConfigurationStore,
         keychain: AIKeychainStoring,
         cache: AIExplanationCache,
         profileManager: AIProviderProfileManager? = nil,
         clientFactory: @escaping @Sendable () -> AIProviderClient = {
             OpenAICompatibleClient()
         }) {
        self.profileManager = profileManager ?? AIProviderProfileManager(
            store: configurationStore, keychain: keychain
        )
        self.cache = cache
        self.clientFactory = clientFactory
    }

    func availability() async -> AIServiceAvailability {
        do {
            let snapshot = try await profileManager.snapshot()
            let configurations = snapshot.catalog.profiles.sorted { $0.priority < $1.priority }
            let enabled = configurations.filter(\.enabled)
            let configured = enabled.contains {
                snapshot.configuredProviderIDs.contains($0.providerID) &&
                    (try? $0.validate()) != nil
            }
            return AIServiceAvailability(
                isEnabled: !enabled.isEmpty,
                isConfigured: configured,
                automaticSentenceAnalysisEnabled: false,
                configuration: enabled.first ?? configurations.first ?? .googlePreset,
                configurations: configurations
            )
        } catch {
            return AIServiceAvailability(isEnabled: false,
                                         isConfigured: false,
                                         automaticSentenceAnalysisEnabled: false,
                                         configuration: .googlePreset,
                                         configurations: [])
        }
    }

    func configuredProviderIdentity() async -> AIConfiguredProviderIdentity? {
        guard let profile = await configuredProfile(providerID: nil) else { return nil }
        return AIConfiguredProviderIdentity(providerID: profile.providerID, model: profile.model)
    }

    func isConfiguredProvider(_ providerID: UUID, model: String) async -> Bool {
        guard let snapshot = try? await profileManager.snapshot() else { return false }
        return configuredCandidates(in: snapshot.catalog,
                                    configuredIDs: snapshot.configuredProviderIDs)
            .contains { $0.profile.providerID == providerID && $0.profile.model == model }
    }

    func explain(query: String, domain: String,
                 bypassCache: Bool = false) async throws -> AIExplanationPresentation {
        let snapshot = try await profileManager.snapshot()
        let catalog = snapshot.catalog
        let candidates = configuredCandidates(in: catalog,
                                              configuredIDs: snapshot.configuredProviderIDs)
        guard !candidates.isEmpty else { throw AIConfigurationError.missingAPIKey }

        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
                if !bypassCache,
                   let cached = try? await cache.value(for: query,
                                                       configuration: candidate.profile) {
                    return AIExplanationPresentation(explanation: cached.explanation,
                                                     providerDisplayName: cached.providerDisplayName,
                                                     model: cached.model,
                                                     fromCache: true,
                                                     providerID: candidate.profile.providerID)
                }
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await clientFactory().explain(
                    query: query,
                    domain: domain,
                    configuration: candidate.profile,
                    apiKey: key
                )
                try? await cache.store(result, query: query, configuration: candidate.profile)
                return AIExplanationPresentation(
                    explanation: result,
                    providerDisplayName: candidate.profile.providerDisplayName,
                    model: candidate.profile.model,
                    fromCache: false,
                    providerID: candidate.profile.providerID
                )
            } catch {
                let failure = AIProviderRequestFailure(
                    providerID: candidate.profile.providerID,
                    providerDisplayName: candidate.profile.providerDisplayName,
                    model: candidate.profile.model,
                    underlying: error
                )
                lastError = failure
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw failure }
            }
        }
        throw lastError
    }

    func analyzeSentence(_ sentence: String,
                         bypassCache: Bool = false,
                         diagnosticContext: AIProviderDiagnosticContext? = nil) async throws
        -> AISentenceAnalysisPresentation {
        let normalized = SentenceTextNormalizer.normalize(sentence)
        guard QueryIntentClassifier.classify(normalized).intent == .sentence else {
            throw AIClientError.invalidRequest()
        }
        let snapshot = try await profileManager.snapshot()
        let catalog = snapshot.catalog
        let candidates = configuredCandidates(in: catalog,
                                              configuredIDs: snapshot.configuredProviderIDs)
        guard !candidates.isEmpty else { throw AIConfigurationError.missingAPIKey }

        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
                if !bypassCache,
                   let cached = try? await cache.sentenceValue(
                    for: normalized, configuration: candidate.profile
                   ) {
                    return AISentenceAnalysisPresentation(
                        analysis: cached.analysis,
                        providerDisplayName: cached.providerDisplayName,
                        model: cached.model,
                        fromCache: true,
                        providerID: candidate.profile.providerID
                    )
                }
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await AIProviderDiagnosticScope.$current.withValue(
                    diagnosticContext
                ) {
                    try await clientFactory().analyzeSentence(
                        normalized,
                        configuration: candidate.profile,
                        apiKey: key
                    )
                }
                try? await cache.storeSentence(result,
                                               sentence: normalized,
                                               configuration: candidate.profile)
                return AISentenceAnalysisPresentation(
                    analysis: result,
                    providerDisplayName: candidate.profile.providerDisplayName,
                    model: candidate.profile.model,
                    fromCache: false,
                    providerID: candidate.profile.providerID
                )
            } catch {
                let failure = AIProviderRequestFailure(
                    providerID: candidate.profile.providerID,
                    providerDisplayName: candidate.profile.providerDisplayName,
                    model: candidate.profile.model,
                    underlying: error
                )
                lastError = failure
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw failure }
            }
        }
        throw lastError
    }

    func analyzeStudyText(_ studyText: StudyText,
                          languageContext: LanguageContext,
                          bypassCache: Bool = false,
                          diagnosticContext: AIProviderDiagnosticContext? = nil) async throws
        -> AISentenceAnalysisPresentation {
        guard studyText.language == languageContext.learningLanguage,
              languageContext.studyTextLanguage == languageContext.learningLanguage,
              TargetLanguageValidator.validate(
                studyText.text, targetLanguage: languageContext.learningLanguage
              ).isTargetLanguage else {
            throw AIClientError.studyTextUnavailable(expected: languageContext.learningLanguage)
        }
        ManualEvidenceRecorder.shared.record(
            "aiSentenceRoutingResolved", strings: [
                "aiAction": "sentenceAnalysis",
                "aiTranslationTargetLanguage": "notApplicable",
                "aiStudyLanguage": studyText.language.rawValue,
                "aiExplanationLanguage": languageContext.explanationLanguage.rawValue,
                "nativeLanguage": languageContext.nativeLanguage.rawValue,
                "learningLanguage": languageContext.learningLanguage.rawValue,
                "queryRelation": languageContext.queryRelation.rawValue,
                "dominantLanguage": languageContext.dominantLanguage?.rawValue ?? "undetermined"
            ]
        )
        return try await analyzeSentence(
            studyText.text, bypassCache: bypassCache,
            diagnosticContext: diagnosticContext
        )
    }

    func translateText(_ text: String,
                       bypassCache: Bool = false) async throws -> AITextTranslationPresentation {
        let context = LanguageContext.make(query: text)
        return try await translateText(
            text,
            targetLanguage: context.translationTargetLanguage ?? context.learningLanguage,
            languageContext: context,
            bypassCache: bypassCache
        )
    }

    func translateText(_ text: String,
                       targetLanguage: LanguageIdentifier,
                       languageContext: LanguageContext,
                       bypassCache: Bool = false) async throws -> AITextTranslationPresentation {
        let normalized = SentenceTextNormalizer.normalize(text)
        guard !normalized.isEmpty,
              normalized.count <= SentenceTextNormalizer.maximumCharacters,
              [languageContext.nativeLanguage,
               languageContext.learningLanguage].contains(targetLanguage) else {
            throw AIClientError.invalidRequest()
        }
        let identity = AITranslationCacheIdentity(
            context: languageContext, targetLanguage: targetLanguage
        )
        let snapshot = try await profileManager.snapshot()
        let catalog = snapshot.catalog
        let candidates = configuredCandidates(in: catalog,
                                               configuredIDs: snapshot.configuredProviderIDs)
        guard !candidates.isEmpty else { throw AIConfigurationError.missingAPIKey }

        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
                let cacheKey = AIExplanationCache.textTranslationCacheKey(
                    text: normalized, configuration: candidate.profile, identity: identity
                )
                let cacheIdentityHash = ManualEvidenceRecorder.identityHash(cacheKey)
                if !bypassCache,
                   let cached = try? await cache.textTranslationValue(
                    for: normalized, configuration: candidate.profile, identity: identity
                   ) {
                    var cacheHitAccepted = false
                    do {
                        try Self.validateTranslation(
                            cached.translation, sourceText: normalized,
                            targetLanguage: targetLanguage
                        )
                        cacheHitAccepted = true
                    } catch {
                        try? await cache.removeTextTranslation(
                            for: normalized, configuration: candidate.profile,
                            identity: identity
                        )
                        ManualEvidenceRecorder.shared.record(
                            "aiWrongTargetRejected", strings: [
                                "aiAction": "deepTranslation",
                                "queryHash": ManualEvidenceRecorder.identityHash(normalized),
                                "nativeLanguage": identity.nativeLanguage.rawValue,
                                "learningLanguage": identity.learningLanguage.rawValue,
                                "queryRelation": identity.queryRelation.rawValue,
                                "dominantLanguage": identity.dominantLanguage?.rawValue ?? "undetermined",
                                "aiTranslationTargetLanguage": targetLanguage.rawValue,
                                "aiCacheIdentityHash": cacheIdentityHash,
                                "aiResultValidation": String(describing: error)
                            ], booleans: ["aiCacheHit": true, "aiWrongTargetRejected": true]
                        )
                    }
                    if cacheHitAccepted {
                        ManualEvidenceRecorder.shared.record(
                            "aiCacheLookup", strings: [
                                "aiAction": "deepTranslation",
                                "queryHash": ManualEvidenceRecorder.identityHash(normalized),
                                "nativeLanguage": identity.nativeLanguage.rawValue,
                                "learningLanguage": identity.learningLanguage.rawValue,
                                "queryRelation": identity.queryRelation.rawValue,
                                "dominantLanguage": identity.dominantLanguage?.rawValue ??
                                    "undetermined",
                                "aiTranslationTargetLanguage": targetLanguage.rawValue,
                                "aiStudyLanguage": languageContext.studyTextLanguage.rawValue,
                                "aiExplanationLanguage": languageContext.explanationLanguage.rawValue,
                                "provider": candidate.profile.providerDisplayName,
                                "model": candidate.profile.model,
                                "aiCacheIdentityHash": cacheIdentityHash,
                                "promptVersion": String(identity.promptVersion),
                                "cacheSchemaVersion": String(identity.cacheSchemaVersion)
                            ], booleans: ["aiCacheHit": true]
                        )
                        return AITextTranslationPresentation(
                            result: cached.translation,
                            providerDisplayName: cached.providerDisplayName,
                            model: cached.model,
                            fromCache: true,
                            providerID: candidate.profile.providerID,
                            targetLanguage: targetLanguage,
                            cacheIdentityHash: cacheIdentityHash,
                            promptVersion: identity.promptVersion,
                            cacheSchemaVersion: identity.cacheSchemaVersion
                        )
                    }
                }
                ManualEvidenceRecorder.shared.record(
                    "aiCacheLookup", strings: [
                        "aiAction": "deepTranslation",
                        "queryHash": ManualEvidenceRecorder.identityHash(normalized),
                        "nativeLanguage": identity.nativeLanguage.rawValue,
                        "learningLanguage": identity.learningLanguage.rawValue,
                        "queryRelation": identity.queryRelation.rawValue,
                        "dominantLanguage": identity.dominantLanguage?.rawValue ?? "undetermined",
                        "aiTranslationTargetLanguage": targetLanguage.rawValue,
                        "aiStudyLanguage": languageContext.studyTextLanguage.rawValue,
                        "aiExplanationLanguage": languageContext.explanationLanguage.rawValue,
                        "aiCacheIdentityHash": cacheIdentityHash,
                        "promptVersion": String(identity.promptVersion),
                        "cacheSchemaVersion": String(identity.cacheSchemaVersion)
                    ], booleans: ["aiCacheHit": false]
                )
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await clientFactory().translateText(
                    normalized, targetLanguage: targetLanguage,
                    languageContext: languageContext,
                    configuration: candidate.profile, apiKey: key
                )
                try Self.validateTranslation(
                    result, sourceText: normalized, targetLanguage: targetLanguage
                )
                try? await cache.storeTextTranslation(result, text: normalized,
                                                      configuration: candidate.profile,
                                                      identity: identity)
                return AITextTranslationPresentation(
                    result: result,
                    providerDisplayName: candidate.profile.providerDisplayName,
                    model: candidate.profile.model,
                    fromCache: false,
                    providerID: candidate.profile.providerID,
                    targetLanguage: targetLanguage,
                    cacheIdentityHash: cacheIdentityHash,
                    promptVersion: identity.promptVersion,
                    cacheSchemaVersion: identity.cacheSchemaVersion
                )
            } catch {
                let failure = AIProviderRequestFailure(
                    providerID: candidate.profile.providerID,
                    providerDisplayName: candidate.profile.providerDisplayName,
                    model: candidate.profile.model,
                    underlying: error
                )
                lastError = failure
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw failure }
            }
        }
        throw lastError
    }

    private static func validateTranslation(
        _ translation: AITextTranslation,
        sourceText: String,
        targetLanguage: LanguageIdentifier
    ) throws {
        let validated = try translation.validated(expectedSourceText: sourceText)
        let source = canonicalTranslationText(sourceText)
        let result = canonicalTranslationText(validated.translation)
        let profile = LanguageTextProfile.make(sourceText)
        let meaningful = profile.hanCharacterCount >= 4 || profile.latinTokenCount >= 3
        if meaningful, !result.isEmpty, source == result {
            ManualEvidenceRecorder.shared.record(
                "aiWrongTargetRejected", strings: [
                    "aiAction": "deepTranslation",
                    "aiTranslationTargetLanguage": targetLanguage.rawValue,
                    "aiResultValidation": "noOpTranslation"
                ], booleans: ["aiWrongTargetRejected": true]
            )
            throw AIClientError.noOpTranslation
        }
        let language = TargetLanguageValidator.validate(
            validated.translation, targetLanguage: targetLanguage
        )
        ManualEvidenceRecorder.shared.record(
            "aiResultValidated", strings: [
                "aiAction": "deepTranslation",
                "aiTranslationTargetLanguage": targetLanguage.rawValue,
                "aiResultLanguage": language.resultLanguage?.rawValue ?? "undetermined",
                "aiResultValidation": language.isTargetLanguage ? "accepted" : "wrongTarget",
                "resultKind": language.isTargetLanguage ? "success" : "failure"
            ], booleans: ["aiWrongTargetRejected": !language.isTargetLanguage]
        )
        guard language.isTargetLanguage else {
            throw AIClientError.wrongTargetLanguage(
                expected: targetLanguage, actual: language.resultLanguage
            )
        }
    }

    private static func canonicalTranslationText(_ value: String) -> String {
        String(value.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || QueryIntentClassifier.isCJK($0)
        })
    }

    func inlineWordQuick(
        _ query: String, diagnosticContext: AIProviderDiagnosticContext? = nil
    ) async throws -> InlineWordQuickResult {
        let normalized = SentenceTextNormalizer.normalize(query)
        guard !normalized.isEmpty else { throw AIClientError.invalidRequest() }
        let (catalog, candidates) = try await inlineCandidates()
        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
                if let cached = try? await cache.inlineWordQuickValue(
                    for: normalized, configuration: candidate.profile
                ) {
                    OpenAICompatibleClient.recordMetrics(
                        configuration: candidate.profile, intent: .inlineWordQuick,
                        cacheHit: true, elapsedMilliseconds: 0, outputTokens: nil,
                        statusCode: nil, thinkingEnabled: false
                    )
                    return InlineWordQuickResult(partOfSpeech: cached.result.partOfSpeech,
                                                 definitions: cached.result.definitionsZH,
                                                 source: "AI",
                                                 providerDisplayName: cached.providerDisplayName,
                                                 model: cached.model,
                                                 fromCache: true,
                                                 learningEquivalent:
                                                    cached.result.learningEquivalent,
                                                 learningDefinition:
                                                    cached.result.learningDefinition,
                                                 nativeExplanation:
                                                    cached.result.nativeExplanation,
                                                 exampleLearning: cached.result.exampleLearning,
                                                 exampleNative: cached.result.exampleNative)
                }
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await AIProviderDiagnosticScope.$current.withValue(
                    diagnosticContext
                ) {
                    try await clientFactory().inlineWordQuick(
                        normalized, configuration: candidate.profile, apiKey: key
                    )
                }
                try? await cache.storeInlineWordQuick(result, query: normalized,
                                                      configuration: candidate.profile)
                return InlineWordQuickResult(partOfSpeech: result.partOfSpeech,
                                             definitions: result.definitionsZH,
                                             source: "AI",
                                             providerDisplayName: candidate.profile.providerDisplayName,
                                             model: candidate.profile.model,
                                             fromCache: false,
                                             learningEquivalent: result.learningEquivalent,
                                             learningDefinition: result.learningDefinition,
                                             nativeExplanation: result.nativeExplanation,
                                             exampleLearning: result.exampleLearning,
                                             exampleNative: result.exampleNative)
            } catch {
                lastError = error
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw error }
            }
        }
        throw lastError
    }

    func inlineSentenceQuick(
        _ sentence: String, diagnosticContext: AIProviderDiagnosticContext? = nil
    ) async throws -> InlineSentenceQuickResult {
        let normalized = SentenceTextNormalizer.normalize(sentence)
        guard QueryIntentClassifier.classify(normalized).intent == .sentence else {
            throw AIClientError.invalidRequest()
        }
        let (catalog, candidates) = try await inlineCandidates()
        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
                if let cached = try? await cache.inlineSentenceQuickValue(
                    for: normalized, configuration: candidate.profile
                ) {
                    OpenAICompatibleClient.recordMetrics(
                        configuration: candidate.profile, intent: .inlineSentenceQuick,
                        cacheHit: true, elapsedMilliseconds: 0, outputTokens: nil,
                        statusCode: nil, thinkingEnabled: false
                    )
                    return InlineSentenceQuickResult(
                        translation: cached.result.translation,
                        providerDisplayName: cached.providerDisplayName,
                        model: cached.model,
                        fromCache: true
                    )
                }
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await AIProviderDiagnosticScope.$current.withValue(
                    diagnosticContext
                ) {
                    try await clientFactory().inlineSentenceQuick(
                        normalized, configuration: candidate.profile, apiKey: key
                    )
                }
                try? await cache.storeInlineSentenceQuick(result, sentence: normalized,
                                                          configuration: candidate.profile)
                return InlineSentenceQuickResult(translation: result.translation,
                                                 providerDisplayName:
                                                    candidate.profile.providerDisplayName,
                                                 model: candidate.profile.model,
                                                 fromCache: false)
            } catch {
                lastError = error
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw error }
            }
        }
        throw lastError
    }

    func inlineWordExpansion(_ query: String) async throws -> AIExplanationPresentation {
        let normalized = SentenceTextNormalizer.normalize(query)
        guard !normalized.isEmpty else { throw AIClientError.invalidRequest() }
        let (catalog, candidates) = try await inlineCandidates()
        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
                if let cached = try? await cache.inlineWordExpansionValue(
                    for: normalized, configuration: candidate.profile
                ) {
                    OpenAICompatibleClient.recordMetrics(
                        configuration: candidate.profile, intent: .inlineWordExpansion,
                        cacheHit: true, elapsedMilliseconds: 0, outputTokens: nil,
                        statusCode: nil, thinkingEnabled: false
                    )
                    return AIExplanationPresentation(explanation: cached.explanation,
                                                     providerDisplayName: cached.providerDisplayName,
                                                     model: cached.model, fromCache: true,
                                                     providerID: candidate.profile.providerID)
                }
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await clientFactory().inlineWordExpansion(
                    normalized, configuration: candidate.profile, apiKey: key
                )
                try? await cache.storeInlineWordExpansion(result, query: normalized,
                                                          configuration: candidate.profile)
                return AIExplanationPresentation(explanation: result,
                                                 providerDisplayName:
                                                    candidate.profile.providerDisplayName,
                                                 model: candidate.profile.model, fromCache: false,
                                                 providerID: candidate.profile.providerID)
            } catch {
                lastError = error
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw error }
            }
        }
        throw lastError
    }

    func inlineSentenceExpansion(_ sentence: String) async throws
        -> AISentenceAnalysisPresentation {
        let normalized = SentenceTextNormalizer.normalize(sentence)
        guard QueryIntentClassifier.classify(normalized).intent == .sentence else {
            throw AIClientError.invalidRequest()
        }
        let (catalog, candidates) = try await inlineCandidates()
        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
                if let cached = try? await cache.inlineSentenceExpansionValue(
                    for: normalized, configuration: candidate.profile
                ) {
                    OpenAICompatibleClient.recordMetrics(
                        configuration: candidate.profile, intent: .inlineSentenceExpansion,
                        cacheHit: true, elapsedMilliseconds: 0, outputTokens: nil,
                        statusCode: nil, thinkingEnabled: false
                    )
                    return AISentenceAnalysisPresentation(
                        analysis: cached.analysis,
                        providerDisplayName: cached.providerDisplayName,
                        model: cached.model, fromCache: true,
                        providerID: candidate.profile.providerID
                    )
                }
                if let existing = try? await cache.sentenceValue(
                    for: normalized, configuration: candidate.profile
                ) {
                    return AISentenceAnalysisPresentation(
                        analysis: existing.analysis,
                        providerDisplayName: existing.providerDisplayName,
                        model: existing.model, fromCache: true,
                        providerID: candidate.profile.providerID
                    )
                }
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await clientFactory().inlineSentenceExpansion(
                    normalized, configuration: candidate.profile, apiKey: key
                )
                try? await cache.storeInlineSentenceExpansion(result, sentence: normalized,
                                                              configuration: candidate.profile)
                return AISentenceAnalysisPresentation(analysis: result,
                                                      providerDisplayName:
                                                        candidate.profile.providerDisplayName,
                                                      model: candidate.profile.model,
                                                      fromCache: false,
                                                      providerID: candidate.profile.providerID)
            } catch {
                lastError = error
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw error }
            }
        }
        throw lastError
    }

    func testConnection(configuration: AIProviderConfiguration,
                        replacementKey: String?) async throws {
        let normalized = try configuration.normalizedForSave()
        let key = try await resolvedKey(for: normalized, replacementKey: replacementKey)
        try await clientFactory().testConnection(configuration: normalized, apiKey: key)
    }

    func testSentenceFunction(configuration: AIProviderConfiguration,
                              replacementKey: String?) async throws {
        let normalized = try configuration.normalizedForSave()
        let key = try await resolvedKey(for: normalized, replacementKey: replacementKey)
        let testSentence = "Because it was raining, the match was postponed."
        _ = try await clientFactory().analyzeSentence(testSentence,
                                                      configuration: normalized,
                                                      apiKey: key)
    }

    func testCompatibility(configuration: AIProviderConfiguration,
                           replacementKey: String?) async throws
        -> AIProviderCompatibilityReport {
        let normalized = try configuration.normalizedForSave()
        let key = try await resolvedKey(for: normalized, replacementKey: replacementKey)
        let client = clientFactory()
        try await client.testConnection(configuration: normalized, apiKey: key)
        let word = try await client.explain(query: "下载", domain: "general",
                                            configuration: normalized, apiKey: key)
        let sentence = try await client.analyzeSentence(
            "Because it was raining, the match was postponed.",
            configuration: normalized, apiKey: key
        )
        return AIProviderCompatibilityReport(
            providerDisplayName: normalized.providerDisplayName,
            model: normalized.model,
            responseCapability: normalized.responseCapability,
            wordParseMode: word.responseParseMode,
            hasRecommendedEnglish: !word.recommendedEnglishExpressions.isEmpty,
            sentenceParseMode: sentence.responseParseMode
        )
    }

    func clearCache() async throws {
        try await cache.clear()
    }

    func hasCurrentCache(for query: String, intent: QueryIntent,
                         providerID: UUID? = nil,
                         studyTexts: [String] = []) async -> Bool {
        guard let profile = await configuredProfile(providerID: providerID) else { return false }
        switch intent {
        case .sentence:
            return (try? await cache.sentenceValue(for: query, configuration: profile)) != nil
        case .word, .phrase:
            return (try? await cache.value(for: query, configuration: profile)) != nil
        case .textTooLong:
            let context = LanguageContext.make(query: query)
            for target in Set([context.nativeLanguage, context.learningLanguage]) {
                let identity = AITranslationCacheIdentity(
                    context: context, targetLanguage: target
                )
                if (try? await cache.textTranslationValue(
                    for: query, configuration: profile, identity: identity
                )) != nil { return true }
            }
            for text in studyTexts where
                (try? await cache.sentenceValue(for: text, configuration: profile)) != nil {
                return true
            }
            return false
        }
    }

    func clearCurrentCache(for query: String, intent: QueryIntent,
                           providerID: UUID? = nil,
                           studyTexts: [String] = []) async throws {
        guard let profile = await configuredProfile(providerID: providerID) else {
            throw AIConfigurationError.missingAPIKey
        }
        switch intent {
        case .sentence:
            try await cache.removeSentenceAnalysis(for: query, configuration: profile)
        case .word, .phrase:
            try await cache.removeExplanation(for: query, configuration: profile)
        case .textTooLong:
            let context = LanguageContext.make(query: query)
            for target in Set([context.nativeLanguage, context.learningLanguage]) {
                try await cache.removeTextTranslation(
                    for: query, configuration: profile,
                    identity: AITranslationCacheIdentity(
                        context: context, targetLanguage: target
                    )
                )
            }
            for text in Set(studyTexts.map(SentenceTextNormalizer.normalize))
                where !text.isEmpty {
                try await cache.removeSentenceAnalysis(for: text, configuration: profile)
            }
        }
    }

    private func configuredProfile(providerID: UUID?) async -> AIProviderConfiguration? {
        guard let snapshot = try? await profileManager.snapshot() else { return nil }
        let profiles = configuredCandidates(in: snapshot.catalog,
                                            configuredIDs: snapshot.configuredProviderIDs)
            .map(\.profile)
        if let providerID { return profiles.first { $0.providerID == providerID } }
        return profiles.first
    }

    private struct Candidate {
        let profile: AIProviderConfiguration
    }

    private func inlineCandidates() async throws -> (AIProviderCatalog, [Candidate]) {
        let snapshot = try await profileManager.snapshot()
        let candidates = configuredCandidates(in: snapshot.catalog,
                                              configuredIDs: snapshot.configuredProviderIDs)
        guard !candidates.isEmpty else { throw AIConfigurationError.missingAPIKey }
        return (snapshot.catalog, candidates)
    }

    private func configuredCandidates(in catalog: AIProviderCatalog,
                                      configuredIDs: Set<UUID>) -> [Candidate] {
        catalog.profiles.sorted(by: { $0.priority < $1.priority }).compactMap { profile in
            guard profile.enabled,
                  configuredIDs.contains(profile.providerID),
                  (try? profile.validate()) != nil else { return nil }
            return Candidate(profile: profile)
        }
    }

    private func resolvedKey(for profile: AIProviderConfiguration,
                             replacementKey: String?) async throws -> String {
        let typed = replacementKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty { return typed }
        if let stored = try await profileManager.apiKey(for: profile) { return stored }
        throw AIConfigurationError.missingAPIKey
    }

    private static func shouldTryFallback(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is AIProviderCredentialError { return false }
        guard let error = error as? AIClientError else { return true }
        switch error {
        case .cancelled: return false
        case .offline, .timeout, .rateLimited, .insufficientQuota, .serverError,
             .invalidJSON, .schemaInvalid, .invalidResponse, .modelNotFound,
             .invalidRequest, .unauthorized, .responseTooLarge, .emptyResponse,
             .providerEmptyResponse, .providerReasoningOnly,
             .normalizationDroppedVisibleContent, .malformedProviderEnvelope, .refused,
             .studyTextUnavailable:
            return true
        case .noOpTranslation, .wrongTargetLanguage:
            return false
        }
    }
}
