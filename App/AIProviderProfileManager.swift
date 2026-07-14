import Foundation

struct AIProviderCatalogSnapshot: Sendable {
    let catalog: AIProviderCatalog
    let configuredProviderIDs: Set<UUID>
}

actor AIProviderProfileManager {
    private let store: AIConfigurationStore
    private let keychain: AIKeychainStoring
    private let credentialSession: AIProviderCredentialSession

    init(store: AIConfigurationStore, keychain: AIKeychainStoring,
         credentialSession: AIProviderCredentialSession? = nil) {
        self.store = store
        self.keychain = keychain
        self.credentialSession = credentialSession ?? AIProviderCredentialSession(
            keychain: keychain
        )
    }

    func catalog() async throws -> AIProviderCatalog {
        if let existing = try store.loadCatalog() { return existing }
        return try await migrateLegacyConfiguration()
    }

    func snapshot() async throws -> AIProviderCatalogSnapshot {
        let catalog = try await catalog()
        let accounts = Set(try await keychain.listAccounts())
        let configured = Set(catalog.profiles.compactMap {
            accounts.contains($0.keychainAccount) ? $0.providerID : nil
        })
        return AIProviderCatalogSnapshot(catalog: catalog,
                                         configuredProviderIDs: configured)
    }

    func apiKey(for profile: AIProviderConfiguration) async throws -> String? {
        try await credentialSession.apiKey(for: profile)
    }

    func save(catalog proposedCatalog: AIProviderCatalog,
              replacementKeys: [UUID: String],
              deletingKeys: Set<UUID> = []) async throws -> AIProviderCatalogSnapshot {
        let normalized = try proposedCatalog.normalizedForSave()
        let oldCatalog = try await catalog()
        let oldIDs = Set(oldCatalog.profiles.map(\.providerID))
        let newIDs = Set(normalized.profiles.map(\.providerID))
        guard replacementKeys.keys.allSatisfy({ newIDs.contains($0) }),
              deletingKeys.allSatisfy({ oldIDs.contains($0) }),
              Set(replacementKeys.keys).isDisjoint(with: deletingKeys) else {
            throw AIConfigurationError.persistenceFailed
        }

        let affectedIDs = Set(replacementKeys.keys).union(deletingKeys)
        var oldKeys: [UUID: String?] = [:]
        for id in affectedIDs {
            let oldProfile = oldCatalog.profiles.first { $0.providerID == id }
            oldKeys[id] = try await credentialSession.apiKey(
                providerID: id,
                account: account(for: id),
                providerDisplayName: oldProfile?.providerDisplayName ?? "AI 服务"
            )
        }

        do {
            for (id, rawKey) in replacementKeys {
                let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                try await keychain.storeKey(key, account: account(for: id))
                await credentialSession.remember(key, for: id)
            }
            try store.saveCatalog(normalized)
            guard try store.loadCatalog() == normalized else {
                throw AIConfigurationError.persistenceFailed
            }
            for id in deletingKeys {
                try await keychain.deleteKey(account: account(for: id))
                await credentialSession.markMissing(id)
            }
            let enabledIDs = Set(normalized.profiles.filter(\.enabled).map(\.providerID))
            await credentialSession.retainOnly(enabledIDs)
            return try await snapshot()
        } catch {
            try? store.saveCatalog(oldCatalog)
            for id in affectedIDs {
                let old = oldKeys[id] ?? nil
                if let old {
                    try? await keychain.storeKey(old, account: account(for: id))
                    await credentialSession.remember(old, for: id)
                } else {
                    try? await keychain.deleteKey(account: account(for: id))
                    await credentialSession.markMissing(id)
                }
            }
            throw error
        }
    }

    private func migrateLegacyConfiguration() async throws -> AIProviderCatalog {
        let legacy = store.legacyMetadata()
        let accounts: [String]
        do {
            accounts = try await keychain.listAccounts()
        } catch {
            throw AIConfigurationError.migrationFailed
        }

        var google = AIProviderConfiguration.googlePreset
        var zhipu = AIProviderConfiguration.zhipuPreset
        google.enabled = accounts.contains(where: Self.isLegacyGoogleAccount)
        zhipu.enabled = accounts.contains(where: Self.isLegacyZhipuAccount)

        if let legacy {
            let source = legacy.configuration
            switch Self.classification(for: source) {
            case .googleGemini:
                google.enabled = source.enabled
                google.providerDisplayName = String(
                    AIConfigurationInput.cleanSingleLine(source.providerDisplayName).prefix(48)
                )
                google.baseURL = source.baseURL
                google.model = source.model
            case .zhipu:
                zhipu.enabled = source.enabled
                zhipu.providerDisplayName = String(
                    AIConfigurationInput.cleanSingleLine(source.providerDisplayName).prefix(48)
                )
                zhipu.baseURL = source.baseURL
                zhipu.model = source.model.caseInsensitiveCompare("glm-4.7-flash") == .orderedSame
                    ? "glm-4.7-flash" : source.model
            case .openAICompatible:
                break
            }
        }

        // Built-in values remain valid even if the legacy scalar data was malformed.
        if (try? google.validate()) == nil { google = .googlePreset }
        if (try? zhipu.validate()) == nil { zhipu = .zhipuPreset }
        google.enabled = true
        zhipu.enabled = false
        google.priority = 1
        zhipu.priority = 2

        var profiles = [google, zhipu]
        let knownAccounts = Set(accounts.filter {
            Self.isLegacyGoogleAccount($0) || Self.isLegacyZhipuAccount($0)
        })
        let unknownAccounts = accounts.filter { !knownAccounts.contains($0) && !Self.isUUID($0) }
        for (offset, oldAccount) in unknownAccounts.enumerated() {
            let recoveredURL = Self.urlSuffix(in: oldAccount) ?? "https://configure.invalid/v1"
            profiles.append(AIProviderConfiguration(
                enabled: false,
                providerType: .openAICompatible,
                providerDisplayName: unknownAccounts.count == 1
                    ? "待恢复的旧服务" : "待恢复的旧服务 \(offset + 1)",
                baseURL: recoveredURL,
                model: "model-to-confirm",
                priority: profiles.count + 1,
                options: AIProviderOptions(requiresUserReview: true)
            ))
        }

        let catalog = AIProviderCatalog(
            profiles: profiles,
            automaticFallbackEnabled: false,
            automaticSentenceAnalysisEnabled:
                legacy?.automaticSentenceAnalysisEnabled ?? false
        )
        let normalized = try catalog.normalizedForSave()
        var newlyWritten: [String] = []
        var availableAccounts = Set(accounts)
        do {
            for profile in normalized.profiles {
                guard !availableAccounts.contains(profile.keychainAccount) else { continue }
                let legacyAccount: String?
                switch profile.providerType {
                case .googleGemini:
                    legacyAccount = accounts.first(where: Self.isLegacyGoogleAccount)
                case .zhipu:
                    legacyAccount = accounts.first(where: Self.isLegacyZhipuAccount)
                case .openAICompatible:
                    legacyAccount = unknownAccounts.first(where: {
                        Self.urlSuffix(in: $0) == profile.baseURL
                    })
                }
                guard let legacyAccount,
                      let key = try await keychain.readKey(account: legacyAccount) else { continue }
                try await keychain.storeKey(key, account: profile.keychainAccount)
                guard Set(try await keychain.listAccounts()).contains(profile.keychainAccount) else {
                    throw AIConfigurationError.migrationFailed
                }
                availableAccounts.insert(profile.keychainAccount)
                if profile.enabled {
                    await credentialSession.remember(key, for: profile.providerID)
                }
                newlyWritten.append(profile.keychainAccount)
            }
            try store.saveCatalog(normalized)
            return normalized
        } catch {
            for account in newlyWritten { try? await keychain.deleteKey(account: account) }
            throw AIConfigurationError.migrationFailed
        }
    }

    private func account(for id: UUID) -> String { id.uuidString.lowercased() }

    private static func classification(for configuration: AIProviderConfiguration) -> AIProviderType {
        let url = configuration.normalizedBaseURL.lowercased()
        if url.contains("generativelanguage.googleapis.com") { return .googleGemini }
        if url.contains("open.bigmodel.cn") { return .zhipu }
        return configuration.providerType
    }

    private static func isLegacyGoogleAccount(_ account: String) -> Bool {
        account.lowercased().contains("generativelanguage.googleapis.com")
    }

    private static func isLegacyZhipuAccount(_ account: String) -> Bool {
        account.lowercased().contains("open.bigmodel.cn")
    }

    private static func isUUID(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    private static func urlSuffix(in account: String) -> String? {
        guard let separator = account.firstIndex(of: "|") else { return nil }
        let suffix = String(account[account.index(after: separator)...])
        return (try? AIEndpoint.chatCompletionsURL(suffix)) == nil
            ? nil : AIEndpoint.normalizedBaseURL(suffix)
    }
}
