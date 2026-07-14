import Foundation
import Security

protocol AIKeychainStoring: AnyObject {
    func readKey(account: String) async throws -> String?
    func storeKey(_ key: String, account: String) async throws
    func deleteKey(account: String) async throws
}

enum AIKeychainError: LocalizedError {
    case operationFailed
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case .operationFailed: return "无法访问 macOS 钥匙串。"
        case .invalidStoredValue: return "钥匙串中的密钥格式无效。"
        }
    }
}

final class AIKeychainStore: AIKeychainStoring {
    static let productionService = "LocalDictionary.AIProvider"

    private let service: String
    private let queue = DispatchQueue(label: "LocalDictionary.AIKeychain", qos: .userInitiated)

    init(service: String = AIKeychainStore.productionService) {
        self.service = service
    }

    func readKey(account: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [service] in
                var query = Self.baseQuery(service: service, account: account)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound {
                    continuation.resume(returning: nil)
                    return
                }
                guard status == errSecSuccess, let data = result as? Data else {
                    continuation.resume(throwing: AIKeychainError.operationFailed)
                    return
                }
                guard let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                    continuation.resume(throwing: AIKeychainError.invalidStoredValue)
                    return
                }
                continuation.resume(returning: key)
            }
        }
    }

    func storeKey(_ key: String, account: String) async throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let data = clean.data(using: .utf8) else {
            throw AIConfigurationError.missingAPIKey
        }
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [service] in
                let query = Self.baseQuery(service: service, account: account)
                let attributes = [kSecValueData as String: data]
                let updateStatus = SecItemUpdate(query as CFDictionary,
                                                 attributes as CFDictionary)
                if updateStatus == errSecSuccess {
                    continuation.resume(returning: ())
                    return
                }
                guard updateStatus == errSecItemNotFound else {
                    continuation.resume(throwing: AIKeychainError.operationFailed)
                    return
                }
                var addition = query
                addition[kSecValueData as String] = data
                addition[kSecAttrAccessible as String] =
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let addStatus = SecItemAdd(addition as CFDictionary, nil)
                if addStatus == errSecSuccess {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: AIKeychainError.operationFailed)
                }
            }
        }
    }

    func deleteKey(account: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [service] in
                let status = SecItemDelete(
                    Self.baseQuery(service: service, account: account) as CFDictionary
                )
                if status == errSecSuccess || status == errSecItemNotFound {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: AIKeychainError.operationFailed)
                }
            }
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
