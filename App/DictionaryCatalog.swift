import Foundation

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

    var id: String { dictionaryID }

    fileprivate func validate() throws {
        guard !dictionaryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !formatterIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictionaryCatalogValidationError.missingRequiredValue
        }
        try relativePaths.validate()
    }
}

struct DictionaryCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

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
        for dictionary in dictionaries {
            try dictionary.validate()
            guard identifiers.insert(dictionary.dictionaryID).inserted else {
                throw DictionaryCatalogValidationError.duplicateDictionaryID
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

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion: return "不支持的词典目录版本。"
        case .duplicateDictionaryID: return "词典目录包含重复标识。"
        case .missingRequiredValue: return "词典目录缺少必要字段。"
        case .absoluteOrUnsafePath: return "词典目录包含绝对路径或不安全路径。"
        }
    }
}
