import Foundation

let aiDictionaryPromptVersion = 1

enum AIProviderType: String, Codable, CaseIterable, Sendable {
    case zhipu = "zhipu"
    case openAICompatible = "openai-compatible"

    var title: String {
        switch self {
        case .zhipu: return "智谱 AI"
        case .openAICompatible: return "自定义 OpenAI 兼容接口"
        }
    }
}

struct AIProviderConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var providerType: AIProviderType
    var providerDisplayName: String
    var baseURL: String
    var model: String
    var thinkingEnabled: Bool

    static let zhipuPreset = AIProviderConfiguration(
        enabled: false,
        providerType: .zhipu,
        providerDisplayName: "智谱 AI",
        baseURL: "https://open.bigmodel.cn/api/paas/v4",
        model: "glm-4.7-flash",
        thinkingEnabled: false
    )

    var normalizedBaseURL: String {
        AIEndpoint.normalizedBaseURL(baseURL)
    }

    var keychainAccount: String {
        "\(providerType.rawValue)|\(normalizedBaseURL.lowercased())"
    }

    func validatedEndpointURL() throws -> URL {
        try AIEndpoint.chatCompletionsURL(baseURL)
    }

    func validate() throws {
        guard !providerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIConfigurationError.missingDisplayName
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIConfigurationError.missingModel
        }
        _ = try validatedEndpointURL()
    }
}

enum AIEndpoint {
    static func normalizedBaseURL(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        let suffix = "/chat/completions"
        if value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
            while value.hasSuffix("/") { value.removeLast() }
        }
        return value
    }

    static func chatCompletionsURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointString: String
        if trimmed.lowercased().hasSuffix("/chat/completions") {
            endpointString = trimmed
        } else {
            endpointString = normalizedBaseURL(trimmed) + "/chat/completions"
        }
        guard let components = URLComponents(string: endpointString),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              let url = components.url else {
            throw AIConfigurationError.invalidBaseURL
        }
        return url
    }
}

enum AIConfigurationError: LocalizedError, Equatable {
    case missingDisplayName
    case missingModel
    case invalidBaseURL
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingDisplayName: return "请输入服务名称。"
        case .missingModel: return "请输入模型名称。"
        case .invalidBaseURL: return "Base URL 必须是有效的 HTTPS 地址。"
        case .missingAPIKey: return "尚未配置 API 密钥。"
        }
    }
}

final class AIConfigurationStore {
    private enum Key {
        static let enabled = "LocalDictionary.AI.enabled"
        static let providerType = "LocalDictionary.AI.providerType"
        static let providerDisplayName = "LocalDictionary.AI.providerDisplayName"
        static let baseURL = "LocalDictionary.AI.baseURL"
        static let model = "LocalDictionary.AI.model"
        static let thinkingEnabled = "LocalDictionary.AI.thinkingEnabled"
        static let automaticSentenceAnalysis = "LocalDictionary.AI.automaticSentenceAnalysis"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AIProviderConfiguration {
        let preset = AIProviderConfiguration.zhipuPreset
        let type = defaults.string(forKey: Key.providerType)
            .flatMap(AIProviderType.init(rawValue:)) ?? preset.providerType
        return AIProviderConfiguration(
            enabled: defaults.object(forKey: Key.enabled) == nil
                ? preset.enabled : defaults.bool(forKey: Key.enabled),
            providerType: type,
            providerDisplayName: defaults.string(forKey: Key.providerDisplayName)
                ?? (type == .zhipu ? preset.providerDisplayName : type.title),
            baseURL: defaults.string(forKey: Key.baseURL) ?? preset.baseURL,
            model: defaults.string(forKey: Key.model) ?? preset.model,
            thinkingEnabled: defaults.object(forKey: Key.thinkingEnabled) == nil
                ? preset.thinkingEnabled : defaults.bool(forKey: Key.thinkingEnabled)
        )
    }

    func save(_ configuration: AIProviderConfiguration) {
        defaults.set(configuration.enabled, forKey: Key.enabled)
        defaults.set(configuration.providerType.rawValue, forKey: Key.providerType)
        defaults.set(configuration.providerDisplayName, forKey: Key.providerDisplayName)
        defaults.set(configuration.baseURL, forKey: Key.baseURL)
        defaults.set(configuration.model, forKey: Key.model)
        defaults.set(configuration.thinkingEnabled, forKey: Key.thinkingEnabled)
    }

    func loadAutomaticSentenceAnalysisEnabled() -> Bool {
        defaults.bool(forKey: Key.automaticSentenceAnalysis)
    }

    func saveAutomaticSentenceAnalysisEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.automaticSentenceAnalysis)
    }
}
