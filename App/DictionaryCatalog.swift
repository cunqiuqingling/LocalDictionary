import Foundation

enum DictionaryFormatterIdentifier: Sendable {
    static let genericMDictV1 = "generic-mdict-v1"
    static let legacyGenericMDictV1 = "generic-mdict.v1"
    static let oxfordOALD8V1 = "oxford-oald8.v1"
    static let century21V1 = "century21.v1"
    static let newOxfordV1 = "new-oxford.v1"
    static let medicalEnglishChineseV1 = "medical-en-zh-2003.v1"
    static let affixRootAV1 = "affix-root-a.v1"
    static let freeDictStarDictV1 = "freedict-stardict-v1"
    static let ccCedictTextV1 = "cc-cedict-text-v1"
    static let kaikkiWiktionaryJSONLV1 = "kaikki-wiktionary-jsonl-v1"
    static let wordNetDataV1 = "wordnet-data-v1"
    static let gcideMarkupV1 = "gcide-markup-v1"

    static func supportsGenericMDictV1(_ identifier: String) -> Bool {
        identifier == genericMDictV1 || identifier == legacyGenericMDictV1
    }

    static func supportsLegacyMDictEnumeration(_ identifier: String) -> Bool {
        supportsGenericMDictV1(identifier) || [
            oxfordOALD8V1, century21V1, newOxfordV1,
            medicalEnglishChineseV1, affixRootAV1
        ].contains(identifier)
    }

    static func supportsOpenResourceSQLite(_ identifier: String) -> Bool {
        [freeDictStarDictV1, ccCedictTextV1, kaikkiWiktionaryJSONLV1,
         wordNetDataV1, gcideMarkupV1].contains(identifier)
    }

    static func openResourceSourceComponent(_ identifier: String) -> String? {
        switch identifier {
        case freeDictStarDictV1: return "source.stardict.tar.xz"
        case ccCedictTextV1: return "source.cc-cedict.txt.gz"
        case kaikkiWiktionaryJSONLV1: return "source.wiktionary.jsonl"
        case wordNetDataV1: return "source.wordnet.tar.gz"
        case gcideMarkupV1: return "source.gcide.tar.xz"
        default: return nil
        }
    }
}

enum FreeDictStarterSecurityConstants: Sendable {
    static let resourceID = "org.freedict.eng-zho"
    static let resourceRevision: UInt64 = 20_251_123
    static let version = "2025.11.23"
    static let sourceURL = "https://download.freedict.org/dictionaries/eng-zho/2025.11.23/" +
        "freedict-eng-zho-2025.11.23.stardict.tar.xz"
    static let sourceBytes: UInt64 = 1_672_048
    static let sourceSHA256 =
        "9dbae6bb5558906cc05f1e573bee2deab8b6e09adfb16fc496288926882435af"
    static let officialSHA512 =
        "059f9aca26fdc3a5a2c0c0e8fc92e111a34bf8fd438f70d267cccf35f5e47a2" +
        "d45c46650999a1b3a48c3bffc3e16e0db897232128fe822d1bc59cf34f40b395c"
    static let catalogMetadataSHA256 =
        "f2c66bec955cec692276c74e05b7f406c177fb3cf99e418285c1621560ac1194"
    static let transformerVersion = "1"
    static let outputSchemaVersion = 1
    static let sourceEntryCount: UInt64 = 26_660
    static let minimumConvertedEntryCount: UInt64 = 26_000
}

/// Small security registry shared by catalog/receipt validation. The richer product presentation
/// lives in `BundledOpenResourceCatalog`; its startup assertion must match these immutable fields.
struct AuditedOpenResourceSecurityMetadata: Equatable, Sendable {
    let resourceID: String
    let resourceRevision: UInt64
    let version: String
    let downloadURL: String
    let downloadBytes: UInt64
    let sha256: String
    let catalogMetadataSHA256: String
    let officialDigestAlgorithm: String
    let officialDigest: String
    let transformerIdentifier: String
    let transformerVersion: String
    let outputSchemaVersion: Int
    let minimumConvertedEntryCount: UInt64
    let expectedEntryCount: UInt64
    let licenseIdentifier: String
}

enum AuditedOpenResourceSecurityRegistry: Sendable {
    private static let records: [String: AuditedOpenResourceSecurityMetadata] = {
        var values = [
            AuditedOpenResourceSecurityMetadata(
                resourceID: FreeDictStarterSecurityConstants.resourceID,
                resourceRevision: FreeDictStarterSecurityConstants.resourceRevision,
                version: FreeDictStarterSecurityConstants.version,
                downloadURL: FreeDictStarterSecurityConstants.sourceURL,
                downloadBytes: FreeDictStarterSecurityConstants.sourceBytes,
                sha256: FreeDictStarterSecurityConstants.sourceSHA256,
                catalogMetadataSHA256:
                    FreeDictStarterSecurityConstants.catalogMetadataSHA256,
                officialDigestAlgorithm: "SHA-512",
                officialDigest: FreeDictStarterSecurityConstants.officialSHA512,
                transformerIdentifier: DictionaryFormatterIdentifier.freeDictStarDictV1,
                transformerVersion: FreeDictStarterSecurityConstants.transformerVersion,
                outputSchemaVersion: FreeDictStarterSecurityConstants.outputSchemaVersion,
                minimumConvertedEntryCount:
                    FreeDictStarterSecurityConstants.minimumConvertedEntryCount,
                expectedEntryCount: FreeDictStarterSecurityConstants.sourceEntryCount,
                licenseIdentifier: "CC-BY-SA-3.0"
            ),
            AuditedOpenResourceSecurityMetadata(
                resourceID: "org.cc-cedict.zh-en",
                resourceRevision: 20_260_808_091_604,
                version: "2026-08-08T09:16:04Z",
                downloadURL:
                    "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz",
                downloadBytes: 3_967_111,
                sha256: "1fe09c26e17ab52eceb2be2988f9c89b13c9b2b010e27325e97c2d0664c65701",
                catalogMetadataSHA256:
                    "67c47c9c8c3f2dde52a3318ab4d53b71fb449cd61a240390d17a83560b512fe6",
                officialDigestAlgorithm: "SHA-256",
                officialDigest:
                    "1fe09c26e17ab52eceb2be2988f9c89b13c9b2b010e27325e97c2d0664c65701",
                transformerIdentifier: DictionaryFormatterIdentifier.ccCedictTextV1,
                transformerVersion: "1", outputSchemaVersion: 1,
                minimumConvertedEntryCount: 120_000,
                expectedEntryCount: 250_000,
                licenseIdentifier: "CC-BY-SA-4.0"
            ),
            AuditedOpenResourceSecurityMetadata(
                resourceID: "org.gnu.gcide.en", resourceRevision: 54,
                version: "0.54",
                downloadURL: "https://ftp.gnu.org/gnu/gcide/gcide-0.54.tar.xz",
                downloadBytes: 14_803_080,
                sha256: "22416f6f36175b160dc388b7547512514d464473cf7d7c898d738efb26c51d42",
                catalogMetadataSHA256:
                    "66e4e3c8bce8e50897653e549e1e88ff258682437f2dae7cc2521639c355a16d",
                officialDigestAlgorithm: "SHA-512",
                officialDigest:
                    "9bda8bc2e30a529bafeb3fcdd2f315025209fa2e609da707caf7b4a273221a761" +
                    "7a10b58d2b635e1ae980e01a790a4e09bb74ec54d6e09c9014e72b30d33b1e6",
                transformerIdentifier: DictionaryFormatterIdentifier.gcideMarkupV1,
                transformerVersion: "1", outputSchemaVersion: 1,
                minimumConvertedEntryCount: 100_000,
                expectedEntryCount: 250_000,
                licenseIdentifier: "GPL-3.0-or-later"
            ),
            AuditedOpenResourceSecurityMetadata(
                resourceID: "org.princeton.wordnet.en", resourceRevision: 30,
                version: "3.0",
                downloadURL:
                    "https://wordnetcode.princeton.edu/3.0/WNdb-3.0.tar.gz",
                downloadBytes: 10_518_425,
                sha256: "658b1ba191f5f98c2e9bae3e25c186013158f30ef779f191d2a44e5d25046dc8",
                catalogMetadataSHA256:
                    "e499c439c98cae0cc25717ff383eb443fea66d51ca4fa68e83da00214293782c",
                officialDigestAlgorithm: "SHA-512",
                officialDigest:
                    "41e177167fa80fa9c26c8002b2783d2bcffa2622b9fec6d5f446ef498b214197" +
                    "3489020b7dce928cce5ce14e6cc5606c7cbb4678e1f069acf907f64f3a38c730",
                transformerIdentifier: DictionaryFormatterIdentifier.wordNetDataV1,
                transformerVersion: "1", outputSchemaVersion: 1,
                minimumConvertedEntryCount: 100_000,
                expectedEntryCount: 300_000,
                licenseIdentifier: "WordNet-3.0"
            ),
            AuditedOpenResourceSecurityMetadata(
                resourceID: "org.kaikki.zhwiktionary.en",
                resourceRevision: 20_260_806_085_640,
                version: "2026-08-06T08:56:40Z",
                downloadURL:
                    "https://kaikki.org/zhwiktionary/%E8%8B%B1%E8%AA%9E/" +
                    "kaikki.org-dictionary-%E8%8B%B1%E8%AA%9E.jsonl",
                downloadBytes: 60_047_743,
                sha256: "fb5a71b2e4fd71f9c752db242d15e028e80872d8c4cc069948d15ba2bf1d946f",
                catalogMetadataSHA256:
                    "f2d8f20f527b580d0b286e0219a5708af0a4281c354f185e1dc34e3cd38abd2c",
                officialDigestAlgorithm: "SHA-512",
                officialDigest:
                    "d00d86150aba906330cc81271bc285f4e938052cb3183c03ee3312ed791e62e4b" +
                    "6d89dd1f9928ac4a32902361247b9dbab5f94d13936abedc98467a99ba6ed33",
                transformerIdentifier:
                    DictionaryFormatterIdentifier.kaikkiWiktionaryJSONLV1,
                transformerVersion: "1", outputSchemaVersion: 1,
                minimumConvertedEntryCount: 50_000,
                expectedEntryCount: 100_000,
                licenseIdentifier: "CC-BY-SA-3.0 AND GFDL-1.3-or-later"
            )
        ]
        #if OPEN_RESOURCE_CONVERTER_TESTING
        values.append(AuditedOpenResourceSecurityMetadata(
            resourceID: "org.synthetic.cc-cedict.zh-en",
            resourceRevision: 1,
            version: "fixture-1",
            downloadURL:
                "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz",
            downloadBytes: 156,
            sha256: "dfe8fdb7bc5c2791e6a4c26b5792761a2510e3b502a37b14177ba58f17427c72",
            catalogMetadataSHA256: String(repeating: "e", count: 64),
            officialDigestAlgorithm: "SHA-256",
            officialDigest:
                "dfe8fdb7bc5c2791e6a4c26b5792761a2510e3b502a37b14177ba58f17427c72",
            transformerIdentifier: DictionaryFormatterIdentifier.ccCedictTextV1,
            transformerVersion: "1", outputSchemaVersion: 1,
            minimumConvertedEntryCount: 3,
            expectedEntryCount: 3,
            licenseIdentifier: "CC-BY-SA-4.0"
        ))
        #endif
        return Dictionary(uniqueKeysWithValues: values.map { ($0.resourceID, $0) })
    }()

    static func resource(id: String) -> AuditedOpenResourceSecurityMetadata? {
        records[id]
    }
}

/// Live official resources are versioned by their upstream directory, not by an App release.
/// Payload integrity is bound to the receipt produced after the actual download.
enum LiveOfficialOpenResourcePolicy {
    static func accepts(resourceID: String, formatterIdentifier: String) -> Bool {
        if formatterIdentifier == DictionaryFormatterIdentifier.freeDictStarDictV1 {
            guard resourceID.hasPrefix("org.freedict.live.") else { return false }
            let pair = resourceID.dropFirst("org.freedict.live.".count).split(separator: "-")
            return pair.count == 2 && pair.allSatisfy {
                $0.count == 3 && $0.allSatisfy { $0.isASCII && $0.isLetter }
            }
        }
        return resourceID == "org.cc-cedict.zh-en.live" &&
            formatterIdentifier == DictionaryFormatterIdentifier.ccCedictTextV1
    }

    static func accepts(resourceID: String, formatterIdentifier: String,
                        sourceURL: String) -> Bool {
        guard accepts(resourceID: resourceID,
                      formatterIdentifier: formatterIdentifier),
              let url = URL(string: sourceURL), url.scheme == "https" else { return false }
        if formatterIdentifier == DictionaryFormatterIdentifier.freeDictStarDictV1 {
            return url.host == "download.freedict.org"
        }
        return url.host == "cc-cedict.org"
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

/// Persisted result of the bounded post-index probe for an imported dictionary. This is only a
/// capability hint; the disposable reverse sidecar remains a separate, user-started operation.
enum DictionaryReverseCapabilityProbe: String, Codable, Equatable, Sendable {
    case supported
    case noUsableNativeGloss
    case unsupportedFormatter
    case unknown
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

struct DictionaryLookupDirection: Equatable, Hashable, Sendable {
    let sourceLanguageCode: String
    let targetLanguageCode: String
}

/// Language metadata derived from formatter identity. Unknown user imports remain unknown;
/// no dictionary body is inspected or rebuilt.
struct DictionaryLanguageCapability: Equatable, Sendable {
    let headwordLanguageCode: String?
    let definitionLanguageCodes: Set<String>
    let lookupDirections: Set<DictionaryLookupDirection>

    var isMonolingual: Bool {
        guard let headwordLanguageCode else { return false }
        return definitionLanguageCodes == [headwordLanguageCode]
    }

    var isBilingual: Bool {
        guard let headwordLanguageCode else { return false }
        return definitionLanguageCodes.contains { $0 != headwordLanguageCode }
    }

    func supportsDirectLookup(languageCode: String) -> Bool {
        headwordLanguageCode == languageCode && lookupDirections.contains {
            $0.sourceLanguageCode == languageCode
        }
    }

    func supportsReverseTo(languageCode: String) -> Bool {
        lookupDirections.contains {
            $0.targetLanguageCode == languageCode && $0.sourceLanguageCode != languageCode
        }
    }

    static let unknown = DictionaryLanguageCapability(
        headwordLanguageCode: nil, definitionLanguageCodes: [], lookupDirections: []
    )
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
    var reverseCapabilityProbe: DictionaryReverseCapabilityProbe? = nil
    /// Durable tombstone for a legacy registration removed from the product.  The referenced
    /// external MDX/MDD and legacy SQLite files remain outside App deletion authority.
    var retiredLegacyRegistrationAt: Date? = nil

    var id: String { dictionaryID }

    var isRetiredLegacyRegistration: Bool {
        sourceKind == .legacyReference && storageOwnership == .externalReference &&
            retiredLegacyRegistrationAt != nil
    }

    var languageCapability: DictionaryLanguageCapability {
        let en = "en"
        let zh = "zh-Hans"
        let enToEn = DictionaryLookupDirection(sourceLanguageCode: en, targetLanguageCode: en)
        let enToZH = DictionaryLookupDirection(sourceLanguageCode: en, targetLanguageCode: zh)
        let zhToEn = DictionaryLookupDirection(sourceLanguageCode: zh, targetLanguageCode: en)
        switch formatterIdentifier {
        case DictionaryFormatterIdentifier.century21V1,
             DictionaryFormatterIdentifier.medicalEnglishChineseV1,
             DictionaryFormatterIdentifier.freeDictStarDictV1,
             DictionaryFormatterIdentifier.kaikkiWiktionaryJSONLV1:
            return DictionaryLanguageCapability(
                headwordLanguageCode: en, definitionLanguageCodes: [en, zh],
                lookupDirections: [enToZH, zhToEn]
            )
        case DictionaryFormatterIdentifier.ccCedictTextV1:
            return DictionaryLanguageCapability(
                headwordLanguageCode: zh, definitionLanguageCodes: [en],
                lookupDirections: [zhToEn]
            )
        case DictionaryFormatterIdentifier.oxfordOALD8V1,
             DictionaryFormatterIdentifier.newOxfordV1,
             DictionaryFormatterIdentifier.affixRootAV1,
             DictionaryFormatterIdentifier.wordNetDataV1,
             DictionaryFormatterIdentifier.gcideMarkupV1:
            return DictionaryLanguageCapability(
                headwordLanguageCode: en, definitionLanguageCodes: [en],
                lookupDirections: [enToEn]
            )
        default:
            return .unknown
        }
    }

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
        if retiredLegacyRegistrationAt != nil {
            guard sourceKind == .legacyReference,
                  storageOwnership == .externalReference,
                  enabled == false,
                  state == .disabled else {
                throw DictionaryCatalogValidationError.invalidRetiredLegacyRegistration
            }
        }
        if sourceKind == .openResource {
            guard let openResourceMetadata else {
                throw DictionaryCatalogValidationError.invalidOpenResourceMetadata
            }
            try openResourceMetadata.validate(dictionaryID: dictionaryID)
            if DictionaryFormatterIdentifier.supportsOpenResourceSQLite(formatterIdentifier) {
                if let resource = AuditedOpenResourceSecurityRegistry.resource(
                    id: openResourceMetadata.resourceID
                ) {
                    guard resource.transformerIdentifier == formatterIdentifier,
                          openResourceMetadata.resourceRevision == resource.resourceRevision,
                          openResourceMetadata.resourceVersion == resource.version,
                          openResourceMetadata.manifestSHA256 == resource.catalogMetadataSHA256,
                          openResourceMetadata.payloadSHA256 == resource.sha256,
                          openResourceMetadata.payloadBytes == resource.downloadBytes,
                          openResourceMetadata.expectedEntryCount.minimum ==
                            resource.minimumConvertedEntryCount,
                          openResourceMetadata.expectedEntryCount.maximum ==
                            resource.expectedEntryCount,
                          openResourceMetadata.license.name == resource.licenseIdentifier else {
                        throw DictionaryCatalogValidationError.invalidOpenResourceMetadata
                    }
                } else if !LiveOfficialOpenResourcePolicy.accepts(
                    resourceID: openResourceMetadata.resourceID,
                    formatterIdentifier: formatterIdentifier
                ) {
                    throw DictionaryCatalogValidationError.invalidOpenResourceMetadata
                }
            }
            let expectedSource = DictionaryFormatterIdentifier
                .openResourceSourceComponent(formatterIdentifier).map {
                    "Dictionaries/\(dictionaryID)/\($0)"
                } ?? "Dictionaries/\(dictionaryID)/payload.mdx"
            let validSourceBinding = DictionaryFormatterIdentifier
                .supportsOpenResourceSQLite(formatterIdentifier)
                ? (relativePaths.dictionary == nil || relativePaths.dictionary == expectedSource)
                : relativePaths.dictionary == expectedSource
            guard validSourceBinding else {
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
        let positions = dictionaries.map(\.sortPosition)
        let hasUnifiedOrder = positions.allSatisfy { $0 > 0 } &&
            Set(positions).count == positions.count
        return dictionaries.sorted {
            if !hasUnifiedOrder, $0.queryLevel.rank != $1.queryLevel.rank {
                return $0.queryLevel.rank < $1.queryLevel.rank
            }
            if $0.sortPosition != $1.sortPosition {
                return $0.sortPosition < $1.sortPosition
            }
            return $0.dictionaryID < $1.dictionaryID
        }
    }

    /// Retired legacy tombstones participate in persistence but never in visible user ordering.
    var activeSortedDictionaries: [DictionaryDescriptor] {
        sortedDictionaries.filter { !$0.isRetiredLegacyRegistration }
    }

    func validated() throws -> DictionaryCatalog {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DictionaryCatalogValidationError.unsupportedSchemaVersion
        }
        var identifiers: Set<String> = []
        var openResourcesByID: [String: [DictionaryDescriptor]] = [:]
        for dictionary in dictionaries {
            try dictionary.validate()
            guard identifiers.insert(dictionary.dictionaryID).inserted else {
                throw DictionaryCatalogValidationError.duplicateDictionaryID
            }
            if let resourceID = dictionary.openResourceMetadata?.resourceID {
                openResourcesByID[resourceID, default: []].append(dictionary)
            }
        }
        for values in openResourcesByID.values where values.count > 1 {
            // A signed update may coexist with the current ready version only while the newer
            // descriptor is disabled and pending/indexing/failed (or ready but not yet switched).
            // This preserves the old query-eligible object until the new sealed index commits.
            guard values.count == 2,
                  let older = values.min(by: {
                      $0.openResourceMetadata!.resourceRevision <
                          $1.openResourceMetadata!.resourceRevision
                  }),
                  let newer = values.max(by: {
                      $0.openResourceMetadata!.resourceRevision <
                          $1.openResourceMetadata!.resourceRevision
                  }),
                  older.openResourceMetadata!.resourceRevision <
                      newer.openResourceMetadata!.resourceRevision,
                  older.queryLevel == .fallback,
                  newer.queryLevel == .fallback,
                  older.state == .ready,
                  older.sortPosition == newer.sortPosition,
                  (
                    (!newer.enabled &&
                     [.pendingIndex, .indexing, .failed, .ready].contains(newer.state)) ||
                    (!older.enabled && newer.enabled && newer.state == .ready)
                  )
            else {
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
    case invalidRetiredLegacyRegistration

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
        case .invalidRetiredLegacyRegistration:
            return "旧配置词典的退役登记无效。"
        }
    }
}
