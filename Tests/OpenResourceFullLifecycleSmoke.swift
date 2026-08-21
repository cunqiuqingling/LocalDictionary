import Darwin
import CryptoKit
import Foundation

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

enum OpenResourceInstallationMode: Sendable {
    case newInstallation
    case update(replacingDictionaryID: String)
}

enum ResourcePayloadDownloadError: Error {
    case operationInProgress
}

struct ReverseIndexIdentity: Equatable, Sendable {
    static let schemaVersion = 2
    static let openResourceSchemaVersion = 1
    let schemaVersion: Int
    let dictionaryID: String
    let dictionaryName: String
    let sourceSHA256: String
    let indexPublicationID: String
    let queryPriority: Int
    let sortPosition: Int64

    init(schemaVersion: Int = ReverseIndexIdentity.schemaVersion,
         dictionaryID: String, dictionaryName: String,
         sourceSHA256: String, indexPublicationID: String,
         queryPriority: Int, sortPosition: Int64) {
        self.schemaVersion = schemaVersion
        self.dictionaryID = dictionaryID
        self.dictionaryName = dictionaryName
        self.sourceSHA256 = sourceSHA256
        self.indexPublicationID = indexPublicationID
        self.queryPriority = queryPriority
        self.sortPosition = sortPosition
    }
}

struct ReverseIndexDescriptor: Equatable, Sendable {
    let fileURL: URL
    let identity: ReverseIndexIdentity
}

enum ReverseIndexThermalPacing {
    static func delayMicroseconds(for state: ProcessInfo.ThermalState) -> useconds_t { 0 }
}

enum ReverseLookupNormalizer {
    static func snippet(_ value: String, maximum: Int) -> String {
        value.count <= maximum ? value : String(value.prefix(maximum - 1)) + "…"
    }

    static func weightedTerms(in value: String) -> [(String, Int)] {
        var output: [String: Int] = [:]
        var run: [String] = []
        func appendRun() {
            guard !run.isEmpty else { return }
            for length in 1...min(4, run.count) {
                for start in 0...(run.count - length) {
                    output[run[start..<(start + length)].joined()] = length * length
                }
            }
            run.removeAll(keepingCapacity: true)
        }
        for scalar in value.unicodeScalars {
            let cjk = (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value)
            if cjk { run.append(String(scalar)) } else { appendRun() }
        }
        appendRun()
        return output.sorted { $0.key < $1.key }
    }
}

private enum FullLifecycleError: Error {
    case usage
    case missingResource(String)
    case invalidFixture(String)
}

private actor RemovalRuntime: ManagedDictionaryQueryRuntime {
    private var removed: [String] = []

    func lookup(descriptor: DictionaryDescriptor, generation: UInt64, query: String) async
        -> ManagedDictionaryRuntimeOutcome { .miss }
    func remove(dictionaryID: String) async { removed.append(dictionaryID) }
    func remove(dictionaryID: String, generation: UInt64) async {
        removed.append(dictionaryID)
    }
    func reset() async {}

    func removedIDs() -> [String] { removed }
}

private actor ProductionOpenResourceRuntime: ManagedDictionaryQueryRuntime {
    let root: URL

    init(root: URL) { self.root = root }

    func lookup(descriptor: DictionaryDescriptor, generation: UInt64, query: String) async
        -> ManagedDictionaryRuntimeOutcome {
        (try? OpenResourceSQLiteRuntime.lookup(
            descriptor: descriptor, query: query,
            applicationSupportRootURL: root
        )) ?? .identityMismatch
    }

    func remove(dictionaryID: String) async {}
    func remove(dictionaryID: String, generation: UInt64) async {}
    func reset() async {}
}

@main
private enum OpenResourceFullLifecycleSmoke {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--live"] {
            try await exerciseLiveOfficialLanguagePair()
            print("Live official bilingual resources: full lifecycle PASS")
            return
        }
        guard arguments.count.isMultiple(of: 2) else {
            throw FullLifecycleError.usage
        }
        var requested: [(BundledOpenResourceDefinition, URL)] = []
        for offset in stride(from: 0, to: arguments.count, by: 2) {
            let id = arguments[offset]
            guard let resource = BundledOpenResourceCatalog.resource(id: id) else {
                throw FullLifecycleError.missingResource(id)
            }
            let source = URL(fileURLWithPath: arguments[offset + 1]).standardizedFileURL
            requested.append((resource, source))
        }
        for (resource, source) in requested {
            try await exercise(resource: resource, source: source)
        }
        let syntheticCC = try makeSyntheticCCCEDICTFixture()
        defer { try? FileManager.default.removeItem(at: syntheticCC.source.deletingLastPathComponent()) }
        try await exercise(resource: syntheticCC.resource, source: syntheticCC.source)
        print("Open resource full production lifecycle: PASS " +
              "(\(requested.count) public resources + synthetic CC-CEDICT direct lookup)")
    }

    @MainActor
    private static func exerciseLiveOfficialLanguagePair() async throws {
        let resources = try await OfficialOpenResourceDiscoveryClient().discover(
            nativeLanguageCode: "zh-Hans", learningLanguageCode: "en"
        )
        let wanted = resources.filter {
            $0.resourceID == "org.freedict.live.eng-zho" ||
                $0.resourceID == "org.cc-cedict.zh-en.live"
        }
        guard wanted.count == 2 else {
            throw FullLifecycleError.invalidFixture("live-language-pair-count")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-live-official-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = OfficialOpenResourcePayloadDownloader(stagingRoot: root)
        for discovered in wanted {
            let (staged, downloaded) = try await downloader.download(discovered)
            try await exercise(resource: downloaded, source: staged.verifiedFileURL)
        }
    }

    private static func makeSyntheticCCCEDICTFixture() throws
        -> (resource: BundledOpenResourceDefinition, source: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-synthetic-cc-cedict-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let textURL = directory.appendingPathComponent("cedict.txt")
        let archiveURL = directory.appendingPathComponent(
            BundledOpenResourceCatalog.ccCedictChineseEnglish.sourceFileName
        )
        let text = """
        # synthetic public-format fixture; no user dictionary content
        蘋果 苹果 [ping2 guo3] /apple/fruit/
        文化 文化 [wen2 hua4] /culture/civilization/

        """
        try Data(text.utf8).write(to: textURL, options: .atomic)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", "-c", textURL.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let compressed = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !compressed.isEmpty else {
            throw FullLifecycleError.invalidFixture("synthetic-cc-cedict:gzip")
        }
        try compressed.write(to: archiveURL, options: .atomic)
        let digest = SHA256.hash(data: compressed).map {
            String(format: "%02x", $0)
        }.joined()
        return (
            BundledOpenResourceCatalog.ccCedictChineseEnglish.replacingPayloadForTesting(
                bytes: UInt64(compressed.count), sha256: digest,
                expectedEntryCount: 3, minimumConvertedEntryCount: 3,
                maximumEntries: 10
            ),
            archiveURL
        )
    }

    @MainActor
    private static func exercise(resource: BundledOpenResourceDefinition,
                                 source: URL) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == resource.downloadBytes else {
            throw FullLifecycleError.invalidFixture("\(resource.resourceID):size")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-full-lifecycle-\(resource.resourceID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let dictionaries = root.appendingPathComponent("Dictionaries", isDirectory: true)
        let catalogStore = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("Catalog", isDirectory: true)
        )

        let first = try await install(
            resource: resource, source: source, root: root,
            dictionaries: dictionaries, catalogStore: catalogStore
        )
        try verifyPublished(first, resource: resource, root: root)

        let restart = await OwnedDictionaryLifecycleReconciler(
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            verifyPublishedIndex: { supportRoot, descriptor in
                guard let outcome = try? OpenResourceSQLiteRuntime.lookup(
                    descriptor: descriptor,
                    query: "localdictionary-identity-probe-no-match",
                    applicationSupportRootURL: supportRoot
                ) else { return false }
                switch outcome {
                case .hit, .miss: return true
                case .unavailable, .identityMismatch: return false
                }
            }
        ).reconcile()
        if !restart.report.issues.isEmpty {
            print("RESTART issues resource=\(resource.resourceID) " +
                  restart.report.issues.map { $0.code.rawValue }.joined(separator: ","))
        }
        guard let restarted = restart.catalog.dictionaries.first(where: {
            $0.dictionaryID == first.dictionaryID
        }), restarted.state == .ready else {
            let issues = restart.report.issues.map { $0.code.rawValue }.joined(separator: ",")
            let catalogStates = restart.catalog.dictionaries.map {
                $0.dictionaryID + ":" + $0.state.rawValue
            }.joined(separator: ",")
            let accepted = restart.report.acceptedDictionaryIDs.joined(separator: ",")
            throw FullLifecycleError.invalidFixture(
                "\(resource.resourceID):restart:\(issues):catalog=\(catalogStates):" +
                "accepted=\(accepted)"
            )
        }
        try verifyQuery(restarted, resource: resource, root: root)
        if resource.sourceFormat == .ccCedictTextGZIP {
            let directService = ManagedDictionaryQueryService(
                catalog: restart.catalog,
                runtime: ProductionOpenResourceRuntime(root: root)
            )
            let direct = await directService.lookupChinese("苹果")
            guard direct.hits.contains(where: {
                $0.dictionaryID == restarted.dictionaryID &&
                    $0.displayName == resource.title &&
                    !$0.noteDefinitions.isEmpty
            }) else {
                throw FullLifecycleError.invalidFixture(
                    "cc-cedict:production-ChineseQueryPlanner-direct-lookup"
                )
            }
        }

        let runtime = RemovalRuntime()
        let lifecycle = ManagedDictionaryLifecycleCoordinator(catalog: restart.catalog)
        let service = ManagedDictionaryQueryService(
            catalog: restart.catalog, runtime: runtime,
            lifecycleCoordinator: lifecycle
        )
        let removal = ManagedDictionaryRemovalCoordinator(
            catalog: restart.catalog,
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            queryService: service,
            lifecycleCoordinator: lifecycle,
            isIndexing: { _ in false }
        )
        let removalResult = await removal.remove(dictionaryID: restarted.dictionaryID)
        let directoryStillExists = FileManager.default.fileExists(
            atPath: dictionaries.appendingPathComponent(restarted.dictionaryID).path
        )
        let removedIDs = await runtime.removedIDs()
        guard removalResult == .removed(cleanupDeferred: false),
              removal.catalog.dictionaries.isEmpty,
              !directoryStillExists,
              removedIDs == [restarted.dictionaryID] else {
            throw FullLifecycleError.invalidFixture(
                "\(resource.resourceID):remove:\(removalResult):" +
                "catalog=\(removal.catalog.dictionaries.count):exists=\(directoryStillExists):" +
                "runtime=\(removedIDs.joined(separator: ","))"
            )
        }

        let reinstalled = try await install(
            resource: resource, source: source, root: root,
            dictionaries: dictionaries, catalogStore: catalogStore
        )
        try verifyPublished(reinstalled, resource: resource, root: root)
        try verifyQuery(reinstalled, resource: resource, root: root)
        print("PASS resource=\(resource.resourceID) install=ready restart=ready " +
              "query=hit remove=source-independent reinstall=ready " +
              "entries=\(reinstalled.indexMetadata.entryCount ?? 0)")
    }

    @MainActor
    private static func install(resource: BundledOpenResourceDefinition,
                                source: URL,
                                root: URL,
                                dictionaries: URL,
                                catalogStore: DictionaryCatalogStore) async throws
        -> DictionaryDescriptor {
        let identity = try OpenResourceInstallationIdentity(
            starter: resource,
            dictionaryID: UUID().uuidString.lowercased(),
            installedAt: Date()
        )
        let staging = root.appendingPathComponent(
            "Staging-\(UUID().uuidString)", isDirectory: true
        )
        let verifiedDirectory = staging.appendingPathComponent("verified", isDirectory: true)
        try FileManager.default.createDirectory(
            at: verifiedDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let copied = verifiedDirectory.appendingPathComponent(identity.sourceComponent)
        try FileManager.default.copyItem(at: source, to: copied)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: copied.path
        )
        let staged = VerifiedPayloadStagingResult(
            resourceID: resource.resourceID,
            resourceRevision: resource.resourceRevision,
            operationID: UUID(),
            verifiedFileURL: copied,
            signedFileName: resource.sourceFileName,
            actualByteCount: resource.downloadBytes,
            verifiedSHA256: resource.sha256,
            stagingRootURL: staging,
            verifiedDirectoryComponent: "verified",
            payloadComponent: identity.sourceComponent,
            sidecarComponent: OpenResourceInstallationIdentity.sidecarComponent,
            installationIdentity: identity
        )
        let result: FreeDictInstallationResult
        if resource.sourceFormat == .freeDictStarDictTarXZ {
            result = try await FreeDictStarDictInstallationCoordinator().install(
                staged, resource: resource, dictionariesRoot: dictionaries,
                catalogStore: catalogStore, mode: .newInstallation
            )
        } else {
            result = try await AuditedOpenResourceInstallationCoordinator().install(
                staged, resource: resource, dictionariesRoot: dictionaries,
                catalogStore: catalogStore, mode: .newInstallation
            )
        }
        return result.descriptor
    }

    private static func verifyPublished(_ descriptor: DictionaryDescriptor,
                                        resource: BundledOpenResourceDefinition,
                                        root: URL) throws {
        guard descriptor.state == .ready,
              descriptor.relativePaths.dictionary == nil,
              descriptor.indexMetadata.entryCount.map({ $0 >= resource.minimumConvertedEntryCount &&
                  $0 <= resource.maximumEntries }) == true,
              let relativeIndex = descriptor.relativePaths.index else {
            throw FullLifecycleError.invalidFixture("\(resource.resourceID):descriptor")
        }
        let directory = root.appendingPathComponent("Dictionaries", isDirectory: true)
            .appendingPathComponent(descriptor.dictionaryID, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        guard entries == ["index", OpenResourceInstallationIdentity.sidecarComponent].sorted(),
              !entries.contains(identitySourceComponent(resource)),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(relativeIndex).path)
        else {
            throw FullLifecycleError.invalidFixture("\(resource.resourceID):source-cleanup")
        }
        let permissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(relativeIndex).path
        )[.posixPermissions] as? NSNumber
        guard permissions?.intValue == 0o400 else {
            throw FullLifecycleError.invalidFixture("\(resource.resourceID):index-mode")
        }
        guard OpenResourceSQLiteRuntime.validatePublishedIndex(
            descriptor: descriptor, applicationSupportRootURL: root
        ) else {
            throw FullLifecycleError.invalidFixture(
                "\(resource.resourceID):production-published-index-verifier"
            )
        }
    }

    private static func identitySourceComponent(_ resource: BundledOpenResourceDefinition)
        -> String {
        resource.sourceFormat == .freeDictStarDictTarXZ
            ? OpenResourceInstallationIdentity.starDictSourceComponent
            : OpenResourceInstallationIdentity.payloadComponent
    }

    private static func verifyQuery(_ descriptor: DictionaryDescriptor,
                                    resource: BundledOpenResourceDefinition,
                                    root: URL) throws {
        let query: String
        switch resource.sourceFormat {
        case .freeDictStarDictTarXZ, .kaikkiWiktionaryJSONL: query = "apple"
        case .ccCedictTextGZIP: query = "苹果"
        case .wordNetDataTarGZIP: query = "entity"
        case .gcideMarkupTarXZ: query = "apple"
        }
        let outcome = try OpenResourceSQLiteRuntime.lookup(
            descriptor: descriptor, query: query,
            applicationSupportRootURL: root
        )
        guard case .hit(let hit) = outcome, !hit.plainText.isEmpty else {
            throw FullLifecycleError.invalidFixture("\(resource.resourceID):query")
        }
        if resource.openResourceCapabilities.requiresDerivedReverseIndex {
            let reverse = try OpenResourceSQLiteRuntime.reverseDescriptor(
                descriptor: descriptor, applicationSupportRootURL: root
            )
            guard FileManager.default.fileExists(atPath: reverse.fileURL.path) else {
                throw FullLifecycleError.invalidFixture("\(resource.resourceID):reverse")
            }
        }
    }
}

private extension BundledOpenResourceDefinition {
    func replacingPayloadForTesting(
        bytes: UInt64,
        sha256: String,
        expectedEntryCount: UInt64,
        minimumConvertedEntryCount: UInt64,
        maximumEntries: UInt64
    ) -> BundledOpenResourceDefinition {
        BundledOpenResourceDefinition(
            resourceID: "org.synthetic.cc-cedict.zh-en",
            resourceRevision: 1,
            title: title,
            summary: summary,
            languageDisplay: languageDisplay,
            category: category,
            publisher: publisher,
            redistributionStatement: redistributionStatement,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            version: "fixture-1",
            sourceFormat: sourceFormat,
            downloadURL: downloadURL,
            downloadBytes: bytes,
            maximumExpandedBytes: maximumExpandedBytes,
            maximumEntries: maximumEntries,
            maximumEntryBytes: maximumEntryBytes,
            sha256: sha256,
            officialDigestAlgorithm: "SHA-256",
            officialDigest: sha256,
            digestProvenance: "synthetic production-lifecycle fixture",
            licenseIdentifier: licenseIdentifier,
            licenseVersion: licenseVersion,
            licenseURL: licenseURL,
            attribution: attribution,
            sourceProject: sourceProject,
            officialDownloadPage: officialDownloadPage,
            transformerIdentifier: transformerIdentifier,
            transformerVersion: transformerVersion,
            outputSchemaVersion: outputSchemaVersion,
            minimumAppVersion: minimumAppVersion,
            expectedEntryCount: expectedEntryCount,
            minimumConvertedEntryCount: minimumConvertedEntryCount,
            catalogMetadataSHA256: String(repeating: "e", count: 64),
            archiveMembers: archiveMembers,
            capabilities: capabilities,
            openResourceCapabilities: openResourceCapabilities
        )
    }
}
