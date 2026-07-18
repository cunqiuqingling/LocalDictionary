import Foundation

enum ResourceManifestQueryLevel: String, Equatable, Sendable {
    case fallback
}

enum ResourceDistributionMode: String, Equatable, Sendable {
    case mirroredDownload
    case officialPageOnly
}

enum ResourceArchiveFormat: String, Equatable, Sendable {
    case none
}

enum ResourceDictionaryFormat: String, Equatable, Sendable {
    case genericMDictV1 = "generic-mdict-v1"
}

enum ResourceManifestStatus: String, Equatable, Sendable {
    case active
    case deprecated
}

enum ResourceNoticeKind: String, Equatable, Sendable {
    case inline
}

struct ResourceManifestNotice: Equatable, Sendable {
    let kind: ResourceNoticeKind
    let text: String
}

struct ResourceManifestEntryCountRange: Equatable, Sendable {
    let minimum: UInt64
    let maximum: UInt64
}

struct ResourceManifestReviewEvidence: Equatable, Sendable {
    let kind: String
    let url: String
    let sha256: String
}

struct ResourceManifestResource: Equatable, Sendable {
    let resourceID: String
    let resourceRevision: UInt64
    let displayName: String
    let version: String
    let languages: [String]
    let description: String
    let category: String
    let queryLevel: ResourceManifestQueryLevel
    let distributionMode: ResourceDistributionMode
    let sourceProjectURL: String
    let officialDownloadPage: String
    let downloadURL: String?
    let allowedDownloadHosts: [String]?
    let fileName: String?
    let archiveFormat: ResourceArchiveFormat?
    let compressedSize: UInt64?
    let maximumDownloadedSize: UInt64?
    let maximumExpandedSize: UInt64?
    let sha256: String?
    let licenseName: String
    let licenseVersion: String
    let licenseURL: String
    let attribution: String
    let notice: ResourceManifestNotice
    let redistributionAllowed: Bool
    let mirroringAllowed: Bool
    let modificationAllowed: Bool
    let formatConversionAllowed: Bool
    let commercialUseAllowed: Bool
    let shareAlikeRequired: Bool
    let minimumAppVersion: String
    let dictionaryFormat: ResourceDictionaryFormat
    let expectedEntryCount: ResourceManifestEntryCountRange
    let status: ResourceManifestStatus
    let reviewedAt: String
    let reviewEvidence: [ResourceManifestReviewEvidence]
}

struct RevokedResourceRange: Equatable, Sendable {
    let resourceID: String
    let minimumRevision: UInt64
    let maximumRevision: UInt64
    let reasonCode: String
    let effectiveAt: String
}

struct ResourceManifestV1: Equatable, Sendable {
    let schemaVersion: UInt64
    let manifestVersion: UInt64
    let issuedAt: String
    let expiresAt: String
    let keyID: String
    let minimumAppVersion: String
    let resources: [ResourceManifestResource]
    let revokedResources: [RevokedResourceRange]
}

struct ManifestAppVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let components: [UInt32]

    init(_ value: String) throws {
        let rawComponents = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(rawComponents.count) else {
            throw ManifestVerificationError.invalidSemanticValue(path: "$.minimumAppVersion")
        }
        var parsed: [UInt32] = []
        for raw in rawComponents {
            guard !raw.isEmpty,
                  raw.allSatisfy({ $0.isASCII && $0.isNumber }),
                  raw == "0" || raw.first != "0",
                  let number = UInt32(raw) else {
                throw ManifestVerificationError.invalidSemanticValue(
                    path: "$.minimumAppVersion"
                )
            }
            parsed.append(number)
        }
        while parsed.count > 1, parsed.last == 0 { parsed.removeLast() }
        components = parsed
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: ManifestAppVersion, rhs: ManifestAppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum ResourceManifestFreshness: Equatable, Sendable {
    case current
    case expired
}

struct ValidatedResourceManifest: Equatable, Sendable {
    let manifest: ResourceManifestV1
    let issuedAt: Date
    let expiresAt: Date
    let minimumAppVersion: ManifestAppVersion
    let freshness: ResourceManifestFreshness
}

struct VerifiedResourceManifest: Equatable, Sendable {
    let validated: ValidatedResourceManifest
    let manifestSHA256: String
    let verifiedKeyID: String
}

struct VerifiedManifestState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let highestManifestVersion: UInt64
    let manifestSHA256: String
    let verifiedKeyID: String
    let issuedAt: Date
    let verifiedAt: Date

    init(highestManifestVersion: UInt64,
         manifestSHA256: String,
         verifiedKeyID: String,
         issuedAt: Date,
         verifiedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.highestManifestVersion = highestManifestVersion
        self.manifestSHA256 = manifestSHA256
        self.verifiedKeyID = verifiedKeyID
        self.issuedAt = issuedAt
        self.verifiedAt = verifiedAt
    }

    func validated() throws -> VerifiedManifestState {
        guard schemaVersion == Self.currentSchemaVersion,
              highestManifestVersion > 0,
              ResourceManifestValidation.isLowercaseSHA256(manifestSHA256),
              ResourceManifestSignatureEnvelope.isValidKeyID(verifiedKeyID) else {
            throw VerifiedManifestStateStoreError.corruptState
        }
        return self
    }
}

struct PreparedManifestVerification: Equatable, Sendable {
    let verifiedManifest: VerifiedResourceManifest
    let stateCandidate: VerifiedManifestState
}

struct StrictJSONLimits: Equatable, Sendable {
    var maximumNestingDepth = 32
    var maximumArrayElements = 512
    var maximumObjectMembers = 128
    var maximumStringBytes = 16 * 1024
    var maximumTotalValues = 20_000
}

struct ManifestVerificationPolicy: Equatable, Sendable {
    var maximumManifestBytes = 1_048_576
    var maximumSignatureBytes = 4_096
    var maximumResources = 256
    var maximumRevocations = 512
    var maximumLanguagesPerResource = 16
    var maximumHostsPerResource = 16
    var maximumEvidenceItemsPerResource = 32
    var maximumDownloadedResourceBytes: UInt64 = 512 * 1024 * 1024
    var maximumExpandedResourceBytes: UInt64 = 1_024 * 1024 * 1024
    var allowedFutureClockSkew: TimeInterval = 300
    var currentAppVersion: ManifestAppVersion
    var jsonLimits = StrictJSONLimits()

    init(currentAppVersion: ManifestAppVersion) {
        self.currentAppVersion = currentAppVersion
    }
}

protocol ManifestClock: Sendable {
    func now() -> Date
}

struct SystemManifestClock: ManifestClock {
    func now() -> Date { Date() }
}

enum ManifestVerificationError: LocalizedError, Equatable, Sendable {
    case signatureEnvelopeTooLarge
    case invalidSignatureEnvelope
    case unknownSignatureVersion
    case unknownSignatureAlgorithm
    case invalidKeyID
    case unknownKeyID
    case invalidTrustedPublicKey
    case invalidSignature
    case manifestTooLarge
    case emptyManifest
    case utf8BOMNotAllowed
    case invalidUTF8
    case malformedJSON(path: String)
    case duplicateJSONKey(path: String)
    case unknownJSONField(path: String)
    case missingJSONField(path: String)
    case invalidJSONType(path: String)
    case JSONLimitExceeded(path: String)
    case unsupportedSchemaVersion
    case invalidSemanticValue(path: String)
    case duplicateResourceID
    case duplicateRevocation
    case activeResourceRevoked
    case manifestIssuedInFuture
    case incompatibleAppVersion
    case manifestRollback
    case manifestVersionContentChanged
    case manifestVersionKeyChanged

    var errorDescription: String? {
        switch self {
        case .signatureEnvelopeTooLarge: return "资源签名文件超过允许大小。"
        case .invalidSignatureEnvelope: return "资源签名文件格式无效。"
        case .unknownSignatureVersion: return "不支持该资源签名格式版本。"
        case .unknownSignatureAlgorithm: return "不支持该资源签名算法。"
        case .invalidKeyID: return "资源签名密钥标识无效。"
        case .unknownKeyID: return "资源清单使用了未受信任的签名密钥。"
        case .invalidTrustedPublicKey: return "内置资源清单公钥无效。"
        case .invalidSignature: return "资源清单签名验证失败。"
        case .manifestTooLarge: return "资源清单超过允许大小。"
        case .emptyManifest: return "资源清单为空。"
        case .utf8BOMNotAllowed: return "资源清单不得包含 UTF-8 BOM。"
        case .invalidUTF8: return "资源清单不是有效的 UTF-8。"
        case .malformedJSON(let path): return "资源清单 JSON 格式无效（\(path)）。"
        case .duplicateJSONKey(let path): return "资源清单包含重复字段（\(path)）。"
        case .unknownJSONField(let path): return "资源清单包含未知字段（\(path)）。"
        case .missingJSONField(let path): return "资源清单缺少必填字段（\(path)）。"
        case .invalidJSONType(let path): return "资源清单字段类型无效（\(path)）。"
        case .JSONLimitExceeded(let path): return "资源清单结构超过安全限制（\(path)）。"
        case .unsupportedSchemaVersion: return "不支持该资源清单版本。"
        case .invalidSemanticValue(let path): return "资源清单字段值无效（\(path)）。"
        case .duplicateResourceID: return "资源清单包含重复资源标识。"
        case .duplicateRevocation: return "资源清单包含重复或重叠的撤回范围。"
        case .activeResourceRevoked: return "资源清单同时启用并撤回同一资源版本。"
        case .manifestIssuedInFuture: return "资源清单签发时间异常。"
        case .incompatibleAppVersion: return "资源清单需要更高版本的 LocalDictionary。"
        case .manifestRollback: return "检测到资源清单版本回滚。"
        case .manifestVersionContentChanged: return "相同资源清单版本的内容发生变化。"
        case .manifestVersionKeyChanged: return "相同资源清单版本的签名密钥发生变化。"
        }
    }
}
