import Foundation

struct AIServiceAvailability: Sendable {
    let isEnabled: Bool
    let isConfigured: Bool
    let automaticSentenceAnalysisEnabled: Bool
    let configuration: AIProviderConfiguration
}

struct AIExplanationPresentation: Sendable {
    let explanation: AIExplanation
    let providerDisplayName: String
    let model: String
    let fromCache: Bool
}

final class AIExplanationService {
    private let configurationStore: AIConfigurationStore
    private let keychain: AIKeychainStoring
    private let cache: AIExplanationCache
    private let clientFactory: () -> AIProviderClient

    init(configurationStore: AIConfigurationStore,
         keychain: AIKeychainStoring,
         cache: AIExplanationCache,
         clientFactory: @escaping () -> AIProviderClient = { OpenAICompatibleClient() }) {
        self.configurationStore = configurationStore
        self.keychain = keychain
        self.cache = cache
        self.clientFactory = clientFactory
    }

    func availability() async -> AIServiceAvailability {
        let configuration = configurationStore.load()
        let valid = (try? configuration.validate()) != nil
        let hasKey: Bool
        do {
            hasKey = try await keychain.readKey(account: configuration.keychainAccount) != nil
        } catch {
            hasKey = false
        }
        return AIServiceAvailability(isEnabled: configuration.enabled,
                                     isConfigured: valid && hasKey,
                                     automaticSentenceAnalysisEnabled:
                                        configurationStore.loadAutomaticSentenceAnalysisEnabled(),
                                     configuration: configuration)
    }

    func explain(query: String, domain: String) async throws -> AIExplanationPresentation {
        let configuration = configurationStore.load()
        guard configuration.enabled else { throw AIConfigurationError.missingAPIKey }
        try configuration.validate()
        if let cached = try? await cache.value(for: query, configuration: configuration) {
            return AIExplanationPresentation(explanation: cached.explanation,
                                             providerDisplayName: cached.providerDisplayName,
                                             model: cached.model,
                                             fromCache: true)
        }
        guard let key = try await keychain.readKey(account: configuration.keychainAccount) else {
            throw AIConfigurationError.missingAPIKey
        }
        let result = try await clientFactory().explain(query: query,
                                                       domain: domain,
                                                       configuration: configuration,
                                                       apiKey: key)
        try? await cache.store(result, query: query, configuration: configuration)
        return AIExplanationPresentation(explanation: result,
                                         providerDisplayName: configuration.providerDisplayName,
                                         model: configuration.model,
                                         fromCache: false)
    }

    func analyzeSentence(_ sentence: String) async throws -> AISentenceAnalysisPresentation {
        let normalized = SentenceTextNormalizer.normalize(sentence)
        guard QueryIntentClassifier.classify(normalized).intent == .sentence else {
            throw AIClientError.invalidRequest
        }
        let configuration = configurationStore.load()
        guard configuration.enabled else { throw AIConfigurationError.missingAPIKey }
        try configuration.validate()
        if let cached = try? await cache.sentenceValue(for: normalized,
                                                       configuration: configuration) {
            return AISentenceAnalysisPresentation(analysis: cached.analysis,
                                                  providerDisplayName: cached.providerDisplayName,
                                                  model: cached.model,
                                                  fromCache: true)
        }
        guard let key = try await keychain.readKey(account: configuration.keychainAccount) else {
            throw AIConfigurationError.missingAPIKey
        }
        let result = try await clientFactory().analyzeSentence(normalized,
                                                               configuration: configuration,
                                                               apiKey: key)
        try? await cache.storeSentence(result, sentence: normalized, configuration: configuration)
        return AISentenceAnalysisPresentation(analysis: result,
                                              providerDisplayName: configuration.providerDisplayName,
                                              model: configuration.model,
                                              fromCache: false)
    }

    func testConnection(configuration: AIProviderConfiguration,
                        replacementKey: String?) async throws {
        try configuration.validate()
        let typed = replacementKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key: String
        if !typed.isEmpty {
            key = typed
        } else if let stored = try await keychain.readKey(account: configuration.keychainAccount) {
            key = stored
        } else {
            throw AIConfigurationError.missingAPIKey
        }
        try await clientFactory().testConnection(configuration: configuration, apiKey: key)
    }

    func clearCache() async throws {
        try await cache.clear()
    }
}
