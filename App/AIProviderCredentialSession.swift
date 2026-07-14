import Foundation

enum AIProviderCredentialError: LocalizedError, Equatable, Sendable {
    case unavailable(providerDisplayName: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let providerDisplayName):
            return "无法读取\(providerDisplayName)的 API 密钥，请在 AI 服务设置中重新授权。"
        }
    }
}

/// Keeps API keys only for the lifetime of the current application process.
/// Nothing in this actor is persisted or logged.
actor AIProviderCredentialSession {
    private struct InFlightRead {
        let token: UUID
        let task: Task<String?, Error>
    }

    private enum State {
        case available(String)
        case missing
        case unavailable
    }

    private let keychain: AIKeychainStoring
    private var states: [UUID: State] = [:]
    private var inFlightReads: [UUID: InFlightRead] = [:]

    init(keychain: AIKeychainStoring) {
        self.keychain = keychain
    }

    func apiKey(for profile: AIProviderConfiguration) async throws -> String? {
        try await apiKey(providerID: profile.providerID,
                         account: profile.keychainAccount,
                         providerDisplayName: profile.providerDisplayName)
    }

    func apiKey(providerID: UUID, account: String,
                providerDisplayName: String) async throws -> String? {
        if let state = states[providerID] {
            switch state {
            case .available(let key): return key
            case .missing: return nil
            case .unavailable:
                throw AIProviderCredentialError.unavailable(
                    providerDisplayName: providerDisplayName
                )
            }
        }

        if let existing = inFlightReads[providerID] {
            return try await resolve(existing.task,
                                     token: existing.token,
                                     providerID: providerID,
                                     providerDisplayName: providerDisplayName)
        }

        let keychain = self.keychain
        let task = Task<String?, Error> {
            try await keychain.readKey(account: account)
        }
        let token = UUID()
        inFlightReads[providerID] = InFlightRead(token: token, task: task)
        return try await resolve(task,
                                 token: token,
                                 providerID: providerID,
                                 providerDisplayName: providerDisplayName)
    }

    func remember(_ rawKey: String, for providerID: UUID) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlightReads.removeValue(forKey: providerID)?.task.cancel()
        states[providerID] = key.isEmpty ? .missing : .available(key)
    }

    func markMissing(_ providerID: UUID) {
        inFlightReads.removeValue(forKey: providerID)?.task.cancel()
        states[providerID] = .missing
    }

    func invalidate(_ providerID: UUID) {
        inFlightReads.removeValue(forKey: providerID)?.task.cancel()
        states.removeValue(forKey: providerID)
    }

    func retainOnly(_ providerIDs: Set<UUID>) {
        for id in Set(states.keys).subtracting(providerIDs) {
            states.removeValue(forKey: id)
        }
        for id in Set(inFlightReads.keys).subtracting(providerIDs) {
            inFlightReads.removeValue(forKey: id)?.task.cancel()
        }
    }

    private func resolve(_ task: Task<String?, Error>, token: UUID, providerID: UUID,
                         providerDisplayName: String) async throws -> String? {
        do {
            let key = try await task.value
            guard inFlightReads[providerID]?.token == token else {
                return try valueAfterInvalidatedRead(
                    providerID: providerID,
                    providerDisplayName: providerDisplayName
                )
            }
            inFlightReads.removeValue(forKey: providerID)
            if let key, !key.isEmpty {
                states[providerID] = .available(key)
                return key
            }
            states[providerID] = .missing
            return nil
        } catch {
            guard inFlightReads[providerID]?.token == token else {
                return try valueAfterInvalidatedRead(
                    providerID: providerID,
                    providerDisplayName: providerDisplayName
                )
            }
            inFlightReads.removeValue(forKey: providerID)
            states[providerID] = .unavailable
            throw AIProviderCredentialError.unavailable(
                providerDisplayName: providerDisplayName
            )
        }
    }

    private func valueAfterInvalidatedRead(providerID: UUID,
                                           providerDisplayName: String) throws -> String? {
        guard let state = states[providerID] else { throw CancellationError() }
        switch state {
        case .available(let key): return key
        case .missing: return nil
        case .unavailable:
            throw AIProviderCredentialError.unavailable(
                providerDisplayName: providerDisplayName
            )
        }
    }
}
