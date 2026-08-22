import Foundation

enum ResourcePayloadDownloadError: LocalizedError, Equatable, Sendable {
    case disabledConfiguration
    case invalidVerifiedManifest
    case catalogEntryMissing
    case unsupportedDistributionMode
    case unsupportedArchiveFormat
    case disallowedHost
    case invalidFileName
    case invalidPathComponent
    case unsafePath
    case stagingDirectoryMissing
    case stagingLeaseExpired
    case temporaryFileMissing
    case downloadDestinationMissing
    case conflict
    case permissionDenied
    case crossDevicePublication
    case durabilityFailure
    case identityChanged
    case sidecarIdentityMismatch
    case unexpectedFileType
    case unexpectedPermissions
    case unexpectedLinkCount
    case ioFailure
    case invalidSignedSize
    case insufficientDiskSpace
    case invalidResponse
    case httpStatus(Int)
    case redirectRejected(String)
    case unsupportedContentType
    case unsupportedContentEncoding
    case payloadTooLarge
    case contentLengthMismatch
    case hashMismatch
    case stagingFailure
    case writeFailure
    case cancelled
    case timedOut
    case dnsFailure
    case tlsFailure
    case networkUnavailable
    case connectionLost
    case operationInProgress
    case transportFailure
    case archiveInvalid
    case converterFailed
    case publicationFailed

    var errorDescription: String? {
        switch self {
        case .disabledConfiguration:
            return "开放词典下载尚未配置。"
        case .invalidVerifiedManifest:
            return "已验证的资源清单不适用于该下载。"
        case .catalogEntryMissing:
            return "资源清单中没有该词典资源。"
        case .unsupportedDistributionMode:
            return "该资源不支持镜像下载。"
        case .unsupportedArchiveFormat:
            return "该资源不是受支持的单文件 MDX。"
        case .disallowedHost:
            return "资源下载地址未通过安全检查。"
        case .invalidFileName:
            return "资源文件名未通过安全检查。"
        case .invalidPathComponent:
            return "资源暂存路径组件无效。"
        case .unsafePath:
            return "资源暂存路径未通过安全检查。"
        case .stagingDirectoryMissing:
            return "资源暂存父目录不存在，下载尚未开始。"
        case .stagingLeaseExpired:
            return "资源暂存任务已经结束，请重新开始下载。"
        case .temporaryFileMissing:
            return "下载临时文件在校验前已不存在。"
        case .downloadDestinationMissing:
            return "无法建立下载目标文件。"
        case .conflict:
            return "资源暂存目标已存在。"
        case .permissionDenied:
            return "没有访问资源暂存目录的权限。"
        case .crossDevicePublication:
            return "资源暂存目录不支持安全发布。"
        case .durabilityFailure:
            return "资源暂存内容无法安全持久化。"
        case .identityChanged:
            return "资源暂存文件在校验期间发生变化。"
        case .sidecarIdentityMismatch:
            return "资源安装信息与已验证身份不一致。"
        case .unexpectedFileType:
            return "资源暂存对象类型无效。"
        case .unexpectedPermissions:
            return "资源暂存对象权限无效。"
        case .unexpectedLinkCount:
            return "资源暂存对象链接数无效。"
        case .ioFailure:
            return "资源暂存发生输入输出错误。"
        case .invalidSignedSize:
            return "资源清单中的文件大小无效。"
        case .insufficientDiskSpace:
            return "可用磁盘空间不足，未开始下载。"
        case .invalidResponse:
            return "资源服务器返回了无效响应。"
        case .httpStatus(let status):
            return "资源服务器返回了不支持的状态（HTTP \(status)）。"
        case .redirectRejected(let host):
            return "资源下载重定向被安全策略拒绝（\(host)）。"
        case .unsupportedContentType:
            return "资源服务器返回了不支持的文件类型。"
        case .unsupportedContentEncoding:
            return "资源服务器使用了不支持的内容编码。"
        case .payloadTooLarge:
            return "资源下载超过允许大小。"
        case .contentLengthMismatch:
            return "下载文件大小与已签名资源清单不一致。"
        case .hashMismatch:
            return "下载文件完整性校验失败。"
        case .stagingFailure:
            return "无法安全暂存下载文件。"
        case .writeFailure:
            return "写入下载文件失败。"
        case .cancelled:
            return "资源下载已取消。"
        case .timedOut:
            return "资源下载请求超时。"
        case .dnsFailure:
            return "无法解析资源服务器域名（DNS 失败）。"
        case .tlsFailure:
            return "与资源服务器建立 TLS 安全连接失败。"
        case .networkUnavailable:
            return "当前网络不可用。"
        case .connectionLost:
            return "下载过程中网络连接中断。"
        case .operationInProgress:
            return "已有开放词典下载正在进行。"
        case .transportFailure:
            return "无法连接资源下载服务。"
        case .archiveInvalid:
            return "下载已完成，但归档结构未通过安全验证。"
        case .converterFailed:
            return "下载已验证，但本机词典转换失败。"
        case .publicationFailed:
            return "词典已转换，但无法安全发布到本机目录。"
        }
    }
}

struct ResourcePayloadDownloadPolicy: Equatable, Sendable {
    static let absoluteHardLimit: UInt64 = 512 * 1024 * 1024
    static let defaultDiskSafetyMargin: UInt64 = 64 * 1024 * 1024

    /// Compatibility constant for security tests. Product composition uses the single
    /// `ResourceCenterProductionConfiguration` injection point.
    static let productionAllowedHosts: [String] = []

    let applicationAllowedHosts: [String]
    let applicationHardLimit: UInt64
    let diskSafetyMargin: UInt64
    let maximumRedirects: Int
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval

    init(applicationAllowedHosts: [String],
         applicationHardLimit: UInt64 = Self.absoluteHardLimit,
         diskSafetyMargin: UInt64 = Self.defaultDiskSafetyMargin,
         maximumRedirects: Int = 5,
         requestTimeout: TimeInterval = 30,
         resourceTimeout: TimeInterval = 1_800) throws {
        guard applicationHardLimit > 0,
              applicationHardLimit <= Self.absoluteHardLimit,
              maximumRedirects >= 0,
              requestTimeout > 0,
              resourceTimeout > 0 else {
            throw ResourcePayloadDownloadError.disabledConfiguration
        }
        self.applicationAllowedHosts = applicationAllowedHosts
        self.applicationHardLimit = applicationHardLimit
        self.diskSafetyMargin = diskSafetyMargin
        self.maximumRedirects = maximumRedirects
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
}

struct ResourcePayloadDownloadPlan: Equatable, Sendable {
    let resourceID: String
    let resourceRevision: UInt64
    let downloadURL: URL
    let signedFileName: String
    let expectedBytes: UInt64
    let maximumBytes: UInt64
    let expectedSHA256: String
    let allowedHosts: [String]
    let stagingRoot: URL
    let policy: ResourcePayloadDownloadPolicy
    /// Generated before the first staging write so payload and immutable receipt share one
    /// directory publication boundary.
    let installationIdentity: OpenResourceInstallationIdentity
}

enum ResourcePayloadDownloadPlanBuilder {
    static func build(verifiedManifest: VerifiedResourceManifest,
                      resourceID: String,
                      applicationAllowedHosts: [String],
                      stagingRoot: URL,
                      policy: ResourcePayloadDownloadPolicy,
                      dictionaryID: String = UUID().uuidString.lowercased(),
                      installedAt: Date = Date()) throws
        -> ResourcePayloadDownloadPlan {
        guard policy.applicationAllowedHosts == applicationAllowedHosts,
              !applicationAllowedHosts.isEmpty,
              stagingRoot.isFileURL,
              stagingRoot.baseURL == nil else {
            throw ResourcePayloadDownloadError.disabledConfiguration
        }
        guard let resource = verifiedManifest.validated.manifest.resources.first(where: {
            $0.resourceID == resourceID
        }) else {
            throw ResourcePayloadDownloadError.catalogEntryMissing
        }
        let revoked = verifiedManifest.validated.manifest.revokedResources.contains {
            $0.resourceID == resource.resourceID &&
                $0.minimumRevision <= resource.resourceRevision &&
                resource.resourceRevision <= $0.maximumRevision
        }
        guard !revoked, resource.status == .active else {
            throw ResourcePayloadDownloadError.invalidVerifiedManifest
        }
        guard resource.distributionMode == .mirroredDownload else {
            throw ResourcePayloadDownloadError.unsupportedDistributionMode
        }
        guard resource.archiveFormat == ResourceArchiveFormat.none,
              resource.dictionaryFormat == .genericMDictV1 else {
            throw ResourcePayloadDownloadError.unsupportedArchiveFormat
        }
        guard let rawURL = resource.downloadURL,
              let signedHosts = resource.allowedDownloadHosts,
              !signedHosts.isEmpty,
              let fileName = resource.fileName,
              let expectedBytes = resource.compressedSize,
              let signedMaximumBytes = resource.maximumDownloadedSize,
              let expectedSHA256 = resource.sha256,
              ResourceManifestValidation.isLowercaseSHA256(expectedSHA256) else {
            throw ResourcePayloadDownloadError.invalidVerifiedManifest
        }
        guard isSafeMDXFileName(fileName) else {
            throw ResourcePayloadDownloadError.invalidFileName
        }
        guard expectedBytes > 0,
              signedMaximumBytes > 0,
              expectedBytes <= signedMaximumBytes,
              signedMaximumBytes <= policy.applicationHardLimit else {
            throw ResourcePayloadDownloadError.invalidSignedSize
        }

        let signedPolicy: ResourceNetworkURLPolicy
        let applicationPolicy: ResourceNetworkURLPolicy
        do {
            signedPolicy = try ResourceNetworkURLPolicy(pinnedAllowedHosts: signedHosts)
            applicationPolicy = try ResourceNetworkURLPolicy(
                pinnedAllowedHosts: applicationAllowedHosts
            )
        } catch {
            throw ResourcePayloadDownloadError.disallowedHost
        }
        let applicationSet = Set(applicationPolicy.pinnedAllowedHosts)
        let intersection = signedPolicy.pinnedAllowedHosts.filter(applicationSet.contains)
        guard !intersection.isEmpty else {
            throw ResourcePayloadDownloadError.disallowedHost
        }
        let intersectionPolicy: ResourceNetworkURLPolicy
        let downloadURL: URL
        do {
            intersectionPolicy = try ResourceNetworkURLPolicy(pinnedAllowedHosts: intersection)
            downloadURL = try intersectionPolicy.validateInitialURL(rawURL)
        } catch {
            throw ResourcePayloadDownloadError.disallowedHost
        }

        let identity = try OpenResourceInstallationIdentity(verifiedManifest: verifiedManifest,
                                                             resourceID: resourceID,
                                                             dictionaryID: dictionaryID,
                                                             installedAt: installedAt)
        guard identity.payloadBytes == expectedBytes, identity.payloadSHA256 == expectedSHA256 else {
            throw ResourcePayloadDownloadError.invalidVerifiedManifest
        }
        return ResourcePayloadDownloadPlan(
            resourceID: resource.resourceID,
            resourceRevision: resource.resourceRevision,
            downloadURL: downloadURL,
            signedFileName: fileName,
            expectedBytes: expectedBytes,
            maximumBytes: min(policy.applicationHardLimit, signedMaximumBytes),
            expectedSHA256: expectedSHA256,
            allowedHosts: intersectionPolicy.pinnedAllowedHosts,
            stagingRoot: stagingRoot.standardizedFileURL,
            policy: policy,
            installationIdentity: identity
        )
    }

    static func isSafeMDXFileName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count),
              bytes.count == value.count,
              bytes.first != 46,
              bytes.last != 46,
              bytes.last != 32,
              !value.contains(".."),
              !value.contains("/"),
              !value.contains("\\"),
              URL(fileURLWithPath: value).pathExtension
                .caseInsensitiveCompare("mdx") == .orderedSame else {
            return false
        }
        return bytes.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }
}

enum ResourcePayloadDownloadPhase: String, Equatable, Sendable {
    case preparing
    case downloading
    case verifying
    case publishingToStaging
    case completed
    case failed
}

struct ResourcePayloadDownloadProgress: Equatable, Sendable {
    let operationID: UUID
    let receivedBytes: UInt64
    let expectedBytes: UInt64?
    let phase: ResourcePayloadDownloadPhase
    let diagnosticLines: [String]

    init(operationID: UUID, receivedBytes: UInt64, expectedBytes: UInt64?,
         phase: ResourcePayloadDownloadPhase, diagnosticLines: [String] = []) {
        self.operationID = operationID
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.phase = phase
        self.diagnosticLines = diagnosticLines
    }
}

struct VerifiedPayloadStagingResult: Equatable, Sendable {
    let resourceID: String
    let resourceRevision: UInt64
    let operationID: UUID
    let verifiedFileURL: URL
    let signedFileName: String
    let actualByteCount: UInt64
    let verifiedSHA256: String
    let stagingRootURL: URL
    let verifiedDirectoryComponent: String
    let payloadComponent: String
    let sidecarComponent: String
    let installationIdentity: OpenResourceInstallationIdentity
}
