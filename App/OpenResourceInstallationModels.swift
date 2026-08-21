import Foundation

enum OpenResourceInstallationError: LocalizedError, Equatable {
    case invalidIdentity
    case invalidSidecar
    case sidecarIdentityMismatch
    case payloadIdentityMismatch
    case unexpectedInstallationEntry
    case unsafeVerifiedPayload
    case resourceAlreadyInstalled
    case dictionaryIDConflict
    case conflict
    case crossDevicePublication
    case durabilityFailure
    case finalPublishedButDirectoryIdentityMismatch
    case filesystemPublishedButIdentityUnconfirmed
    case catalogCommitFailedAfterFilesystemPublish
    case installationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "开放词典安装身份无效。"
        case .invalidSidecar: return "开放词典安装信息无效。"
        case .sidecarIdentityMismatch: return "开放词典安装信息与已验证身份不一致。"
        case .payloadIdentityMismatch: return "开放词典文件与已验证身份不一致。"
        case .unexpectedInstallationEntry: return "开放词典目录包含未预期文件。"
        case .unsafeVerifiedPayload: return "已验证词典文件未通过安全复核。"
        case .resourceAlreadyInstalled: return "该开放词典资源已安装。"
        case .dictionaryIDConflict: return "该开放词典安装标识已存在。"
        case .conflict: return "该开放词典已安装。"
        case .crossDevicePublication: return "词典暂存位置与安装位置不在同一磁盘上。"
        case .durabilityFailure: return "词典文件已发布，但未能确认磁盘持久化。"
        case .finalPublishedButDirectoryIdentityMismatch:
            return "词典目录已发布，但目录身份未通过复核。"
        case .filesystemPublishedButIdentityUnconfirmed:
            return "词典目录已发布，但内容身份未通过复核。"
        case .catalogCommitFailedAfterFilesystemPublish:
            return "词典文件已安装，但目录记录未能保存。"
        case .installationInProgress: return "该开放词典正在安装。"
        }
    }
}

struct OpenResourceInstallationIdentity: Equatable, Sendable {
    static let payloadComponent = "payload.mdx"
    static let starDictSourceComponent = "source.stardict.tar.xz"
    static let ccCedictSourceComponent = "source.cc-cedict.txt.gz"
    static let kaikkiSourceComponent = "source.wiktionary.jsonl"
    static let wordNetSourceComponent = "source.wordnet.tar.gz"
    static let gcideSourceComponent = "source.gcide.tar.xz"
    static let convertedSourceComponents: Set<String> = [
        starDictSourceComponent, ccCedictSourceComponent, kaikkiSourceComponent,
        wordNetSourceComponent, gcideSourceComponent
    ]
    static let sidecarComponent = "resource-installation.json"
    static let sidecarFormatVersion = 1
    static let convertedSidecarFormatVersion = 2

    let dictionaryID: String
    let resourceID: String
    let displayName: String
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

#if !OPEN_RESOURCE_CONVERTER_TESTING
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
        displayName = resource.displayName
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
        self.installedAt = Date(timeIntervalSince1970: floor(installedAt.timeIntervalSince1970))
        formatterIdentifier = DictionaryFormatterIdentifier.genericMDictV1
    }
#endif

    init(dictionaryID: String, resourceID: String, resourceRevision: UInt64, resourceVersion: String,
         manifestVersion: UInt64, manifestSHA256: String, verifiedKeyID: String,
         payloadSHA256: String, payloadBytes: UInt64, languages: [String],
         license: OpenResourceLicenseMetadata, sourceProject: String,
         officialPageReference: String, expectedEntryCount: OpenResourceEntryCountMetadata,
         installedAt: Date,
         formatterIdentifier: String = DictionaryFormatterIdentifier.genericMDictV1,
         displayName: String? = nil) throws {
        guard OpenResourceInstallationMetadata.isCanonicalUUID(dictionaryID),
              OpenResourceInstallationMetadata.isSafeToken(resourceID), resourceRevision > 0,
              manifestVersion > 0, OpenResourceInstallationMetadata.isSHA256(manifestSHA256),
              OpenResourceInstallationMetadata.isSHA256(payloadSHA256), payloadBytes > 0,
              ResourceManifestKeyID.isValid(verifiedKeyID), !languages.isEmpty,
              expectedEntryCount.minimum <= expectedEntryCount.maximum,
              (DictionaryFormatterIdentifier.supportsGenericMDictV1(formatterIdentifier) ||
                DictionaryFormatterIdentifier.supportsOpenResourceSQLite(formatterIdentifier)) else {
            throw OpenResourceInstallationError.invalidIdentity
        }
        let resolvedDisplayName = displayName ?? resourceID
        guard !resolvedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              resolvedDisplayName.utf8.count <= 512 else {
            throw OpenResourceInstallationError.invalidIdentity
        }
        self.dictionaryID = dictionaryID.lowercased(); self.resourceID = resourceID
        self.displayName = resolvedDisplayName
        self.resourceRevision = resourceRevision; self.resourceVersion = resourceVersion
        self.manifestVersion = manifestVersion; self.manifestSHA256 = manifestSHA256
        self.verifiedKeyID = verifiedKeyID; self.payloadSHA256 = payloadSHA256
        self.payloadBytes = payloadBytes; self.languages = languages; self.license = license
        self.sourceProject = sourceProject; self.officialPageReference = officialPageReference
        self.expectedEntryCount = expectedEntryCount
        self.installedAt = Date(timeIntervalSince1970: floor(installedAt.timeIntervalSince1970))
        self.formatterIdentifier = formatterIdentifier
    }

    var sourceComponent: String {
        DictionaryFormatterIdentifier.supportsOpenResourceSQLite(formatterIdentifier)
            ? Self.sourceComponent(for: formatterIdentifier) : Self.payloadComponent
    }

    static func sourceComponent(for formatterIdentifier: String) -> String {
        switch formatterIdentifier {
        case DictionaryFormatterIdentifier.freeDictStarDictV1:
            return starDictSourceComponent
        case DictionaryFormatterIdentifier.ccCedictTextV1:
            return ccCedictSourceComponent
        case DictionaryFormatterIdentifier.kaikkiWiktionaryJSONLV1:
            return kaikkiSourceComponent
        case DictionaryFormatterIdentifier.wordNetDataV1:
            return wordNetSourceComponent
        case DictionaryFormatterIdentifier.gcideMarkupV1:
            return gcideSourceComponent
        default:
            return payloadComponent
        }
    }

    var receiptFormatVersion: Int {
        DictionaryFormatterIdentifier.supportsOpenResourceSQLite(formatterIdentifier)
            ? Self.convertedSidecarFormatVersion : Self.sidecarFormatVersion
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
    let sourceURL: String?
    let officialDigestAlgorithm: String?
    let officialDigest: String?
    let transformerVersion: String?
    let outputSchemaVersion: Int?
    let outputPublicationID: String?
    let outputSHA256: String?
    let outputIntegrityStatus: String?

    init(identity: OpenResourceInstallationIdentity) {
        formatVersion = identity.receiptFormatVersion
        dictionaryID = identity.dictionaryID; resourceID = identity.resourceID
        resourceRevision = identity.resourceRevision; resourceVersion = identity.resourceVersion
        payloadRelativePath = identity.sourceComponent
        payloadBytes = identity.payloadBytes; payloadSHA256 = identity.payloadSHA256
        sourceKind = .openResource; storageOwnership = .appManagedOpenResource
        languages = identity.languages; formatterIdentifier = identity.formatterIdentifier
        license = identity.license; manifestVersion = identity.manifestVersion
        manifestSHA256 = identity.manifestSHA256; verifiedKeyID = identity.verifiedKeyID
        expectedEntryCount = identity.expectedEntryCount; sourceProject = identity.sourceProject
        officialPageReference = identity.officialPageReference; installedAt = identity.installedAt
        sourceURL = nil; officialDigestAlgorithm = nil; officialDigest = nil
        transformerVersion = nil; outputSchemaVersion = nil; outputPublicationID = nil
        outputSHA256 = nil; outputIntegrityStatus = nil
    }


    init(identity: OpenResourceInstallationIdentity,
         sourceURL: String,
         officialDigestAlgorithm: String,
         officialDigest: String,
         transformerVersion: String,
         outputSchemaVersion: Int,
         outputPublicationID: String,
         outputSHA256: String,
         outputIntegrityStatus: String) {
        formatVersion = identity.receiptFormatVersion
        dictionaryID = identity.dictionaryID; resourceID = identity.resourceID
        resourceRevision = identity.resourceRevision; resourceVersion = identity.resourceVersion
        payloadRelativePath = identity.sourceComponent
        payloadBytes = identity.payloadBytes; payloadSHA256 = identity.payloadSHA256
        sourceKind = .openResource; storageOwnership = .appManagedOpenResource
        languages = identity.languages; formatterIdentifier = identity.formatterIdentifier
        license = identity.license; manifestVersion = identity.manifestVersion
        manifestSHA256 = identity.manifestSHA256; verifiedKeyID = identity.verifiedKeyID
        expectedEntryCount = identity.expectedEntryCount; sourceProject = identity.sourceProject
        officialPageReference = identity.officialPageReference; installedAt = identity.installedAt
        self.sourceURL = sourceURL
        self.officialDigestAlgorithm = officialDigestAlgorithm
        self.officialDigest = officialDigest
        self.transformerVersion = transformerVersion
        self.outputSchemaVersion = outputSchemaVersion
        self.outputPublicationID = outputPublicationID
        self.outputSHA256 = outputSHA256
        self.outputIntegrityStatus = outputIntegrityStatus
    }

    func validated(expected identity: OpenResourceInstallationIdentity? = nil) throws -> OpenResourceInstallationSidecar {
        let generic = DictionaryFormatterIdentifier.supportsGenericMDictV1(formatterIdentifier)
        let converted = DictionaryFormatterIdentifier.supportsOpenResourceSQLite(formatterIdentifier)
        guard (generic && formatVersion == OpenResourceInstallationIdentity.sidecarFormatVersion ||
                converted && formatVersion == OpenResourceInstallationIdentity.convertedSidecarFormatVersion),
              OpenResourceInstallationMetadata.isCanonicalUUID(dictionaryID),
              OpenResourceInstallationMetadata.isSafeToken(resourceID), resourceRevision > 0,
              manifestVersion > 0,
              payloadRelativePath == (converted
                ? OpenResourceInstallationIdentity.sourceComponent(for: formatterIdentifier)
                : OpenResourceInstallationIdentity.payloadComponent),
              !payloadRelativePath.contains("/"), !payloadRelativePath.contains("\\"),
              payloadBytes > 0, OpenResourceInstallationMetadata.isSHA256(payloadSHA256),
              OpenResourceInstallationMetadata.isSHA256(manifestSHA256),
              ResourceManifestKeyID.isValid(verifiedKeyID),
              sourceKind == .openResource, storageOwnership == .appManagedOpenResource,
              DictionaryOwnershipPolicy.policy(for: sourceKind, ownership: storageOwnership) != nil,
              !languages.isEmpty, (generic || converted),
              expectedEntryCount.minimum <= expectedEntryCount.maximum else {
            throw OpenResourceInstallationError.invalidSidecar
        }
        if converted {
            let digestValid = (officialDigestAlgorithm == "SHA-512" &&
                officialDigest?.count == 128) ||
                (officialDigestAlgorithm == "SHA-256" && officialDigest?.count == 64)
            let allOutputFields = sourceURL != nil && digestValid && transformerVersion != nil &&
                (outputSchemaVersion ?? 0) > 0 &&
                outputPublicationID.flatMap(UUID.init(uuidString:)) != nil &&
                outputSHA256.map(OpenResourceInstallationMetadata.isSHA256) == true &&
                outputIntegrityStatus == "ok"
            let noOutputFields = sourceURL == nil && officialDigestAlgorithm == nil &&
                officialDigest == nil && transformerVersion == nil && outputSchemaVersion == nil &&
                outputPublicationID == nil && outputSHA256 == nil && outputIntegrityStatus == nil
            guard allOutputFields || noOutputFields else {
                throw OpenResourceInstallationError.invalidSidecar
            }
            if allOutputFields {
                if let resource = AuditedOpenResourceSecurityRegistry.resource(id: resourceID) {
                    guard resourceRevision == resource.resourceRevision,
                          resourceVersion == resource.version,
                          payloadBytes == resource.downloadBytes,
                          payloadSHA256 == resource.sha256,
                          manifestSHA256 == resource.catalogMetadataSHA256,
                          sourceURL == resource.downloadURL,
                          officialDigestAlgorithm == resource.officialDigestAlgorithm,
                          officialDigest == resource.officialDigest,
                          transformerVersion == resource.transformerVersion,
                          outputSchemaVersion == resource.outputSchemaVersion else {
                        throw OpenResourceInstallationError.invalidSidecar
                    }
                } else if !LiveOfficialOpenResourcePolicy.accepts(
                    resourceID: resourceID,
                    formatterIdentifier: formatterIdentifier,
                    sourceURL: sourceURL ?? ""
                ) {
                    throw OpenResourceInstallationError.invalidSidecar
                }
            }
        }
        if let identity {
            let expected = OpenResourceInstallationSidecar(identity: identity)
            // Compare the decoded schema values, never the source JSON representation or its
            // key order. `OpenResourceInstallationIdentity` normalizes installedAt to the
            // sidecar's whole-second encoding before this comparison.
            guard self == expected else {
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
