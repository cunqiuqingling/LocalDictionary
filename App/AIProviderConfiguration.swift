import Foundation

let aiDictionaryPromptVersion = 1

enum AIProviderType: String, Codable, CaseIterable, Sendable {
    case googleGemini = "google-gemini"
    case zhipu = "zhipu"
    case openAICompatible = "openai-compatible"

    var title: String {
        switch self {
        case .googleGemini: return "Google Gemini"
        case .zhipu: return "智谱 AI"
        case .openAICompatible: return "自定义 OpenAI 兼容接口"
        }
    }

    var cacheIdentity: String {
        // Gemini used the generic OpenAI-compatible type before profiles existed.
        // Keep that identity so valid pre-migration cache entries remain readable.
        self == .googleGemini ? AIProviderType.openAICompatible.rawValue : rawValue
    }
}

struct AIProviderOptions: Codable, Equatable, Sendable {
    var usesJSONResponseFormat: Bool
    var requiresUserReview: Bool

    init(usesJSONResponseFormat: Bool = true, requiresUserReview: Bool = false) {
        self.usesJSONResponseFormat = usesJSONResponseFormat
        self.requiresUserReview = requiresUserReview
    }
}

struct AIProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    static let googleProviderID = UUID(uuidString: "3F5E7E8D-4C6C-4D1E-A67C-37191DF45E11")!
    static let zhipuProviderID = UUID(uuidString: "4A157C65-BCC2-4F64-A8D4-9324D8C35631")!

    var providerID: UUID
    var providerType: AIProviderType
    var providerDisplayName: String
    var baseURL: String
    var model: String
    var enabled: Bool
    var priority: Int
    var options: AIProviderOptions

    var id: UUID { providerID }

    init(providerID: UUID = UUID(),
         enabled: Bool,
         providerType: AIProviderType,
         providerDisplayName: String,
         baseURL: String,
         model: String,
         priority: Int = 1,
         options: AIProviderOptions = AIProviderOptions(),
         thinkingEnabled: Bool = false) {
        self.providerID = providerID
        self.enabled = enabled
        self.providerType = providerType
        self.providerDisplayName = providerDisplayName
        self.baseURL = baseURL
        self.model = model
        self.priority = priority
        self.options = options
        _ = thinkingEnabled // Legacy source compatibility; Zhipu thinking is always disabled.
    }

    static let googlePreset = AIProviderConfiguration(
        providerID: googleProviderID,
        enabled: true,
        providerType: .googleGemini,
        providerDisplayName: "Google Gemini",
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
        model: "gemini-3.1-flash-lite",
        priority: 1
    )

    static let zhipuPreset = AIProviderConfiguration(
        providerID: zhipuProviderID,
        enabled: false,
        providerType: .zhipu,
        providerDisplayName: "智谱 AI",
        baseURL: "https://open.bigmodel.cn/api/paas/v4",
        model: "glm-4.7-flash",
        priority: 2
    )

    var normalizedBaseURL: String {
        AIEndpoint.normalizedBaseURL(baseURL)
    }

    /// The stable UUID is the only account identifier used by the new profile store.
    var keychainAccount: String {
        providerID.uuidString.lowercased()
    }

    var thinkingEnabled: Bool {
        get { false }
        set { _ = newValue }
    }

    func validatedEndpointURL() throws -> URL {
        try AIEndpoint.chatCompletionsURL(baseURL)
    }

    func normalizedForSave() throws -> AIProviderConfiguration {
        var value = self
        value.providerDisplayName = AIConfigurationInput.cleanSingleLine(providerDisplayName)
        value.baseURL = AIEndpoint.normalizedBaseURL(baseURL)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        try value.validate()
        return value
    }

    func validate() throws {
        let displayName = providerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { throw AIConfigurationError.missingDisplayName }
        guard !providerDisplayName.contains(where: { $0.isNewline || $0 == "\t" }),
              displayName.count <= 48 else {
            throw AIConfigurationError.displayNameTooLong
        }
        guard baseURL.count <= 512,
              !baseURL.contains(where: { $0.isWhitespace }) else {
            throw AIConfigurationError.invalidBaseURL
        }
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else { throw AIConfigurationError.missingModel }
        guard cleanModel.count <= 128,
              cleanModel.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) != nil else {
            throw AIConfigurationError.invalidModel
        }
        if providerType == .zhipu,
           cleanModel.caseInsensitiveCompare("glm-4.7-flash") == .orderedSame,
           cleanModel != "glm-4.7-flash" {
            throw AIConfigurationError.invalidModel
        }
        _ = try validatedEndpointURL()
    }
}

struct AIProviderCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var profiles: [AIProviderConfiguration]
    var automaticFallbackEnabled: Bool
    var automaticSentenceAnalysisEnabled: Bool

    init(schemaVersion: Int = currentSchemaVersion,
         profiles: [AIProviderConfiguration],
         automaticFallbackEnabled: Bool = false,
         automaticSentenceAnalysisEnabled: Bool = false) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.automaticFallbackEnabled = automaticFallbackEnabled
        self.automaticSentenceAnalysisEnabled = automaticSentenceAnalysisEnabled
    }

    static let builtIn = AIProviderCatalog(
        profiles: [.googlePreset, .zhipuPreset]
    )

    func normalizedForSave() throws -> AIProviderCatalog {
        guard !profiles.isEmpty else { throw AIConfigurationError.emptyProviderList }
        var ids = Set<UUID>()
        var normalized: [AIProviderConfiguration] = []
        for profile in profiles {
            guard ids.insert(profile.providerID).inserted else {
                throw AIConfigurationError.duplicateProviderID
            }
            normalized.append(try profile.normalizedForSave())
        }
        normalized.sort {
            if $0.priority == $1.priority {
                return $0.providerDisplayName.localizedCaseInsensitiveCompare(
                    $1.providerDisplayName
                ) == .orderedAscending
            }
            return $0.priority < $1.priority
        }
        for index in normalized.indices { normalized[index].priority = index + 1 }
        return AIProviderCatalog(schemaVersion: Self.currentSchemaVersion,
                                 profiles: normalized,
                                 automaticFallbackEnabled: automaticFallbackEnabled,
                                 automaticSentenceAnalysisEnabled:
                                    automaticSentenceAnalysisEnabled)
    }
}

enum AIConfigurationInput {
    static func cleanSingleLine(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func safeDisplayName(_ rawValue: String) throws -> String {
        let cleaned = cleanSingleLine(rawValue)
        guard !cleaned.isEmpty else { throw AIConfigurationError.missingDisplayName }
        guard cleaned.count <= 48 else { throw AIConfigurationError.displayNameTooLong }
        return cleaned
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
        guard trimmed.count <= 512, !trimmed.contains(where: { $0.isWhitespace }) else {
            throw AIConfigurationError.invalidBaseURL
        }
        let endpointString: String
        if trimmed.lowercased().hasSuffix("/chat/completions") {
            endpointString = trimmed
        } else {
            endpointString = normalizedBaseURL(trimmed) + "/chat/completions"
        }
        guard let components = URLComponents(string: endpointString),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            throw AIConfigurationError.invalidBaseURL
        }
        return url
    }
}

enum AIConfigurationError: LocalizedError, Equatable {
    case missingDisplayName
    case displayNameTooLong
    case missingModel
    case invalidModel
    case invalidBaseURL
    case missingAPIKey
    case emptyProviderList
    case duplicateProviderID
    case persistenceFailed
    case migrationFailed

    var errorDescription: String? {
        switch self {
        case .missingDisplayName: return "请输入服务名称。"
        case .displayNameTooLong: return "服务名称过长。"
        case .missingModel: return "请输入模型名称。"
        case .invalidModel: return "模型名称包含不允许的字符或长度超过 128。"
        case .invalidBaseURL: return "Base URL 必须是有效的 HTTPS 地址。"
        case .missingAPIKey: return "尚未配置 API 密钥。"
        case .emptyProviderList: return "至少需要保留一个 AI 服务。"
        case .duplicateProviderID: return "AI 服务标识重复。"
        case .persistenceFailed: return "AI 服务设置未能安全保存，原配置已保留。"
        case .migrationFailed: return "旧 AI 服务设置尚未完成迁移，原配置仍保留。"
        }
    }
}

protocol AIConfigurationPersisting: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func string(forKey defaultName: String) -> String?
    func object(forKey defaultName: String) -> Any?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: AIConfigurationPersisting {}

struct AILegacyConfigurationMetadata: Sendable {
    let configuration: AIProviderConfiguration
    let automaticSentenceAnalysisEnabled: Bool
    let originalKeychainAccount: String
}

final class AIConfigurationStore {
    private enum Key {
        static let catalog = "LocalDictionary.AI.providerCatalog.v2"
        static let catalogBackup = "LocalDictionary.AI.providerCatalog.v2.backup"
        static let catalogStaging = "LocalDictionary.AI.providerCatalog.v2.staging"
        static let enabled = "LocalDictionary.AI.enabled"
        static let providerType = "LocalDictionary.AI.providerType"
        static let providerDisplayName = "LocalDictionary.AI.providerDisplayName"
        static let baseURL = "LocalDictionary.AI.baseURL"
        static let model = "LocalDictionary.AI.model"
        static let thinkingEnabled = "LocalDictionary.AI.thinkingEnabled"
        static let automaticSentenceAnalysis = "LocalDictionary.AI.automaticSentenceAnalysis"
    }

    private let defaults: AIConfigurationPersisting
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: AIConfigurationPersisting = UserDefaults.standard) {
        self.defaults = defaults
    }

    func loadCatalog() throws -> AIProviderCatalog? {
        if let data = defaults.data(forKey: Key.catalog),
           let catalog = try? decoder.decode(AIProviderCatalog.self, from: data),
           let loaded = try normalizedLoadedCatalog(catalog) {
            return loaded
        }
        if let data = defaults.data(forKey: Key.catalogBackup),
           let catalog = try? decoder.decode(AIProviderCatalog.self, from: data),
           let loaded = try normalizedLoadedCatalog(catalog) {
            return loaded
        }
        return nil
    }

    func saveCatalog(_ catalog: AIProviderCatalog) throws {
        let normalized = try catalog.normalizedForSave()
        let data = try encoder.encode(normalized)
        let previous = defaults.data(forKey: Key.catalog)

        defaults.set(data, forKey: Key.catalogStaging)
        guard defaults.data(forKey: Key.catalogStaging) == data else {
            throw AIConfigurationError.persistenceFailed
        }
        if let previous { defaults.set(previous, forKey: Key.catalogBackup) }
        defaults.set(data, forKey: Key.catalog)
        guard defaults.data(forKey: Key.catalog) == data,
              let verified = try? decoder.decode(AIProviderCatalog.self, from: data),
              verified == normalized else {
            if let previous { defaults.set(previous, forKey: Key.catalog) }
            else { defaults.removeObject(forKey: Key.catalog) }
            defaults.removeObject(forKey: Key.catalogStaging)
            throw AIConfigurationError.persistenceFailed
        }
        defaults.removeObject(forKey: Key.catalogStaging)
    }

    func legacyMetadata() -> AILegacyConfigurationMetadata? {
        let hasLegacy = defaults.object(forKey: Key.providerType) != nil ||
            defaults.object(forKey: Key.baseURL) != nil || defaults.object(forKey: Key.model) != nil
        guard hasLegacy else { return nil }
        let rawType = defaults.string(forKey: Key.providerType)
            .flatMap(AIProviderType.init(rawValue:)) ?? .openAICompatible
        let rawBaseURL = defaults.string(forKey: Key.baseURL) ?? ""
        let inferredType: AIProviderType
        if rawBaseURL.lowercased().contains("generativelanguage.googleapis.com") {
            inferredType = .googleGemini
        } else if rawBaseURL.lowercased().contains("open.bigmodel.cn") || rawType == .zhipu {
            inferredType = .zhipu
        } else {
            inferredType = rawType
        }
        let displayName = defaults.string(forKey: Key.providerDisplayName) ?? inferredType.title
        let model = defaults.string(forKey: Key.model) ?? "model-to-confirm"
        let legacy = AIProviderConfiguration(
            enabled: defaults.object(forKey: Key.enabled) == nil
                ? false : defaults.bool(forKey: Key.enabled),
            providerType: inferredType,
            providerDisplayName: String(AIConfigurationInput.cleanSingleLine(displayName).prefix(48)),
            baseURL: rawBaseURL,
            model: model,
            thinkingEnabled: defaults.bool(forKey: Key.thinkingEnabled)
        )
        let oldRawType = rawType == .googleGemini ? AIProviderType.openAICompatible : rawType
        let oldAccount = "\(oldRawType.rawValue)|\(AIEndpoint.normalizedBaseURL(rawBaseURL).lowercased())"
        return AILegacyConfigurationMetadata(
            configuration: legacy,
            automaticSentenceAnalysisEnabled: defaults.bool(forKey: Key.automaticSentenceAnalysis),
            originalKeychainAccount: oldAccount
        )
    }

    // Kept as a narrow source-compatibility layer for the existing smoke tests and cache tools.
    // Production settings use the versioned catalog APIs above.
    func load() -> AIProviderConfiguration {
        (try? loadCatalog()?.profiles.first) ?? legacyMetadata()?.configuration ?? .googlePreset
    }

    func save(_ configuration: AIProviderConfiguration) {
        let automatic = (try? loadCatalog()?.automaticSentenceAnalysisEnabled) ?? false
        try? saveCatalog(AIProviderCatalog(profiles: [configuration],
                                           automaticFallbackEnabled: false,
                                           automaticSentenceAnalysisEnabled: automatic))
    }

    func loadAutomaticSentenceAnalysisEnabled() -> Bool {
        (try? loadCatalog()?.automaticSentenceAnalysisEnabled) ??
            defaults.bool(forKey: Key.automaticSentenceAnalysis)
    }

    func saveAutomaticSentenceAnalysisEnabled(_ enabled: Bool) {
        if var catalog = try? loadCatalog() {
            catalog.automaticSentenceAnalysisEnabled = enabled
            try? saveCatalog(catalog)
        } else {
            defaults.set(enabled, forKey: Key.automaticSentenceAnalysis)
        }
    }

    private func normalizedLoadedCatalog(_ catalog: AIProviderCatalog) throws
        -> AIProviderCatalog? {
        if catalog.schemaVersion == AIProviderCatalog.currentSchemaVersion {
            return try catalog.normalizedForSave()
        }
        guard catalog.schemaVersion == 2 else { return nil }

        // One-time operational policy for the existing v2 provider catalog:
        // Google remains primary, Zhipu stays available but disabled, and automatic
        // fallback is opt-in. No profile or Keychain item is deleted.
        var profiles = catalog.profiles.sorted { $0.priority < $1.priority }
        if let googleIndex = profiles.firstIndex(where: {
            $0.providerID == AIProviderConfiguration.googleProviderID
        }) {
            var google = profiles.remove(at: googleIndex)
            google.enabled = true
            profiles.insert(google, at: 0)
        }
        if let zhipuIndex = profiles.firstIndex(where: {
            $0.providerID == AIProviderConfiguration.zhipuProviderID
        }) {
            profiles[zhipuIndex].enabled = false
        }
        for index in profiles.indices { profiles[index].priority = index + 1 }
        return try AIProviderCatalog(
            profiles: profiles,
            automaticFallbackEnabled: false,
            automaticSentenceAnalysisEnabled: catalog.automaticSentenceAnalysisEnabled
        ).normalizedForSave()
    }
}
