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
}

final class AIExplanationService {
    private let profileManager: AIProviderProfileManager
    private let cache: AIExplanationCache
    private let clientFactory: () -> AIProviderClient

    init(configurationStore: AIConfigurationStore,
         keychain: AIKeychainStoring,
         cache: AIExplanationCache,
         profileManager: AIProviderProfileManager? = nil,
         clientFactory: @escaping () -> AIProviderClient = { OpenAICompatibleClient() }) {
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
                automaticSentenceAnalysisEnabled:
                    snapshot.catalog.automaticSentenceAnalysisEnabled,
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

    func explain(query: String, domain: String) async throws -> AIExplanationPresentation {
        let snapshot = try await profileManager.snapshot()
        let catalog = snapshot.catalog
        let candidates = configuredCandidates(in: catalog,
                                              configuredIDs: snapshot.configuredProviderIDs)
        guard !candidates.isEmpty else { throw AIConfigurationError.missingAPIKey }

        for candidate in candidates {
            if let cached = try? await cache.value(for: query, configuration: candidate.profile) {
                return AIExplanationPresentation(explanation: cached.explanation,
                                                 providerDisplayName: cached.providerDisplayName,
                                                 model: cached.model,
                                                 fromCache: true)
            }
        }

        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
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
                    fromCache: false
                )
            } catch {
                lastError = error
                guard catalog.automaticFallbackEnabled,
                      index + 1 < candidates.count,
                      Self.shouldTryFallback(after: error) else { throw error }
            }
        }
        throw lastError
    }

    func analyzeSentence(_ sentence: String) async throws -> AISentenceAnalysisPresentation {
        let normalized = SentenceTextNormalizer.normalize(sentence)
        guard QueryIntentClassifier.classify(normalized).intent == .sentence else {
            throw AIClientError.invalidRequest()
        }
        let snapshot = try await profileManager.snapshot()
        let catalog = snapshot.catalog
        let candidates = configuredCandidates(in: catalog,
                                              configuredIDs: snapshot.configuredProviderIDs)
        guard !candidates.isEmpty else { throw AIConfigurationError.missingAPIKey }

        for candidate in candidates {
            if let cached = try? await cache.sentenceValue(for: normalized,
                                                           configuration: candidate.profile) {
                return AISentenceAnalysisPresentation(analysis: cached.analysis,
                                                      providerDisplayName: cached.providerDisplayName,
                                                      model: cached.model,
                                                      fromCache: true)
            }
        }

        var lastError: Error = AIConfigurationError.missingAPIKey
        for (index, candidate) in candidates.enumerated() {
            do {
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
                    fromCache: false
                )
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

    private struct Candidate {
        let profile: AIProviderConfiguration
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
