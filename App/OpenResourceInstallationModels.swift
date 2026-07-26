import Foundation

enum OpenResourceInstallationError: LocalizedError, Equatable {
    case invalidIdentity
    case invalidSidecar
    case unsafeVerifiedPayload
    case conflict
    case crossDevicePublication
    case durabilityFailure
    case catalogCommitFailedAfterFilesystemPublish
    case installationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "开放词典安装身份无效。"
        case .invalidSidecar: return "开放词典安装信息无效。"
        case .unsafeVerifiedPayload: return "已验证词典文件未通过安全复核。"
        case .conflict: return "该开放词典已安装。"
        case .crossDevicePublication: return "词典暂存位置与安装位置不在同一磁盘上。"
        case .durabilityFailure: return "词典文件已发布，但未能确认磁盘持久化。"
        case .catalogCommitFailedAfterFilesystemPublish:
            return "词典文件已安装，但目录记录未能保存。"
        case .installationInProgress: return "该开放词典正在安装。"
        }
    }
}

struct OpenResourceInstallationIdentity: Equatable, Sendable {
    static let payloadComponent = "payload.mdx"
    static let sidecarComponent = "resource-installation.json"
    static let sidecarFormatVersion = 1

    let dictionaryID: String
    let resourceID: String
    let resourceRevision: UInt64
    let resourceVersion: String
    let manifestVersion: UInt64
    let manifestSHA256: String
    let verifiedKeyID: String
    let payloadSHA256: String
    let payloadBytes: UInt64
    let languages: [String]
    let license: OpenResourceLicenseMetadata
    let sourceProject: String
    let officialPageReference: String
    let expectedEntryCount: OpenResourceEntryCountMetadata
    let installedAt: Date
    let formatterIdentifier: String

    init(verifiedManifest: VerifiedResourceManifest,
         resourceID: String,
         dictionaryID: String = UUID().uuidString.lowercased(),
         installedAt: Date = Date()) throws {
        guard OpenResourceInstallationMetadata.isCanonicalUUID(dictionaryID),
              let resource = verifiedManifest.validated.manifest.resources.first(where: { $0.resourceID == resourceID }),
              resource.status == .active,
              resource.resourceRevision > 0,
              resource.expectedEntryCount.minimum <= resource.expectedEntryCount.maximum,
              let payloadBytes = resource.compressedSize, payloadBytes > 0,
              let payloadSHA256 = resource.sha256,
              OpenResourceInstallationMetadata.isSHA256(payloadSHA256),
              OpenResourceInstallationMetadata.isSHA256(verifiedManifest.manifestSHA256) else {
            throw OpenResourceInstallationError.invalidIdentity
        }
        self.dictionaryID = dictionaryID.lowercased()
        self.resourceID = resource.resourceID
        resourceRevision = resource.resourceRevision
        resourceVersion = resource.version
        manifestVersion = verifiedManifest.validated.manifest.manifestVersion
        manifestSHA256 = verifiedManifest.manifestSHA256
        verifiedKeyID = verifiedManifest.verifiedKeyID
        self.payloadSHA256 = payloadSHA256
        self.payloadBytes = payloadBytes
        languages = resource.languages
        license = OpenResourceLicenseMetadata(name: resource.licenseName, version: resource.licenseVersion,
                                               url: resource.licenseURL, attribution: resource.attribution)
        sourceProject = resource.sourceProjectURL
        officialPageReference = resource.officialDownloadPage
        expectedEntryCount = OpenResourceEntryCountMetadata(minimum: resource.expectedEntryCount.minimum,
                                                             maximum: resource.expectedEntryCount.maximum)
        self.installedAt = installedAt
        formatterIdentifier = DictionaryFormatterIdentifier.genericMDictV1
    }

    init(dictionaryID: String, resourceID: String, resourceRevision: UInt64, resourceVersion: String,
         manifestVersion: UInt64, manifestSHA256: String, verifiedKeyID: String,
         payloadSHA256: String, payloadBytes: UInt64, languages: [String],
         license: OpenResourceLicenseMetadata, sourceProject: String,
         officialPageReference: String, expectedEntryCount: OpenResourceEntryCountMetadata,
         installedAt: Date, formatterIdentifier: String = DictionaryFormatterIdentifier.genericMDictV1) throws {
        guard OpenResourceInstallationMetadata.isCanonicalUUID(dictionaryID),
              OpenResourceInstallationMetadata.isSafeToken(resourceID), resourceRevision > 0,
              manifestVersion > 0, OpenResourceInstallationMetadata.isSHA256(manifestSHA256),
              OpenResourceInstallationMetadata.isSHA256(payloadSHA256), payloadBytes > 0,
              !verifiedKeyID.isEmpty, !languages.isEmpty,
              expectedEntryCount.minimum <= expectedEntryCount.maximum,
              DictionaryFormatterIdentifier.supportsGenericMDictV1(formatterIdentifier) else {
            throw OpenResourceInstallationError.invalidIdentity
        }
        self.dictionaryID = dictionaryID.lowercased(); self.resourceID = resourceID
        self.resourceRevision = resourceRevision; self.resourceVersion = resourceVersion
        self.manifestVersion = manifestVersion; self.manifestSHA256 = manifestSHA256
        self.verifiedKeyID = verifiedKeyID; self.payloadSHA256 = payloadSHA256
        self.payloadBytes = payloadBytes; self.languages = languages; self.license = license
        self.sourceProject = sourceProject; self.officialPageReference = officialPageReference
        self.expectedEntryCount = expectedEntryCount; self.installedAt = installedAt
        self.formatterIdentifier = formatterIdentifier
    }

    var catalogMetadata: OpenResourceInstallationMetadata {
        OpenResourceInstallationMetadata(resourceID: resourceID, resourceRevision: resourceRevision,
                                         resourceVersion: resourceVersion, manifestVersion: manifestVersion,
                                         manifestSHA256: manifestSHA256, verifiedKeyID: verifiedKeyID,
                                         payloadSHA256: payloadSHA256, payloadBytes: payloadBytes,
                                         sidecarRelativePath: "Dictionaries/\(dictionaryID)/\(Self.sidecarComponent)",
                                         languages: languages, license: license, sourceProject: sourceProject,
                                         officialPageReference: officialPageReference,
                                         expectedEntryCount: expectedEntryCount, installedAt: installedAt)
    }
}

struct OpenResourceInstallationSidecar: Codable, Equatable, Sendable {
    let formatVersion: Int
    let dictionaryID: String
    let resourceID: String
    let resourceRevision: UInt64
    let resourceVersion: String
    let payloadRelativePath: String
    let payloadBytes: UInt64
    let payloadSHA256: String
    let sourceKind: DictionarySourceKind
    let storageOwnership: DictionaryStorageOwnership
    let languages: [String]
    let formatterIdentifier: String
    let license: OpenResourceLicenseMetadata
    let manifestVersion: UInt64
    let manifestSHA256: String
    let verifiedKeyID: String
    let expectedEntryCount: OpenResourceEntryCountMetadata
    let sourceProject: String
    let officialPageReference: String
    let installedAt: Date

    init(identity: OpenResourceInstallationIdentity) {
        formatVersion = OpenResourceInstallationIdentity.sidecarFormatVersion
        dictionaryID = identity.dictionaryID; resourceID = identity.resourceID
        resourceRevision = identity.resourceRevision; resourceVersion = identity.resourceVersion
        payloadRelativePath = OpenResourceInstallationIdentity.payloadComponent
        payloadBytes = identity.payloadBytes; payloadSHA256 = identity.payloadSHA256
        sourceKind = .openResource; storageOwnership = .appManagedOpenResource
        languages = identity.languages; formatterIdentifier = identity.formatterIdentifier
        license = identity.license; manifestVersion = identity.manifestVersion
        manifestSHA256 = identity.manifestSHA256; verifiedKeyID = identity.verifiedKeyID
        expectedEntryCount = identity.expectedEntryCount; sourceProject = identity.sourceProject
        officialPageReference = identity.officialPageReference; installedAt = identity.installedAt
    }

    func validated(expected identity: OpenResourceInstallationIdentity? = nil) throws -> OpenResourceInstallationSidecar {
        guard formatVersion == OpenResourceInstallationIdentity.sidecarFormatVersion,
              OpenResourceInstallationMetadata.isCanonicalUUID(dictionaryID),
              OpenResourceInstallationMetadata.isSafeToken(resourceID), resourceRevision > 0,
              manifestVersion > 0, payloadRelativePath == OpenResourceInstallationIdentity.payloadComponent,
              !payloadRelativePath.contains("/"), !payloadRelativePath.contains("\\"),
              payloadBytes > 0, OpenResourceInstallationMetadata.isSHA256(payloadSHA256),
              OpenResourceInstallationMetadata.isSHA256(manifestSHA256), !verifiedKeyID.isEmpty,
              sourceKind == .openResource, storageOwnership == .appManagedOpenResource,
              DictionaryOwnershipPolicy.policy(for: sourceKind, ownership: storageOwnership) != nil,
              !languages.isEmpty, DictionaryFormatterIdentifier.supportsGenericMDictV1(formatterIdentifier),
              expectedEntryCount.minimum <= expectedEntryCount.maximum else {
            throw OpenResourceInstallationError.invalidSidecar
        }
        if let identity {
            guard self == OpenResourceInstallationSidecar(identity: identity) else {
                throw OpenResourceInstallationError.invalidSidecar
            }
        }
        return self
    }

    func encodedData() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 64 * 1024 else { throw OpenResourceInstallationError.invalidSidecar }
        return data
    }

    static func decode(_ data: Data) throws -> OpenResourceInstallationSidecar {
        guard !data.isEmpty, data.count <= 64 * 1024 else { throw OpenResourceInstallationError.invalidSidecar }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(OpenResourceInstallationSidecar.self, from: data).validated()
    }
}
