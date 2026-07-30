import Foundation

enum ResourceNetworkError: LocalizedError, Equatable, Sendable {
    case disabledConfiguration
    case invalidEndpoint
    case disallowedURL
    case disallowedHost
    case redirectRejected
    case tooManyRedirects
    case invalidResponse
    case unacceptableStatus(Int)
    case unsupportedContentEncoding
    case unsupportedContentType
    case responseTooLarge
    case cancelled
    case timedOut
    case transportFailure
    case operationInProgress
    case verificationFailure(ManifestVerificationError)

    var errorDescription: String? {
        switch self {
        case .disabledConfiguration:
            return "开放词典资源服务尚未配置。"
        case .invalidEndpoint:
            return "资源清单服务配置无效。"
        case .disallowedURL, .disallowedHost:
            return "资源清单地址未通过安全检查。"
        case .redirectRejected:
            return "资源清单服务返回了不安全的重定向。"
        case .tooManyRedirects:
            return "资源清单服务重定向次数过多。"
        case .invalidResponse:
            return "资源清单服务返回了无效响应。"
        case .unacceptableStatus(let status):
            return "资源清单服务返回了不支持的状态（HTTP \(status)）。"
        case .unsupportedContentEncoding:
            return "资源清单服务使用了不支持的内容编码。"
        case .unsupportedContentType:
            return "资源清单服务返回了不支持的内容类型。"
        case .responseTooLarge:
            return "资源清单响应超过允许大小。"
        case .cancelled:
            return "资源清单获取已取消。"
        case .timedOut:
            return "资源清单服务请求超时。"
        case .transportFailure:
            return "无法连接资源清单服务。"
        case .operationInProgress:
            return "已有资源清单刷新正在进行。"
        case .verificationFailure(let error):
            return error.errorDescription ?? "资源清单验证失败。"
        }
    }
}

struct ResourceNetworkPolicy: Equatable, Sendable {
    static let signatureHardLimit = 4_096

    let maximumSignatureBytes: Int
    let maximumManifestBytes: Int
    let maximumRedirects: Int
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval

    init(verificationPolicy: ManifestVerificationPolicy,
         maximumRedirects: Int = 5,
         requestTimeout: TimeInterval = 15,
         resourceTimeout: TimeInterval = 30) throws {
        let signatureLimit = min(
            verificationPolicy.maximumSignatureBytes,
            Self.signatureHardLimit
        )
        guard signatureLimit > 0,
              verificationPolicy.maximumManifestBytes > 0,
              maximumRedirects >= 0,
              requestTimeout > 0,
              resourceTimeout > 0 else {
            throw ResourceNetworkError.invalidEndpoint
        }
        maximumSignatureBytes = signatureLimit
        maximumManifestBytes = verificationPolicy.maximumManifestBytes
        self.maximumRedirects = maximumRedirects
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
}

struct ResourceManifestEndpoint: Equatable, Sendable {
    /// Compatibility constant for security tests. Product composition uses the single
    /// `ResourceCenterProductionConfiguration` injection point.
    static let productionDefault: ResourceManifestEndpoint? = nil

    let manifestURL: URL
    let signatureURL: URL
    let pinnedAllowedHosts: [String]

    init(manifestURL: String,
         signatureURL: String,
         pinnedAllowedHosts: [String]) throws {
        let urlPolicy = try ResourceNetworkURLPolicy(
            pinnedAllowedHosts: pinnedAllowedHosts
        )
        self.manifestURL = try urlPolicy.validateInitialURL(manifestURL)
        self.signatureURL = try urlPolicy.validateInitialURL(signatureURL)
        self.pinnedAllowedHosts = urlPolicy.pinnedAllowedHosts
    }
}

enum ResourceNetworkPayloadKind: Equatable, Sendable {
    case signature
    case manifest

    var acceptHeader: String {
        switch self {
        case .signature: return "application/octet-stream"
        case .manifest: return "application/json, application/octet-stream"
        }
    }

    func accepts(contentType: String?) -> Bool {
        guard let raw = contentType?.split(separator: ";", maxSplits: 1).first else {
            return false
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch self {
        case .signature:
            return normalized == "application/octet-stream"
        case .manifest:
            return normalized == "application/json" ||
                normalized == "application/octet-stream"
        }
    }
}

protocol ResourceManifestPreparing: Sendable {
    var manifestVerificationPolicy: ManifestVerificationPolicy { get }

    func prepareVerification(signatureBytes: Data,
                             manifestBytes: Data,
                             priorState: VerifiedManifestState?) throws
        -> PreparedManifestVerification
}

extension ResourceManifestVerifier: ResourceManifestPreparing {
    var manifestVerificationPolicy: ManifestVerificationPolicy { policy }
}
