import CryptoKit
import Foundation

enum OfficialOpenResourceDiscoveryError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidResponse
    case invalidCatalog
    case noMatchingResource
    case downloadFailed
    case payloadTooLarge
    case digestMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable: return "暂时无法连接开放词典官方目录。"
        case .invalidResponse: return "开放词典官方目录返回了无效响应。"
        case .invalidCatalog: return "开放词典官方目录格式无效。"
        case .noMatchingResource: return "当前母语与学习语言暂未匹配到可安装的双语词典。"
        case .downloadFailed: return "开放词典下载未完成。"
        case .payloadTooLarge: return "开放词典文件超过本机允许的大小。"
        case .digestMismatch: return "开放词典与官方目录提供的校验值不一致。"
        }
    }
}

/// Fetches the official FreeDict API each time Resource Center refreshes.  This is deliberately
/// small: matching comes from the current Native/Learning pair and release metadata comes from
/// upstream, instead of compiling a release number, byte count, or payload hash into the app.
actor OfficialOpenResourceDiscoveryClient {
    static let freeDictCatalogURL = URL(string: "https://freedict.org/freedict-database.json")!

    private let session: URLSession
    private let catalogURL: URL

    init(session: URLSession = .shared,
         catalogURL: URL = OfficialOpenResourceDiscoveryClient.freeDictCatalogURL) {
        self.session = session
        self.catalogURL = catalogURL
    }

    func discover(nativeLanguageCode: String,
                  learningLanguageCode: String) async throws
        -> [BundledOpenResourceDefinition] {
        guard catalogURL.scheme == "https", catalogURL.host == "freedict.org" else {
            throw OfficialOpenResourceDiscoveryError.invalidCatalog
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: catalogURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OfficialOpenResourceDiscoveryError.unavailable
        }
        guard data.count <= 4 * 1024 * 1024,
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.url?.scheme == "https", http.url?.host == "freedict.org" else {
            throw OfficialOpenResourceDiscoveryError.invalidResponse
        }
        return try Self.resources(
            from: data,
            nativeLanguageCode: nativeLanguageCode,
            learningLanguageCode: learningLanguageCode
        )
    }

    /// Pure parser shared by production and synthetic tests.
    static func resources(from data: Data,
                          nativeLanguageCode: String,
                          learningLanguageCode: String) throws
        -> [BundledOpenResourceDefinition] {
        let records: [FreeDictRecord]
        do {
            records = try JSONDecoder().decode([FreeDictRecord].self, from: data)
        } catch {
            throw OfficialOpenResourceDiscoveryError.invalidCatalog
        }
        let native = Self.iso6393(nativeLanguageCode)
        let learning = Self.iso6393(learningLanguageCode)
        guard native != learning else {
            throw OfficialOpenResourceDiscoveryError.noMatchingResource
        }
        let wanted = Set(["\(learning)-\(native)", "\(native)-\(learning)"])
        var resources = records.compactMap { record -> BundledOpenResourceDefinition? in
            guard let name = record.name, wanted.contains(name.lowercased()),
                  let release = record.releases
                    .filter({ $0.platform == "stardict" })
                    .sorted(by: { Self.releaseSortKey($0) > Self.releaseSortKey($1) })
                    .first else { return nil }
            return Self.makeFreeDictResource(record: record, release: release)
        }
        // CC-CEDICT is an official continuously updated Chinese→English source.  It has no
        // release hash API; the payload is therefore hashed locally after download and the
        // resulting digest is stored in the installation receipt.  It is only offered for the
        // matching language pair, never as a global static recommendation. Use the project
        // editor's export endpoint instead of automating the MDBG public dictionary UI.
        if Set([native, learning]) == Set(["zho", "eng"]) {
            resources.append(Self.makeLiveCCCEDICTResource())
        }
        guard !resources.isEmpty else {
            throw OfficialOpenResourceDiscoveryError.noMatchingResource
        }
        return resources.sorted {
            if $0.sourceLanguage == learning && $1.sourceLanguage != learning { return true }
            if $0.sourceLanguage != learning && $1.sourceLanguage == learning { return false }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private struct FreeDictRecord: Decodable {
        let edition: String?
        let headwords: String?
        let name: String?
        let releases: [FreeDictRelease]
        let status: String?

        private enum CodingKeys: String, CodingKey {
            case edition, headwords, name, releases, status
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            edition = values.flexibleString(forKey: .edition)
            headwords = values.flexibleString(forKey: .headwords)
            name = values.flexibleString(forKey: .name)
            status = values.flexibleString(forKey: .status)
            releases = (try? values.decode([FreeDictRelease].self, forKey: .releases)) ?? []
        }
    }

    private struct FreeDictRelease: Decodable {
        let URL: String?
        let checksum: String?
        let date: String?
        let platform: String?
        let size: String?
        let version: String?

        private enum CodingKeys: String, CodingKey {
            case URL, checksum, date, platform, size, version
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            URL = values.flexibleString(forKey: .URL)
            checksum = values.flexibleString(forKey: .checksum)
            date = values.flexibleString(forKey: .date)
            platform = values.flexibleString(forKey: .platform)
            size = values.flexibleString(forKey: .size)
            version = values.flexibleString(forKey: .version)
        }
    }

    private static func makeFreeDictResource(record: FreeDictRecord,
                                             release: FreeDictRelease)
        -> BundledOpenResourceDefinition? {
        guard let name = record.name,
              let releaseURL = release.URL,
              let checksum = release.checksum,
              let size = release.size else { return nil }
        let components = name.lowercased().split(separator: "-")
        guard components.count == 2,
              let url = URL(string: releaseURL), url.scheme == "https",
              url.host == "download.freedict.org",
              checksum.count == 128,
              checksum.allSatisfy({ $0.isHexDigit }),
              let bytes = UInt64(size), bytes > 0,
              bytes <= 128 * 1024 * 1024 else { return nil }
        let source = String(components[0])
        let target = String(components[1])
        let entries = record.headwords.flatMap(UInt64.init) ?? 0
        guard entries > 0 else { return nil }
        let version = release.version ?? record.edition ?? "current"
        let revision = revisionNumber(release.date ?? "", fallback: version)
        let metadataDigest = sha256(
            "\(name)|\(version)|\(releaseURL)|\(checksum)"
        )
        return BundledOpenResourceDefinition(
            resourceID: "org.freedict.live.\(name.lowercased())",
            resourceRevision: revision,
            title: "FreeDict \(displayName(source)) → \(displayName(target))",
            summary: "按当前语言组合从 FreeDict 官方目录实时匹配的双语词典。",
            languageDisplay: "\(displayName(source)) → \(displayName(target))",
            category: "双语词典",
            publisher: "FreeDict",
            redistributionStatement: "用户主动从 FreeDict 官方地址下载；具体数据许可见资源详情与词典包内说明。",
            sourceLanguage: source,
            targetLanguage: target,
            version: version,
            sourceFormat: .freeDictStarDictTarXZ,
            downloadURL: url,
            downloadBytes: bytes,
            maximumExpandedBytes: min(512 * 1024 * 1024, max(16 * 1024 * 1024, bytes * 24)),
            maximumEntries: max(entries + max(1_000, entries / 4), entries),
            maximumEntryBytes: 128 * 1024,
            sha256: "",
            officialDigestAlgorithm: "SHA-512",
            officialDigest: checksum.lowercased(),
            digestProvenance: "FreeDict 实时官方目录",
            licenseIdentifier: "FreeDict source-specific open license",
            licenseVersion: "",
            licenseURL: URL(string: "https://freedict.org/documentation/")!,
            attribution: "FreeDict contributors；具体作者与许可见下载词典包。",
            sourceProject: URL(string: "https://freedict.org/")!,
            officialDownloadPage: url.deletingLastPathComponent(),
            transformerIdentifier: DictionaryFormatterIdentifier.freeDictStarDictV1,
            transformerVersion: "2",
            outputSchemaVersion: 1,
            minimumAppVersion: "0.1",
            expectedEntryCount: entries,
            minimumConvertedEntryCount: max(1, min(entries, entries * 7 / 10)),
            catalogMetadataSHA256: metadataDigest,
            archiveMembers: [:],
            capabilities: DictionaryCapabilities(
                englishLookup: source == "eng", chineseLookup: source == "zho",
                bilingualDefinitions: true, pronunciations: false, examples: false,
                synonyms: false, antonyms: false, morphology: false,
                semanticRelations: false
            ),
            openResourceCapabilities: OpenResourceCapabilities(
                supportsEnglishLookup: source == "eng",
                supportsChineseLookup: source == "zho",
                supportsChineseReverse: source == "eng" && target == "zho",
                supportsEnglishDefinition: target == "eng",
                supportsSemanticRelations: false,
                requiresDerivedReverseIndex: source == "eng" && target == "zho"
            )
        )
    }

    private static func makeLiveCCCEDICTResource() -> BundledOpenResourceDefinition {
        let url = URL(string:
            "https://cc-cedict.org/editor/editor_export_cedict.php?c=gz"
        )!
        return BundledOpenResourceDefinition(
            resourceID: "org.cc-cedict.zh-en.live", resourceRevision: 1,
            title: "CC-CEDICT 中文 → English",
            summary: "按当前中英语言组合提供的 CC-CEDICT 官方实时编辑版。",
            languageDisplay: "简体中文 → English", category: "双语词典",
            publisher: "CC-CEDICT",
            redistributionStatement: "用户主动从 CC-CEDICT 官方当前导出地址下载；App 不重新托管正文。",
            sourceLanguage: "zh", targetLanguage: "en", version: "current",
            sourceFormat: .ccCedictTextGZIP, downloadURL: url,
            downloadBytes: 0, maximumExpandedBytes: 64 * 1024 * 1024,
            maximumEntries: 400_000, maximumEntryBytes: 64 * 1024, sha256: "",
            officialDigestAlgorithm: "LOCAL-SHA-256", officialDigest: "",
            digestProvenance: "下载后本机计算并写入安装凭据",
            licenseIdentifier: "CC-BY-SA-4.0", licenseVersion: "4.0",
            licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/legalcode")!,
            attribution: "CC-CEDICT contributors；MDBG；Paul Andrew Denisowski。",
            sourceProject: URL(string: "https://cc-cedict.org/")!,
            officialDownloadPage: URL(string:
                "https://cc-cedict.org/editor/editor.php?handler=Download")!,
            transformerIdentifier: DictionaryFormatterIdentifier.ccCedictTextV1,
            transformerVersion: "2", outputSchemaVersion: 1,
            minimumAppVersion: "0.1", expectedEntryCount: 250_000,
            minimumConvertedEntryCount: 100_000,
            catalogMetadataSHA256: sha256("cc-cedict|official-current|zh-en"),
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
    }

    private static func iso6393(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-hans", "zho": return "zho"
        case "en", "eng": return "eng"
        case "de", "deu", "ger": return "deu"
        case "ja", "jpn": return "jpn"
        case "fr", "fra", "fre": return "fra"
        case "es", "spa": return "spa"
        case "it", "ita": return "ita"
        case "pt", "por": return "por"
        case "ru", "rus": return "rus"
        case "ko", "kor": return "kor"
        case "nl", "nld", "dut": return "nld"
        case "pl", "pol": return "pol"
        case "sv", "swe": return "swe"
        case "fi", "fin": return "fin"
        default: return code.lowercased().split(separator: "-").first.map(String.init) ?? code
        }
    }

    private static func displayName(_ code: String) -> String {
        switch code {
        case "zho": return "简体中文"
        case "eng": return "English"
        case "deu": return "Deutsch"
        case "jpn": return "日本語"
        case "fra": return "Français"
        case "spa": return "Español"
        case "ita": return "Italiano"
        case "por": return "Português"
        case "rus": return "Русский"
        case "kor": return "한국어"
        default: return code
        }
    }

    private static func releaseSortKey(_ release: FreeDictRelease) -> String {
        "\(release.date ?? "")|\(release.version ?? "")|\(release.URL ?? "")"
    }

    private static func revisionNumber(_ date: String, fallback: String) -> UInt64 {
        let digits = (date + fallback).filter(\.isNumber)
        return UInt64(String(digits.prefix(14))) ?? 1
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

extension BundledOpenResourceDefinition {
    var isLiveDiscoveredResource: Bool { sha256.isEmpty }

    func recordingDownloadedPayload(bytes: UInt64, sha256: String)
        -> BundledOpenResourceDefinition {
        let locallyRecordedDigest = officialDigest.isEmpty
        return BundledOpenResourceDefinition(
            resourceID: resourceID, resourceRevision: resourceRevision, title: title,
            summary: summary, languageDisplay: languageDisplay, category: category,
            publisher: publisher, redistributionStatement: redistributionStatement,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, version: version,
            sourceFormat: sourceFormat, downloadURL: downloadURL, downloadBytes: bytes,
            maximumExpandedBytes: maximumExpandedBytes, maximumEntries: maximumEntries,
            maximumEntryBytes: maximumEntryBytes, sha256: sha256,
            officialDigestAlgorithm: locallyRecordedDigest ? "SHA-256" : officialDigestAlgorithm,
            officialDigest: locallyRecordedDigest ? sha256 : officialDigest,
            digestProvenance: digestProvenance,
            licenseIdentifier: licenseIdentifier, licenseVersion: licenseVersion,
            licenseURL: licenseURL, attribution: attribution, sourceProject: sourceProject,
            officialDownloadPage: officialDownloadPage,
            transformerIdentifier: transformerIdentifier,
            transformerVersion: transformerVersion, outputSchemaVersion: outputSchemaVersion,
            minimumAppVersion: minimumAppVersion, expectedEntryCount: expectedEntryCount,
            minimumConvertedEntryCount: minimumConvertedEntryCount,
            catalogMetadataSHA256: catalogMetadataSHA256, archiveMembers: archiveMembers,
            capabilities: capabilities, openResourceCapabilities: openResourceCapabilities
        )
    }
}

/// Downloads only a resource returned by the official discovery client.  The payload SHA-256 is
/// computed locally and becomes part of the durable receipt; FreeDict's upstream SHA-512 is also
/// checked when present.  There is no compiled-in per-release hash or exact byte count.
actor OfficialOpenResourcePayloadDownloader {
    private let stagingRoot: URL
    private let session: URLSession
    private let maximumBytes: UInt64
    private var busy = false

    init(stagingRoot: URL, session: URLSession = .shared,
         maximumBytes: UInt64 = 128 * 1024 * 1024) {
        self.stagingRoot = stagingRoot
        self.session = session
        self.maximumBytes = maximumBytes
    }

    func download(_ discovered: BundledOpenResourceDefinition)
        async throws -> (VerifiedPayloadStagingResult, BundledOpenResourceDefinition) {
        guard !busy else { throw ResourcePayloadDownloadError.operationInProgress }
        busy = true
        defer { busy = false }
        guard discovered.isLiveDiscoveredResource,
              discovered.downloadURL.scheme == "https",
              ["download.freedict.org", "cc-cedict.org"].contains(discovered.allowedHost) else {
            throw OfficialOpenResourceDiscoveryError.invalidCatalog
        }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(from: discovered.downloadURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OfficialOpenResourceDiscoveryError.downloadFailed
        }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.url?.scheme == "https",
              http.url?.host == discovered.allowedHost else {
            throw OfficialOpenResourceDiscoveryError.invalidResponse
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw OfficialOpenResourceDiscoveryError.downloadFailed
        }
        let bytes = number.uint64Value
        guard bytes > 0, bytes <= maximumBytes else {
            throw OfficialOpenResourceDiscoveryError.payloadTooLarge
        }
        let digests = try Self.digests(temporary)
        if discovered.officialDigestAlgorithm == "SHA-512",
           !discovered.officialDigest.isEmpty,
           digests.sha512 != discovered.officialDigest.lowercased() {
            throw OfficialOpenResourceDiscoveryError.digestMismatch
        }
        let resource = discovered.recordingDownloadedPayload(
            bytes: bytes, sha256: digests.sha256
        )
        let identity = try OpenResourceInstallationIdentity(starter: resource)
        try FileManager.default.createDirectory(
            at: stagingRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let operationID = UUID()
        let component = "verified-\(operationID.uuidString.lowercased())"
        let directory = stagingRoot.appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let payload = directory.appendingPathComponent(identity.sourceComponent)
            try FileManager.default.copyItem(at: temporary, to: payload)
            try FileManager.default.setAttributes([.posixPermissions: 0o400],
                                                  ofItemAtPath: payload.path)
            let sidecar = OpenResourceInstallationSidecar(identity: identity)
            let sidecarURL = directory.appendingPathComponent(
                OpenResourceInstallationIdentity.sidecarComponent
            )
            try sidecar.encodedData().write(to: sidecarURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o400],
                                                  ofItemAtPath: sidecarURL.path)
            return (VerifiedPayloadStagingResult(
                resourceID: resource.resourceID,
                resourceRevision: resource.resourceRevision,
                operationID: operationID,
                verifiedFileURL: payload,
                signedFileName: resource.sourceFileName,
                actualByteCount: bytes,
                verifiedSHA256: digests.sha256,
                stagingRootURL: stagingRoot,
                verifiedDirectoryComponent: component,
                payloadComponent: identity.sourceComponent,
                sidecarComponent: OpenResourceInstallationIdentity.sidecarComponent,
                installationIdentity: identity
            ), resource)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func digests(_ url: URL) throws -> (sha256: String, sha512: String) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash256 = SHA256()
        var hash512 = SHA512()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash256.update(data: data)
            hash512.update(data: data)
        }
        return (
            Array(hash256.finalize()).map { String(format: "%02x", $0) }.joined(),
            Array(hash512.finalize()).map { String(format: "%02x", $0) }.joined()
        )
    }
}
