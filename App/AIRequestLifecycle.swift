import Foundation

/// A request token independent from the page/query generation. It prevents a
/// cancelled or late request from leaving or overwriting the visible loading
/// state when a retry for the same query has already started.
struct AIRequestLifecycle: Sendable {
    private(set) var activeToken: UUID?

    var isLoading: Bool { activeToken != nil }

    mutating func begin() -> UUID {
        let token = UUID()
        activeToken = token
        return token
    }

    mutating func finish(_ token: UUID) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }

    mutating func invalidate() {
        activeToken = nil
    }
}

enum AIRequestUserMessage {
    static func message(for error: Error) -> String {
        if let failure = error as? AIProviderRequestFailure {
            let detail = message(forUnderlying: failure.underlying)
            return "\(failure.providerDisplayName) · \(failure.model)：\(detail)"
        }
        return message(forUnderlying: error)
    }

    private static func message(forUnderlying error: Error) -> String {
        if let credential = error as? AIProviderCredentialError {
            return credential.localizedDescription
        }
        if let configuration = error as? AIConfigurationError {
            switch configuration {
            case .invalidBaseURL:
                return "服务地址无效，请在 AI 服务设置中检查 Base URL。"
            case .invalidModel, .missingModel:
                return "模型配置无效，请在 AI 服务设置中检查模型名称。"
            case .missingAPIKey:
                return "尚未配置 API 密钥，请打开 AI 服务设置。"
            default:
                return "AI 服务配置无效，请打开 AI 服务设置检查。"
            }
        }
        guard let client = error as? AIClientError else {
            return "AI 请求未能完成，请稍后重试或检查 AI 服务设置。"
        }
        switch client {
        case .invalidRequest:
            return "服务拒绝了请求参数，请检查服务地址和模型配置。"
        case .unauthorized:
            return "API 密钥无效或无权使用该模型，请在 AI 服务设置中检查。"
        case .rateLimited(let retryAfter):
            return retryAfter.map { "请求过于频繁，请在 \($0) 秒后重试。" }
                ?? "请求过于频繁，请稍后重试。"
        case .insufficientQuota:
            return "AI 服务额度不足或账户欠费，请检查服务商账户。"
        case .modelNotFound:
            return "模型不可用，请在 AI 服务设置中检查模型名称和访问权限。"
        case .timeout:
            return "请求超时，请检查当前网络后重试。"
        case .offline:
            return "当前网络无法连接 AI 服务，请检查网络后重试。"
        case .serverError:
            return "AI 服务暂时不可用，请稍后重试。"
        case .invalidJSON, .schemaInvalid, .invalidResponse:
            return "服务返回格式无法解析，请重试或更换 AI 服务。"
        case .responseTooLarge:
            return "服务返回内容过长，已停止处理；请缩短输入后重试。"
        case .cancelled:
            return "AI 查询已取消，可以重新查询。"
        }
    }
}
