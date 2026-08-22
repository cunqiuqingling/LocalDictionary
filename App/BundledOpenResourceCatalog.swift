import Foundation

enum OpenResourceSourceFormat: String, Codable, Equatable, Sendable {
    case freeDictStarDictTarXZ = "freedict-stardict-tar-xz"
    case ccCedictTextGZIP = "cc-cedict-text-gzip"
    case kaikkiWiktionaryJSONL = "kaikki-wiktionary-jsonl"
    case wordNetDataTarGZIP = "wordnet-data-tar-gzip"
    case gcideMarkupTarXZ = "gcide-markup-tar-xz"
}

/// Query/index behavior belongs to the audited resource type, not to a generic
/// "every dictionary has a forward and reverse index" assumption.
struct OpenResourceCapabilities: Equatable, Sendable {
    let supportsEnglishLookup: Bool
    let supportsChineseLookup: Bool
    let supportsChineseReverse: Bool
    let supportsEnglishDefinition: Bool
    let supportsSemanticRelations: Bool
    let requiresDerivedReverseIndex: Bool
}

/// Installation metadata shared by built-in resources and resources discovered from an official
/// upstream catalog. Live entries intentionally receive their payload SHA-256 after download.
struct BundledOpenResourceDefinition: Equatable, Sendable {
    let resourceID: String
    let resourceRevision: UInt64
    let title: String
    let summary: String
    let languageDisplay: String
    let category: String
    let publisher: String
    let redistributionStatement: String
    let sourceLanguage: String
    let targetLanguage: String
    let version: String
    let sourceFormat: OpenResourceSourceFormat
    let downloadURL: URL
    let downloadBytes: UInt64
    let maximumExpandedBytes: UInt64
    let maximumEntries: UInt64
    let maximumEntryBytes: UInt64
    let sha256: String
    let officialDigestAlgorithm: String
    let officialDigest: String
    let digestProvenance: String
    let licenseIdentifier: String
    let licenseVersion: String
    let licenseURL: URL
    let attribution: String
    let sourceProject: URL
    let officialDownloadPage: URL
    let transformerIdentifier: String
    let transformerVersion: String
    let outputSchemaVersion: Int
    let minimumAppVersion: String
    let expectedEntryCount: UInt64
    let minimumConvertedEntryCount: UInt64
    let catalogMetadataSHA256: String
    let archiveMembers: [String: UInt64]
    let capabilities: DictionaryCapabilities
    let openResourceCapabilities: OpenResourceCapabilities

    var allowedHost: String { downloadURL.host ?? "" }
    var languages: [String] { [sourceLanguage, targetLanguage] }
    var sourceFileName: String { downloadURL.lastPathComponent }

    var languageCapability: DictionaryLanguageCapability {
        let source = Self.normalizedLanguageCode(sourceLanguage)
        let target = Self.normalizedLanguageCode(targetLanguage)
        let directions: Set<DictionaryLookupDirection>
        if let source, let target {
            directions = [DictionaryLookupDirection(
                sourceLanguageCode: source, targetLanguageCode: target
            )]
        } else {
            directions = []
        }
        return DictionaryLanguageCapability(
            headwordLanguageCode: source,
            definitionLanguageCodes: Set([target].compactMap { $0 }),
            lookupDirections: directions
        )
    }

    func isRecommended(nativeLanguageCode: String,
                       learningLanguageCode: String) -> Bool {
        let capability = languageCapability
        return capability.lookupDirections.contains {
            ($0.sourceLanguageCode == learningLanguageCode &&
                $0.targetLanguageCode == nativeLanguageCode) ||
            ($0.sourceLanguageCode == nativeLanguageCode &&
                $0.targetLanguageCode == learningLanguageCode) ||
            ($0.sourceLanguageCode == learningLanguageCode &&
                $0.targetLanguageCode == learningLanguageCode)
        }
    }

    private static func normalizedLanguageCode(_ resourceCode: String) -> String? {
        switch resourceCode.lowercased() {
        case "zh", "zh-hans", "zho": return "zh-Hans"
        case "en", "eng": return "en"
        case "de", "deu", "ger": return "de"
        case "ja", "jpn": return "ja"
        case "fr", "fra", "fre": return "fr"
        case "es", "spa": return "es"
        case "it", "ita": return "it"
        case "pt", "por": return "pt"
        case "ru", "rus": return "ru"
        case "ko", "kor": return "ko"
        case "nl", "nld", "dut": return "nl"
        case "pl", "pol": return "pl"
        case "sv", "swe": return "sv"
        case "fi", "fin": return "fi"
        default: return nil
        }
    }
}

enum BundledOpenResourceCatalog {
    static let freeDictEnglishChinese = BundledOpenResourceDefinition(
        resourceID: FreeDictStarterSecurityConstants.resourceID,
        resourceRevision: FreeDictStarterSecurityConstants.resourceRevision,
        title: "FreeDict英中词典",
        summary: "FreeDict/WikDict 英语→中文开放词典，固定官方版本。",
        languageDisplay: "英语 → 中文",
        category: "双语词典",
        publisher: "FreeDict / WikDict",
        redistributionStatement: "资源由用户主动从 FreeDict 官方固定地址下载；App 不重新托管词典正文。",
        sourceLanguage: "en",
        targetLanguage: "zh",
        version: FreeDictStarterSecurityConstants.version,
        sourceFormat: .freeDictStarDictTarXZ,
        downloadURL: URL(string: FreeDictStarterSecurityConstants.sourceURL)!,
        downloadBytes: FreeDictStarterSecurityConstants.sourceBytes,
        maximumExpandedBytes: 16 * 1024 * 1024,
        maximumEntries: 30_000,
        maximumEntryBytes: 64 * 1024,
        sha256: FreeDictStarterSecurityConstants.sourceSHA256,
        officialDigestAlgorithm: "SHA-512",
        officialDigest: FreeDictStarterSecurityConstants.officialSHA512,
        digestProvenance: "FreeDict 官方 SHA-512",
        licenseIdentifier: "CC-BY-SA-3.0",
        licenseVersion: "3.0",
        licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/3.0/legalcode")!,
        attribution: "English-中文 FreeDict+WikDict dictionary；FreeDict、WikDict、" +
            "Wiktionary/DBnary contributors；Karl Bartel（publisher）。",
        sourceProject: URL(string: "https://freedict.org/")!,
        officialDownloadPage: URL(string:
            "https://download.freedict.org/dictionaries/eng-zho/2025.11.23/")!,
        transformerIdentifier: DictionaryFormatterIdentifier.freeDictStarDictV1,
        transformerVersion: FreeDictStarterSecurityConstants.transformerVersion,
        outputSchemaVersion: FreeDictStarterSecurityConstants.outputSchemaVersion,
        minimumAppVersion: "0.1",
        expectedEntryCount: FreeDictStarterSecurityConstants.sourceEntryCount,
        minimumConvertedEntryCount:
            FreeDictStarterSecurityConstants.minimumConvertedEntryCount,
        catalogMetadataSHA256: FreeDictStarterSecurityConstants.catalogMetadataSHA256,
        archiveMembers: [
            "eng-zho/eng-zho.ifo": 880,
            "eng-zho/eng-zho.idx.gz": 250_058,
            "eng-zho/eng-zho.dict": 8_124_281,
            "eng-zho/README": 0,
            "eng-zho/COPYING": 22_459,
            "eng-zho/INSTALL": 4_560
        ],
        capabilities: DictionaryCapabilities(
            englishLookup: true, chineseLookup: true, bilingualDefinitions: true,
            pronunciations: false, examples: false, synonyms: false, antonyms: false,
            morphology: false, semanticRelations: false
        ),
        openResourceCapabilities: OpenResourceCapabilities(
            supportsEnglishLookup: true, supportsChineseLookup: true,
            supportsChineseReverse: true, supportsEnglishDefinition: false,
            supportsSemanticRelations: false, requiresDerivedReverseIndex: true
        )
    )

    static let ccCedictChineseEnglish = BundledOpenResourceDefinition(
        resourceID: "org.cc-cedict.zh-en",
        resourceRevision: 20_260_808_091_604,
        title: "CC-CEDICT中英词典",
        summary: "MDBG 发布的 CC-CEDICT 中文→英语社区词典固定快照。",
        languageDisplay: "中文 → 英语",
        category: "双语词典",
        publisher: "CC-CEDICT / MDBG",
        redistributionStatement: "用户点击后从 MDBG 官方下载页的固定导出地址获取；App 不重新托管正文。",
        sourceLanguage: "zh",
        targetLanguage: "en",
        version: "2026-08-08T09:16:04Z",
        sourceFormat: .ccCedictTextGZIP,
        downloadURL: URL(string:
            "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz")!,
        downloadBytes: 3_967_111,
        maximumExpandedBytes: 16 * 1024 * 1024,
        maximumEntries: 300_000,
        maximumEntryBytes: 64 * 1024,
        sha256: "1fe09c26e17ab52eceb2be2988f9c89b13c9b2b010e27325e97c2d0664c65701",
        officialDigestAlgorithm: "SHA-256",
        officialDigest:
            "1fe09c26e17ab52eceb2be2988f9c89b13c9b2b010e27325e97c2d0664c65701",
        digestProvenance: "LocalDictionary 受控下载复核（上游未发布摘要）",
        licenseIdentifier: "CC-BY-SA-4.0",
        licenseVersion: "4.0",
        licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/legalcode")!,
        attribution: "CC-CEDICT contributors；MDBG（publisher）；原始 CEDICT：" +
            "Paul Andrew Denisowski。",
        sourceProject: URL(string: "https://cc-cedict.org/")!,
        officialDownloadPage: URL(string:
            "https://www.mdbg.net/chinese/dictionary?page=cc-cedict")!,
        transformerIdentifier: DictionaryFormatterIdentifier.ccCedictTextV1,
        transformerVersion: "1",
        outputSchemaVersion: 1,
        minimumAppVersion: "0.1",
        expectedEntryCount: 250_000,
        minimumConvertedEntryCount: 120_000,
        catalogMetadataSHA256:
            "67c47c9c8c3f2dde52a3318ab4d53b71fb449cd61a240390d17a83560b512fe6",
        archiveMembers: [:],
        capabilities: DictionaryCapabilities(
            englishLookup: false, chineseLookup: true, bilingualDefinitions: true,
            pronunciations: true, examples: false, synonyms: false, antonyms: false,
            morphology: false, semanticRelations: false
        ),
        openResourceCapabilities: OpenResourceCapabilities(
            supportsEnglishLookup: false, supportsChineseLookup: true,
            supportsChineseReverse: false, supportsEnglishDefinition: true,
            supportsSemanticRelations: false, requiresDerivedReverseIndex: false
        )
    )

    static let gcideEnglish = BundledOpenResourceDefinition(
        resourceID: "org.gnu.gcide.en",
        resourceRevision: 54,
        title: "GNU GCIDE英英词典",
        summary: "GNU Collaborative International Dictionary of English 0.54 固定版本。",
        languageDisplay: "英语 · 英英释义",
        category: "单语词典",
        publisher: "GNU Project / GCIDE",
        redistributionStatement: "用户点击后从 GNU 官方 HTTPS 归档下载；App 不重新托管正文。",
        sourceLanguage: "en",
        targetLanguage: "en",
        version: "0.54",
        sourceFormat: .gcideMarkupTarXZ,
        downloadURL: URL(string: "https://ftp.gnu.org/gnu/gcide/gcide-0.54.tar.xz")!,
        downloadBytes: 14_803_080,
        maximumExpandedBytes: 128 * 1024 * 1024,
        maximumEntries: 300_000,
        maximumEntryBytes: 1024 * 1024,
        sha256: "22416f6f36175b160dc388b7547512514d464473cf7d7c898d738efb26c51d42",
        officialDigestAlgorithm: "SHA-512",
        officialDigest:
            "9bda8bc2e30a529bafeb3fcdd2f315025209fa2e609da707caf7b4a273221a761" +
            "7a10b58d2b635e1ae980e01a790a4e09bb74ec54d6e09c9014e72b30d33b1e6",
        digestProvenance: "LocalDictionary 受控下载复核",
        licenseIdentifier: "GPL-3.0-or-later",
        licenseVersion: "3.0-or-later",
        licenseURL: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!,
        attribution: "GNU Collaborative International Dictionary of English contributors；" +
            "GCIDE release 0.54。",
        sourceProject: URL(string: "https://www.gnu.org/software/gcide/")!,
        officialDownloadPage: URL(string: "https://ftp.gnu.org/gnu/gcide/")!,
        transformerIdentifier: DictionaryFormatterIdentifier.gcideMarkupV1,
        transformerVersion: "1",
        outputSchemaVersion: 1,
        minimumAppVersion: "0.1",
        expectedEntryCount: 250_000,
        minimumConvertedEntryCount: 100_000,
        catalogMetadataSHA256:
            "66e4e3c8bce8e50897653e549e1e88ff258682437f2dae7cc2521639c355a16d",
        archiveMembers: [:],
        capabilities: DictionaryCapabilities(
            englishLookup: true, chineseLookup: false, bilingualDefinitions: false,
            pronunciations: true, examples: true, synonyms: true, antonyms: true,
            morphology: true, semanticRelations: false
        ),
        openResourceCapabilities: OpenResourceCapabilities(
            supportsEnglishLookup: true, supportsChineseLookup: false,
            supportsChineseReverse: false, supportsEnglishDefinition: true,
            supportsSemanticRelations: false, requiresDerivedReverseIndex: false
        )
    )

    static let wordNetEnglish = BundledOpenResourceDefinition(
        resourceID: "org.princeton.wordnet.en",
        resourceRevision: 30,
        title: "Princeton WordNet英语语义词库",
        summary: "Princeton WordNet 3.0 固定数据库归档，提供英语词义和语义关系。",
        languageDisplay: "英语 · 语义关系",
        category: "语义词库",
        publisher: "Princeton University",
        redistributionStatement:
            "用户点击后从 Princeton 官方 HTTPS 固定归档下载；保留许可证通知，App 不重新托管正文。",
        sourceLanguage: "en",
        targetLanguage: "en",
        version: "3.0",
        sourceFormat: .wordNetDataTarGZIP,
        downloadURL: URL(string:
            "https://wordnetcode.princeton.edu/3.0/WNdb-3.0.tar.gz")!,
        downloadBytes: 10_518_425,
        maximumExpandedBytes: 64 * 1024 * 1024,
        maximumEntries: 350_000,
        maximumEntryBytes: 64 * 1024,
        sha256: "658b1ba191f5f98c2e9bae3e25c186013158f30ef779f191d2a44e5d25046dc8",
        officialDigestAlgorithm: "SHA-512",
        officialDigest:
            "41e177167fa80fa9c26c8002b2783d2bcffa2622b9fec6d5f446ef498b214197" +
            "3489020b7dce928cce5ce14e6cc5606c7cbb4678e1f069acf907f64f3a38c730",
        digestProvenance: "LocalDictionary 受控下载复核（上游未发布摘要）",
        licenseIdentifier: "WordNet-3.0",
        licenseVersion: "3.0",
        licenseURL: URL(string: "https://wordnet.princeton.edu/license-and-commercial-use")!,
        attribution:
            "WordNet 3.0；Princeton University；Copyright 2006 Princeton University。",
        sourceProject: URL(string: "https://wordnet.princeton.edu/")!,
        officialDownloadPage: URL(string: "https://wordnetcode.princeton.edu/3.0/")!,
        transformerIdentifier: DictionaryFormatterIdentifier.wordNetDataV1,
        transformerVersion: "1",
        outputSchemaVersion: 1,
        minimumAppVersion: "0.1",
        expectedEntryCount: 300_000,
        minimumConvertedEntryCount: 100_000,
        catalogMetadataSHA256:
            "e499c439c98cae0cc25717ff383eb443fea66d51ca4fa68e83da00214293782c",
        archiveMembers: [
            "data.adj": 3_155_426,
            "data.adv": 516_696,
            "data.noun": 15_300_280,
            "data.verb": 2_772_517
        ],
        capabilities: DictionaryCapabilities(
            englishLookup: true, chineseLookup: false, bilingualDefinitions: false,
            pronunciations: false, examples: true, synonyms: true, antonyms: true,
            morphology: false, semanticRelations: true
        ),
        openResourceCapabilities: OpenResourceCapabilities(
            supportsEnglishLookup: true, supportsChineseLookup: false,
            supportsChineseReverse: false, supportsEnglishDefinition: true,
            supportsSemanticRelations: true, requiresDerivedReverseIndex: false
        )
    )

    static let kaikkiChineseWiktionaryEnglish = BundledOpenResourceDefinition(
        resourceID: "org.kaikki.zhwiktionary.en",
        resourceRevision: 20_260_806_085_640,
        title: "Kaikki中文维基词典·英语条目",
        summary: "Kaikki/Wiktextract 从中文维基词典提取的英语条目固定 JSONL 快照。",
        languageDisplay: "英语 → 中文",
        category: "社区词典",
        publisher: "Kaikki.org / 中文维基词典",
        redistributionStatement:
            "用户点击后从 Kaikki 官方固定快照下载；遵守维基词典署名与相同方式共享要求。",
        sourceLanguage: "en",
        targetLanguage: "zh",
        version: "2026-08-06T08:56:40Z",
        sourceFormat: .kaikkiWiktionaryJSONL,
        downloadURL: URL(string:
            "https://kaikki.org/zhwiktionary/%E8%8B%B1%E8%AA%9E/" +
            "kaikki.org-dictionary-%E8%8B%B1%E8%AA%9E.jsonl")!,
        downloadBytes: 60_047_743,
        maximumExpandedBytes: 64 * 1024 * 1024,
        maximumEntries: 150_000,
        maximumEntryBytes: 1024 * 1024,
        sha256: "fb5a71b2e4fd71f9c752db242d15e028e80872d8c4cc069948d15ba2bf1d946f",
        officialDigestAlgorithm: "SHA-512",
        officialDigest:
            "d00d86150aba906330cc81271bc285f4e938052cb3183c03ee3312ed791e62e4b" +
            "6d89dd1f9928ac4a32902361247b9dbab5f94d13936abedc98467a99ba6ed33",
        digestProvenance: "LocalDictionary 受控下载复核（上游未发布摘要）",
        licenseIdentifier: "CC-BY-SA-3.0 AND GFDL-1.3-or-later",
        licenseVersion: "dual",
        licenseURL: URL(string: "https://kaikki.org/zhwiktionary/\u{82f1}\u{8a9e}/")!,
        attribution:
            "中文维基词典贡献者；Wiktextract/Kaikki.org；Tatu Ylonen。",
        sourceProject: URL(string: "https://kaikki.org/zhwiktionary/\u{82f1}\u{8a9e}/")!,
        officialDownloadPage:
            URL(string: "https://kaikki.org/zhwiktionary/\u{82f1}\u{8a9e}/")!,
        transformerIdentifier: DictionaryFormatterIdentifier.kaikkiWiktionaryJSONLV1,
        transformerVersion: "1",
        outputSchemaVersion: 1,
        minimumAppVersion: "0.1",
        expectedEntryCount: 100_000,
        minimumConvertedEntryCount: 50_000,
        catalogMetadataSHA256:
            "f2d8f20f527b580d0b286e0219a5708af0a4281c354f185e1dc34e3cd38abd2c",
        archiveMembers: [:],
        capabilities: DictionaryCapabilities(
            englishLookup: true, chineseLookup: true, bilingualDefinitions: true,
            pronunciations: false, examples: true, synonyms: true, antonyms: true,
            morphology: true, semanticRelations: false
        ),
        openResourceCapabilities: OpenResourceCapabilities(
            supportsEnglishLookup: true, supportsChineseLookup: true,
            supportsChineseReverse: true, supportsEnglishDefinition: false,
            supportsSemanticRelations: false, requiresDerivedReverseIndex: true
        )
    )

    private static let auditedResources: [BundledOpenResourceDefinition] = {
        let values = [freeDictEnglishChinese, ccCedictChineseEnglish,
                      kaikkiChineseWiktionaryEnglish, wordNetEnglish, gcideEnglish]
        precondition(values.allSatisfy { value in
            guard let security = AuditedOpenResourceSecurityRegistry.resource(
                id: value.resourceID
            ) else { return false }
            return value.resourceRevision == security.resourceRevision &&
                value.version == security.version &&
                value.downloadURL.absoluteString == security.downloadURL &&
                value.downloadBytes == security.downloadBytes &&
                value.sha256 == security.sha256 &&
                value.catalogMetadataSHA256 == security.catalogMetadataSHA256 &&
                value.officialDigestAlgorithm == security.officialDigestAlgorithm &&
                value.officialDigest == security.officialDigest &&
                value.transformerIdentifier == security.transformerIdentifier &&
                value.transformerVersion == security.transformerVersion &&
                value.outputSchemaVersion == security.outputSchemaVersion &&
                value.minimumConvertedEntryCount == security.minimumConvertedEntryCount &&
                value.expectedEntryCount == security.expectedEntryCount &&
                value.licenseIdentifier == security.licenseIdentifier &&
                value.maximumEntries >= value.expectedEntryCount &&
                value.maximumEntryBytes >= 16 * 1024
        }, "Bundled resource presentation drifted from its security registry")
        return values
    }()

    /// Monolingual references remain available without discovery. Bilingual resources are
    /// supplied at runtime for the active Native/Learning pair.
    static let resources: [BundledOpenResourceDefinition] = [
        wordNetEnglish,
        gcideEnglish
    ]

    static let hiddenStarterResourceIDs: Set<String> = [
        ccCedictChineseEnglish.resourceID,
        kaikkiChineseWiktionaryEnglish.resourceID
    ]

    static func resource(id: String) -> BundledOpenResourceDefinition? {
        auditedResources.first { $0.resourceID == id }
    }

    static func capabilities(resourceID: String) -> OpenResourceCapabilities? {
        if let known = resource(id: resourceID) { return known.openResourceCapabilities }
        if resourceID == "org.cc-cedict.zh-en.live" {
            return OpenResourceCapabilities(
                supportsEnglishLookup: false, supportsChineseLookup: true,
                supportsChineseReverse: false, supportsEnglishDefinition: true,
                supportsSemanticRelations: false, requiresDerivedReverseIndex: false
            )
        }
        guard resourceID.hasPrefix("org.freedict.live.") else { return nil }
        let pair = resourceID.dropFirst("org.freedict.live.".count).split(separator: "-")
        guard pair.count == 2 else { return nil }
        let source = String(pair[0]), target = String(pair[1])
        return OpenResourceCapabilities(
            supportsEnglishLookup: source == "eng", supportsChineseLookup: source == "zho",
            supportsChineseReverse: source == "eng" && target == "zho",
            supportsEnglishDefinition: target == "eng", supportsSemanticRelations: false,
            requiresDerivedReverseIndex: source == "eng" && target == "zho"
        )
    }

    static func starterResource(id: String) -> BundledOpenResourceDefinition? {
        resources.first { $0.resourceID == id }
    }
}

extension OpenResourceInstallationIdentity {
    init(starter resource: BundledOpenResourceDefinition,
         dictionaryID: String = UUID().uuidString.lowercased(),
         installedAt: Date = Date()) throws {
        try self.init(
            dictionaryID: dictionaryID,
            resourceID: resource.resourceID,
            resourceRevision: resource.resourceRevision,
            resourceVersion: resource.version,
            manifestVersion: 1,
            manifestSHA256: resource.catalogMetadataSHA256,
            verifiedKeyID: "bundled-starter-v1",
            payloadSHA256: resource.sha256,
            payloadBytes: resource.downloadBytes,
            languages: resource.languages,
            license: OpenResourceLicenseMetadata(
                name: resource.licenseIdentifier,
                version: resource.licenseVersion,
                url: resource.licenseURL.absoluteString,
                attribution: resource.attribution
            ),
            sourceProject: resource.sourceProject.absoluteString,
            officialPageReference: resource.officialDownloadPage.absoluteString,
            expectedEntryCount: OpenResourceEntryCountMetadata(
                minimum: resource.minimumConvertedEntryCount,
                maximum: resource.expectedEntryCount
            ),
            installedAt: installedAt,
            formatterIdentifier: resource.transformerIdentifier,
            displayName: resource.title
        )
    }
}

#if !OPEN_RESOURCE_CONVERTER_TESTING
extension ResourcePayloadDownloadPlanBuilder {
    static func build(starter resource: BundledOpenResourceDefinition,
                      applicationAllowedHosts: [String],
                      stagingRoot: URL,
                      policy: ResourcePayloadDownloadPolicy,
                      dictionaryID: String = UUID().uuidString.lowercased(),
                      installedAt: Date = Date()) throws -> ResourcePayloadDownloadPlan {
        guard policy.applicationAllowedHosts == applicationAllowedHosts,
              applicationAllowedHosts.contains(resource.allowedHost),
              !resource.allowedHost.isEmpty,
              resource.downloadURL.scheme == "https",
              resource.downloadBytes > 0,
              resource.downloadBytes <= policy.applicationHardLimit,
              OpenResourceInstallationMetadata.isSHA256(resource.sha256) else {
            throw ResourcePayloadDownloadError.disabledConfiguration
        }
        let urlPolicy = try ResourceNetworkURLPolicy(pinnedAllowedHosts: [resource.allowedHost])
        let url = try urlPolicy.validateInitialURL(resource.downloadURL.absoluteString)
        let identity = try OpenResourceInstallationIdentity(
            starter: resource, dictionaryID: dictionaryID, installedAt: installedAt
        )
        return ResourcePayloadDownloadPlan(
            resourceID: resource.resourceID,
            resourceRevision: resource.resourceRevision,
            downloadURL: url,
            signedFileName: resource.sourceFileName,
            expectedBytes: resource.downloadBytes,
            maximumBytes: resource.downloadBytes,
            expectedSHA256: resource.sha256,
            allowedHosts: [resource.allowedHost],
            stagingRoot: stagingRoot.standardizedFileURL,
            policy: policy,
            installationIdentity: identity
        )
    }
}
#endif
