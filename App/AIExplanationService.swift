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

struct AIProviderRequestFailure: LocalizedError {
    let providerID: UUID
    let providerDisplayName: String
    let model: String
    let underlying: Error

    var errorDescription: String? {
        "\(providerDisplayName) · \(model)：\(underlying.localizedDescription)"
    }
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
                         bypassCache: Bool = false) async throws -> AISentenceAnalysisPresentation {
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
                let result = try await clientFactory().analyzeSentence(
                    normalized,
                    configuration: candidate.profile,
                    apiKey: key
                )
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

    func inlineWordQuick(_ query: String) async throws -> InlineWordQuickResult {
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
                                                 fromCache: true)
                }
                guard let key = try await profileManager.apiKey(for: candidate.profile) else {
                    continue
                }
                let result = try await clientFactory().inlineWordQuick(
                    normalized, configuration: candidate.profile, apiKey: key
                )
                try? await cache.storeInlineWordQuick(result, query: normalized,
                                                      configuration: candidate.profile)
                return InlineWordQuickResult(partOfSpeech: result.partOfSpeech,
                                             definitions: result.definitionsZH,
                                             source: "AI",
                                             providerDisplayName: candidate.profile.providerDisplayName,
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

    func inlineSentenceQuick(_ sentence: String) async throws -> InlineSentenceQuickResult {
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
                let result = try await clientFactory().inlineSentenceQuick(
                    normalized, configuration: candidate.profile, apiKey: key
                )
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

    func clearCache() async throws {
        try await cache.clear()
    }

    func hasCurrentCache(for query: String, intent: QueryIntent,
                         providerID: UUID? = nil) async -> Bool {
        guard let profile = await configuredProfile(providerID: providerID) else { return false }
        switch intent {
        case .sentence:
            return (try? await cache.sentenceValue(for: query, configuration: profile)) != nil
        case .word, .phrase:
            return (try? await cache.value(for: query, configuration: profile)) != nil
        case .textTooLong:
            return false
        }
    }

    func clearCurrentCache(for query: String, intent: QueryIntent,
                           providerID: UUID? = nil) async throws {
        guard let profile = await configuredProfile(providerID: providerID) else {
            throw AIConfigurationError.missingAPIKey
        }
        switch intent {
        case .sentence:
            try await cache.removeSentenceAnalysis(for: query, configuration: profile)
        case .word, .phrase:
            try await cache.removeExplanation(for: query, configuration: profile)
        case .textTooLong:
            return
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
             .invalidRequest, .unauthorized, .responseTooLarge:
            return true
        }
    }
}
