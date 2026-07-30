import Foundation

enum DictionaryFormatterIdentifier: Sendable {
    static let genericMDictV1 = "generic-mdict-v1"
    static let legacyGenericMDictV1 = "generic-mdict.v1"

    static func supportsGenericMDictV1(_ identifier: String) -> Bool {
        identifier == genericMDictV1 || identifier == legacyGenericMDictV1
    }
}

enum DictionaryQueryLevel: String, Codable, CaseIterable, Sendable {
    case preferred
    case normal
    case fallback

    var rank: Int {
        switch self {
        case .preferred: return 0
        case .normal: return 1
        case .fallback: return 2
        }
    }

    var displayName: String {
        switch self {
        case .preferred: return "首选"
        case .normal: return "普通"
        case .fallback: return "仅后备"
        }
    }
}

enum DictionarySourceKind: String, Codable, Sendable {
    case legacyReference
    case managedLocal
    case externalReference
    case openResource

    var defaultQueryLevel: DictionaryQueryLevel {
        switch self {
        case .legacyReference, .managedLocal, .externalReference:
            return .normal
        case .openResource:
            return .fallback
        }
    }

    var displayName: String {
        switch self {
        case .legacyReference: return "旧配置引用"
        case .managedLocal: return "本地托管"
        case .externalReference: return "外部文件引用"
        case .openResource: return "开放词典"
        }
    }
}

/// Filesystem ownership is deliberately independent from lookup precedence and lifecycle state.
/// It is persisted because the lifecycle code must never infer deletion authority from a display
/// source kind or from a path.
enum DictionaryStorageOwnership: String, Codable, Sendable {
    case externalReference
    case appManagedImported
    case appManagedOpenResource
    case bundledReadOnly
}

struct DictionaryOwnershipPolicy: Sendable {
    let isAppManaged: Bool
    let isRecoverable: Bool
    let isRemovable: Bool
    let isIndexable: Bool

    static func policy(for sourceKind: DictionarySourceKind,
                       ownership: DictionaryStorageOwnership) -> DictionaryOwnershipPolicy? {
        switch (sourceKind, ownership) {
        case (.legacyReference, .externalReference),
             (.externalReference, .externalReference):
            return DictionaryOwnershipPolicy(isAppManaged: false, isRecoverable: false,
                                             isRemovable: false, isIndexable: false)
        case (.managedLocal, .appManagedImported):
            return DictionaryOwnershipPolicy(isAppManaged: true, isRecoverable: true,
                                             isRemovable: true, isIndexable: true)
        case (.openResource, .appManagedOpenResource):
            return DictionaryOwnershipPolicy(isAppManaged: true, isRecoverable: true,
                                             isRemovable: true, isIndexable: true)
        default:
            // A bundled descriptor does not exist yet.  Keeping it out of the current matrix
            // fails closed instead of accidentally granting a future source kind deletion rights.
            return nil
        }
    }

    static func defaultOwnership(for sourceKind: DictionarySourceKind) -> DictionaryStorageOwnership? {
        switch sourceKind {
        case .legacyReference, .externalReference: return .externalReference
        case .managedLocal: return .appManagedImported
        case .openResource: return .appManagedOpenResource
        }
    }
}

struct OpenResourceLicenseMetadata: Codable, Equatable, Sendable {
    var name: String
    var version: String
    var url: String
    var attribution: String
}

struct OpenResourceEntryCountMetadata: Codable, Equatable, Sendable {
    var minimum: UInt64
    var maximum: UInt64
}

/// Immutable identity copied from a verified manifest/sidecar.  Mutable installation state stays
/// in `DictionaryDescriptor`, never in this structure.
struct OpenResourceInstallationMetadata: Codable, Equatable, Sendable {
    var resourceID: String
    var resourceRevision: UInt64
    var resourceVersion: String
    var manifestVersion: UInt64
    var manifestSHA256: String
    var verifiedKeyID: String
    var payloadSHA256: String
    var payloadBytes: UInt64
    var sidecarRelativePath: String
    var languages: [String]
    var license: OpenResourceLicenseMetadata
    var sourceProject: String
    var officialPageReference: String
    var expectedEntryCount: OpenResourceEntryCountMetadata
    var installedAt: Date

    fileprivate func validate(dictionaryID: String) throws {
        guard OpenResourceInstallationMetadata.isCanonicalUUID(dictionaryID),
              OpenResourceInstallationMetadata.isSafeToken(resourceID),
              resourceRevision > 0,
              manifestVersion > 0,
              payloadBytes > 0,
              OpenResourceInstallationMetadata.isSHA256(manifestSHA256),
              OpenResourceInstallationMetadata.isSHA256(payloadSHA256),
              ResourceManifestKeyID.isValid(verifiedKeyID),
              sidecarRelativePath == "Dictionaries/\(dictionaryID)/resource-installation.json",
              !languages.isEmpty,
              expectedEntryCount.minimum <= expectedEntryCount.maximum else {
            throw DictionaryCatalogValidationError.invalidOpenResourceMetadata
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    static func isSafeToken(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count) && bytes.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

enum DictionaryState: String, Codable, Sendable {
    case waitingForImport
    case copying
    case scanning
    case pendingIndex
    case indexing
    case ready
    case disabled
    case missingResources
    case staleIndex
    case unavailable
    case invalid
    case corrupt
    case importFailed
    case failed

    var displayName: String {
        switch self {
        case .waitingForImport: return "等待导入"
        case .copying: return "正在复制"
        case .scanning: return "正在扫描"
        case .pendingIndex: return "等待索引"
        case .indexing: return "正在建立索引"
        case .ready: return "可用"
        case .disabled: return "已停用"
        case .missingResources: return "缺少资源"
        case .staleIndex: return "索引过期"
        case .unavailable: return "不可用"
        case .invalid: return "无效"
        case .corrupt: return "文件损坏"
        case .importFailed: return "导入失败"
        case .failed: return "索引失败"
        }
    }
}

struct DictionaryCapabilities: Codable, Equatable, Sendable {
    var englishLookup: Bool
    var chineseLookup: Bool
    var bilingualDefinitions: Bool
    var pronunciations: Bool
    var examples: Bool
    var synonyms: Bool
    var antonyms: Bool
    var morphology: Bool
    var semanticRelations: Bool

    static let unknown = DictionaryCapabilities(
        englishLookup: true,
        chineseLookup: false,
        bilingualDefinitions: false,
        pronunciations: false,
        examples: false,
        synonyms: false,
        antonyms: false,
        morphology: false,
        semanticRelations: false
    )
}

struct DictionaryRelativePaths: Codable, Equatable, Sendable {
    var dictionary: String?
    var resources: [String]
    var index: String?

    static let empty = DictionaryRelativePaths(dictionary: nil, resources: [], index: nil)

    fileprivate func validate() throws {
        for path in [dictionary, index].compactMap({ $0 }) + resources {
            guard Self.isSafeRelativePath(path) else {
                throw DictionaryCatalogValidationError.absoluteOrUnsafePath
            }
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              !path.contains("\\") else { return false }
        let components = NSString(string: path).pathComponents
        return !components.contains("..") && !components.contains(".")
    }
}

struct DictionaryIndexMetadata: Codable, Equatable, Sendable {
    var schemaVersion: Int?
    var entryCount: UInt64?
    var indexFileSize: UInt64?
    var sourceFileSize: UInt64?
    var sourceModifiedAt: Date?
    var sourceSHA256: String?
    var indexedAt: Date?
}

/// Durable content identity for one app-managed, query-eligible SQLite
/// publication. POSIX inode and timestamp fields are deliberately excluded.
struct PublishedIndexIdentity: Codable, Equatable, Sendable {
    var indexPublicationID: String
    var indexSHA256: String
    var indexFileSize: UInt64
    var sourceSHA256: String
    var sourceFileSize: UInt64
    var schemaVersion: Int
    var entryCount: UInt64
    var indexedAt: Date
    var relativePath: String

    fileprivate func validate(dictionaryID: String) throws {
        guard OpenResourceInstallationMetadata.isCanonicalUUID(indexPublicationID),
              OpenResourceInstallationMetadata.isSHA256(indexSHA256),
              OpenResourceInstallationMetadata.isSHA256(sourceSHA256),
              indexFileSize > 0, sourceFileSize > 0,
              schemaVersion > 0, entryCount > 0,
              relativePath ==
                "Dictionaries/\(dictionaryID)/index/dictionary.\(indexPublicationID).sqlite"
        else {
            throw DictionaryCatalogValidationError.invalidPublishedIndexFields
        }
    }
}

struct DictionaryDescriptor: Codable, Equatable, Identifiable, Sendable {
    var dictionaryID: String
    var displayName: String
    var sourceKind: DictionarySourceKind
    var queryLevel: DictionaryQueryLevel
    var sortPosition: Int64
    var enabled: Bool
    var state: DictionaryState
    var indexMetadata: DictionaryIndexMetadata
    var formatterIdentifier: String
    var capabilities: DictionaryCapabilities
    var relativePaths: DictionaryRelativePaths
    var createdAt: Date
    var updatedAt: Date
    var storageOwnership: DictionaryStorageOwnership = .appManagedImported
    var openResourceMetadata: OpenResourceInstallationMetadata?
    var publishedIndexIdentity: PublishedIndexIdentity? = nil

    var id: String { dictionaryID }

    fileprivate func validate() throws {
        guard !dictionaryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !formatterIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictionaryCatalogValidationError.missingRequiredValue
        }
        try relativePaths.validate()
        guard DictionaryOwnershipPolicy.policy(for: sourceKind, ownership: storageOwnership) != nil else {
            throw DictionaryCatalogValidationError.invalidStorageOwnership
        }
        if sourceKind == .openResource {
            guard let openResourceMetadata else {
                throw DictionaryCatalogValidationError.invalidOpenResourceMetadata
            }
            try openResourceMetadata.validate(dictionaryID: dictionaryID)
            guard relativePaths.dictionary == "Dictionaries/\(dictionaryID)/payload.mdx" else {
                throw DictionaryCatalogValidationError.invalidOpenResourceMetadata
            }
        } else if openResourceMetadata != nil {
            throw DictionaryCatalogValidationError.invalidOpenResourceMetadata
        }
        if DictionaryOwnershipPolicy.policy(
            for: sourceKind, ownership: storageOwnership
        )?.isAppManaged == true {
            if state == .ready {
                guard let publishedIndexIdentity else {
                    throw DictionaryCatalogValidationError
                        .invalidPublishedIndexBinding("missing")
                }
                guard relativePaths.index == publishedIndexIdentity.relativePath else {
                    throw DictionaryCatalogValidationError
                        .invalidPublishedIndexBinding("path")
                }
                guard indexMetadata.schemaVersion == publishedIndexIdentity.schemaVersion else {
                    throw DictionaryCatalogValidationError
                        .invalidPublishedIndexBinding("schema")
                }
                guard indexMetadata.entryCount == publishedIndexIdentity.entryCount else {
                    throw DictionaryCatalogValidationError
                        .invalidPublishedIndexBinding("entryCount")
                }
                guard indexMetadata.indexFileSize == publishedIndexIdentity.indexFileSize else {
                    throw DictionaryCatalogValidationError
                        .invalidPublishedIndexBinding("indexSize")
                }
                guard indexMetadata.sourceFileSize == publishedIndexIdentity.sourceFileSize else {
                    throw DictionaryCatalogValidationError
                        .invalidPublishedIndexBinding("sourceSize")
                }
                guard indexMetadata.sourceSHA256?.lowercased() ==
                        publishedIndexIdentity.sourceSHA256 else {
                    throw DictionaryCatalogValidationError
                        .invalidPublishedIndexBinding("sourceSHA")
                }
                try publishedIndexIdentity.validate(dictionaryID: dictionaryID)
            } else if relativePaths.index != nil || publishedIndexIdentity != nil {
                throw DictionaryCatalogValidationError.invalidPublishedIndexIdentity
            }
        }
    }
}

struct DictionaryCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var createdAt: Date
    var updatedAt: Date
    var dictionaries: [DictionaryDescriptor]

    static func empty(now: Date = Date()) -> DictionaryCatalog {
        DictionaryCatalog(schemaVersion: currentSchemaVersion,
                          createdAt: now,
                          updatedAt: now,
                          dictionaries: [])
    }

    var sortedDictionaries: [DictionaryDescriptor] {
        dictionaries.sorted {
            if $0.queryLevel.rank != $1.queryLevel.rank {
                return $0.queryLevel.rank < $1.queryLevel.rank
            }
            if $0.sortPosition != $1.sortPosition {
                return $0.sortPosition < $1.sortPosition
            }
            return $0.dictionaryID < $1.dictionaryID
        }
    }

    func validated() throws -> DictionaryCatalog {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DictionaryCatalogValidationError.unsupportedSchemaVersion
        }
        var identifiers: Set<String> = []
        var openResourceIDs: Set<String> = []
        for dictionary in dictionaries {
            try dictionary.validate()
            guard identifiers.insert(dictionary.dictionaryID).inserted else {
                throw DictionaryCatalogValidationError.duplicateDictionaryID
            }
            if let resourceID = dictionary.openResourceMetadata?.resourceID,
               !openResourceIDs.insert(resourceID).inserted {
                throw DictionaryCatalogValidationError.duplicateOpenResourceID
            }
        }
        return self
    }
}

enum DictionaryCatalogValidationError: LocalizedError {
    case unsupportedSchemaVersion
    case duplicateDictionaryID
    case missingRequiredValue
    case absoluteOrUnsafePath
    case invalidStorageOwnership
    case invalidOpenResourceMetadata
    case duplicateOpenResourceID
    case invalidPublishedIndexIdentity
    case invalidPublishedIndexFields
    case invalidPublishedIndexBinding(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion: return "不支持的词典目录版本。"
        case .duplicateDictionaryID: return "词典目录包含重复标识。"
        case .missingRequiredValue: return "词典目录缺少必要字段。"
        case .absoluteOrUnsafePath: return "词典目录包含绝对路径或不安全路径。"
        case .invalidStorageOwnership: return "词典目录包含不兼容的存储所有权。"
        case .invalidOpenResourceMetadata: return "开放词典安装身份无效。"
        case .duplicateOpenResourceID: return "开放词典资源已存在安装实例。"
        case .invalidPublishedIndexIdentity: return "托管词典的已发布索引身份无效。"
        case .invalidPublishedIndexFields: return "托管词典的已发布索引字段无效。"
        case .invalidPublishedIndexBinding(let field):
            return "托管词典的索引元数据绑定无效：\(field)。"
        }
    }
}
