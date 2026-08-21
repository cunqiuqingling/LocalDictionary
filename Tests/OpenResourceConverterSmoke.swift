import Darwin
import Foundation
import SQLite3

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

enum ReverseIndexThermalPacing {
    static func delayMicroseconds(for state: ProcessInfo.ThermalState) -> useconds_t { 0 }
}

enum GenericMDictBlockKind: String, Equatable, Sendable { case paragraph }
struct GenericMDictTextRun: Equatable, Sendable {
    let text: String; let bold: Bool; let italic: Bool; let code: Bool
}
struct GenericMDictBlock: Equatable, Sendable {
    let kind: GenericMDictBlockKind; let level: Int; let runs: [GenericMDictTextRun]
}
struct ManagedDictionaryQueryHit: Equatable, Sendable {
    let dictionaryID: String; let displayName: String; let matchedHeadword: String
    let blocks: [GenericMDictBlock]; let plainText: String; let truncated: Bool
    let sourcePriority: Int; let dictionaryOrder: Int64

    init(dictionaryID: String, displayName: String, matchedHeadword: String,
         blocks: [GenericMDictBlock], plainText: String, truncated: Bool,
         sourcePriority: Int = 1, dictionaryOrder: Int64 = 0) {
        self.dictionaryID = dictionaryID
        self.displayName = displayName
        self.matchedHeadword = matchedHeadword
        self.blocks = blocks
        self.plainText = plainText
        self.truncated = truncated
        self.sourcePriority = sourcePriority
        self.dictionaryOrder = dictionaryOrder
    }
}
enum ManagedDictionaryRuntimeOutcome: Sendable {
    case hit(ManagedDictionaryQueryHit), miss, unavailable, identityMismatch
}

@main
struct OpenResourceConverterSmoke {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("expected official StarDict archive path")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        try securitySubsetChecks()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-open-resource-smoke-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let verifiedDirectory = staging.appendingPathComponent("verified", isDirectory: true)
        let dictionaries = root.appendingPathComponent("Dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(at: verifiedDirectory,
                                                withIntermediateDirectories: true)
        let resource = BundledOpenResourceCatalog.freeDictEnglishChinese
        let identity = try OpenResourceInstallationIdentity(starter: resource)
        try await officialDigestFailureCheck(
            source: source, root: root, resource: resource, identity: identity
        )
        let verifiedFile = verifiedDirectory.appendingPathComponent(identity.sourceComponent)
        try FileManager.default.copyItem(at: source, to: verifiedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: verifiedFile.path)
        let catalogStore = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("Catalog", isDirectory: true)
        )
        let staged = VerifiedPayloadStagingResult(
            resourceID: resource.resourceID,
            resourceRevision: resource.resourceRevision,
            operationID: UUID(),
            verifiedFileURL: verifiedFile,
            signedFileName: resource.sourceFileName,
            actualByteCount: resource.downloadBytes,
            verifiedSHA256: resource.sha256,
            stagingRootURL: staging,
            verifiedDirectoryComponent: "verified",
            payloadComponent: identity.sourceComponent,
            sidecarComponent: OpenResourceInstallationIdentity.sidecarComponent,
            installationIdentity: identity
        )
        let result = try await FreeDictStarDictInstallationCoordinator().install(
            staged,
            resource: resource,
            dictionariesRoot: dictionaries,
            catalogStore: catalogStore,
            mode: .newInstallation
        )
        let catalog = try catalogStore.load().validated()
        guard catalog.dictionaries.count == 1,
              catalog.dictionaries[0].dictionaryID == result.descriptor.dictionaryID,
              catalog.dictionaries[0].state == .ready,
              catalog.dictionaries[0].enabled else {
            fatalError("catalog publication mismatch")
        }
        let descriptor = catalog.dictionaries[0]
        let supportRoot = dictionaries.deletingLastPathComponent()
        let lookup = try OpenResourceSQLiteRuntime.lookup(
            descriptor: descriptor, query: "apple",
            applicationSupportRootURL: supportRoot
        )
        guard case .hit(let hit) = lookup,
              hit.displayName == "FreeDict英中词典",
              hit.plainText.contains("苹果") || hit.plainText.contains("蘋果") else {
            fatalError("forward lookup failed")
        }
        let reverse = try OpenResourceSQLiteRuntime.reverseDescriptor(
            descriptor: descriptor, applicationSupportRootURL: supportRoot
        )
        let productionReverse = ReverseLookupService(descriptors: [reverse])
        let productionResults = await productionReverse.lookup("苹果")
        guard productionResults.contains(where: {
            $0.headword == "apple" && $0.dictionaryName == "FreeDict英中词典" &&
                $0.matchTier == .exactGloss
        }) else {
            fatalError("FreeDict reverse-ready descriptor did not enter production query")
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(reverse.fileURL.path, &database,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            fatalError("reverse database unavailable")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, """
            SELECT e.headword FROM terms t JOIN entries e ON e.id=t.entry_id
            WHERE t.term IN ('苹果','蘋果') AND e.headword='apple' LIMIT 1
            """, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            fatalError("reverse candidate missing")
        }
        sqlite3_finalize(statement)
        let receiptURL = dictionaries.appendingPathComponent(identity.dictionaryID)
            .appendingPathComponent(OpenResourceInstallationIdentity.sidecarComponent)
        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try OpenResourceInstallationSidecar.decode(receiptData)
        guard receipt.outputIntegrityStatus == "ok",
              receipt.officialDigest == resource.officialDigest,
              receipt.transformerVersion == resource.transformerVersion,
              receipt.outputSHA256 == descriptor.publishedIndexIdentity?.indexSHA256 else {
            fatalError("receipt mismatch")
        }
        var tampered = String(decoding: receiptData, as: UTF8.self)
        tampered = tampered.replacingOccurrences(
            of: resource.officialDigest,
            with: String(repeating: "0", count: resource.officialDigest.count)
        )
        do {
            _ = try OpenResourceInstallationSidecar.decode(Data(tampered.utf8))
            fatalError("tampered official digest receipt was accepted")
        } catch is OpenResourceInstallationError {}
        let indexURL = supportRoot.appendingPathComponent(descriptor.relativePaths.index!)
        var damagedIndex = try Data(contentsOf: indexURL)
        damagedIndex[damagedIndex.count - 1] ^= 0x01
        try damagedIndex.write(to: indexURL, options: .atomic)
        let damagedLookup = try OpenResourceSQLiteRuntime.lookup(
            descriptor: descriptor, query: "apple", applicationSupportRootURL: supportRoot
        )
        guard case .identityMismatch = damagedLookup else {
            fatalError("damaged internal index was accepted")
        }
        print("Open resource converter smoke passed (\(descriptor.indexMetadata.entryCount ?? 0) " +
              "usable / \(resource.expectedEntryCount) source entries).")
    }

    @MainActor
    private static func officialDigestFailureCheck(
        source: URL,
        root: URL,
        resource: BundledOpenResourceDefinition,
        identity: OpenResourceInstallationIdentity
    ) async throws {
        let directory = root.appendingPathComponent("digest-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupted = directory.appendingPathComponent(identity.sourceComponent)
        var bytes = try Data(contentsOf: source)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: corrupted, options: .withoutOverwriting)
        let staged = VerifiedPayloadStagingResult(
            resourceID: resource.resourceID, resourceRevision: resource.resourceRevision,
            operationID: UUID(), verifiedFileURL: corrupted,
            signedFileName: resource.sourceFileName,
            actualByteCount: resource.downloadBytes, verifiedSHA256: resource.sha256,
            stagingRootURL: directory, verifiedDirectoryComponent: "digest-failure",
            payloadComponent: identity.sourceComponent,
            sidecarComponent: OpenResourceInstallationIdentity.sidecarComponent,
            installationIdentity: identity
        )
        do {
            _ = try await FreeDictStarDictInstallationCoordinator().install(
                staged, resource: resource,
                dictionariesRoot: root.appendingPathComponent("DigestFailureDictionaries"),
                catalogStore: DictionaryCatalogStore(
                    directoryURL: root.appendingPathComponent("DigestFailureCatalog")
                ),
                mode: .newInstallation
            )
            fatalError("official digest mismatch was accepted")
        } catch let error as FreeDictResourceError {
            guard error == .sourceDigestMismatch else { throw error }
        }
    }

    private static func securitySubsetChecks() throws {
        try syntheticArchiveChecks()
        try auditedFormatSubsetChecks()
        let normal = try FreeDictSecurityTestHooks.parseHTML(
            "<div><font class=\"grammar\">noun</font><ol><li><div>苹果</div></li>" +
            "<li><div>蘋果</div></li></ol></div>"
        )
        guard normal.partOfSpeech == "noun", normal.definition.contains("苹果"),
              normal.definition.contains("蘋果") else { fatalError("safe subset parse failed") }
        let rejected = [
            "<!DOCTYPE x><div>中文</div>",
            "<!ENTITY x SYSTEM \"file:///etc/passwd\"><div>&x;</div>",
            String(repeating: "<div>", count: 65) + "中文" +
                String(repeating: "</div>", count: 65),
            "<div>" + String(repeating: "中", count: 17_000) + "</div>"
        ]
        for value in rejected {
            do {
                _ = try FreeDictSecurityTestHooks.parseHTML(value)
                fatalError("hostile HTML was accepted")
            } catch is FreeDictResourceError {}
        }
        let skipped = try FreeDictSecurityTestHooks.parseHTML(
            "<div><font class=\"grammar\">noun</font><div>pinyin-only</div></div>"
        )
        guard skipped.definition.isEmpty else { fatalError("non-CJK content was retained") }
        do {
            _ = try FreeDictSecurityTestHooks.parseHTML(Data([0xC3, 0x28]))
            fatalError("invalid UTF-8 was accepted")
        } catch FreeDictResourceError.invalidEntry {}
    }

    private static func auditedFormatSubsetChecks() throws {
        let cedict = try AuditedOpenResourceSecurityTestHooks.parseCCCEDICT(
            "蘋果 苹果 [ping2 guo3] /apple/CL:個|个[ge4]/"
        )
        guard cedict.map(\.0) == ["蘋果", "苹果"],
              cedict.allSatisfy({ $0.1.contains("apple") }) else {
            fatalError("CC-CEDICT safe subset failed")
        }

        let kaikkiLine = """
        {"lang_code":"en","word":"apple","pos":"noun","senses":[{"glosses":["苹果；苹果树的果实"]}]}
        """
        let kaikki = try AuditedOpenResourceSecurityTestHooks.parseKaikki(kaikkiLine)
        guard kaikki?.0 == "apple", kaikki?.1.contains("苹果") == true else {
            fatalError("Kaikki JSONL safe subset failed")
        }

        let wordNet = try AuditedOpenResourceSecurityTestHooks.parseWordNet(
            "00001740 03 n 02 entity 0 physical_entity 0 000 | that which is perceived"
        )
        guard wordNet.map(\.0) == ["entity", "physical entity"],
              wordNet.allSatisfy({ $0.1 == "that which is perceived" }) else {
            fatalError("WordNet data safe subset failed")
        }

        let gcide = try AuditedOpenResourceSecurityTestHooks.parseGCIDE(
            "<p><ent>Apple</ent><pos>n.</pos><def>The fruit of the apple tree &amp; food.</def></p>"
        )
        guard gcide?.0 == "Apple", gcide?.1.contains("fruit") == true,
              gcide?.1.contains("& food") == true else {
            fatalError("GCIDE markup safe subset failed")
        }

        let hostile: [() throws -> Void] = [
            { _ = try AuditedOpenResourceSecurityTestHooks.parseCCCEDICT("broken") },
            { _ = try AuditedOpenResourceSecurityTestHooks.parseKaikki("{not-json}") },
            { _ = try AuditedOpenResourceSecurityTestHooks.parseWordNet(
                "00001740 03 n ff impossible 0 | invalid word count"
            ) }
        ]
        for attack in hostile {
            do {
                try attack()
                fatalError("hostile audited source fixture was accepted")
            } catch is AuditedOpenResourceError {}
        }
        let missingDefinition = try AuditedOpenResourceSecurityTestHooks.parseGCIDE(
            "<p><ent>Apple</ent><script>not accepted</script></p>"
        )
        guard missingDefinition == nil else {
            fatalError("GCIDE markup outside the audited subset was accepted")
        }
    }

    private struct SyntheticTarEntry {
        let path: String
        let type: UInt8
        let link: String
        let data: Data

        init(_ path: String, type: UInt8 = 48, link: String = "", data: Data = Data()) {
            self.path = path
            self.type = type
            self.link = link
            self.data = data
        }
    }

    private static func syntheticArchiveChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-open-resource-attacks-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let safe = SyntheticTarEntry("eng-zho/safe", data: Data("abc".utf8))
        let safeArchive = try compressedTar([safe], root: root, name: "safe")
        try FreeDictSecurityTestHooks.inspectArchive(
            safeArchive, expected: [safe.path: 3], maximumExpandedBytes: 3
        )
        try expectUnsafeArchive(
            [SyntheticTarEntry("../escape", data: Data("x".utf8))],
            expected: [safe.path: 1], root: root, name: "traversal"
        )
        try expectUnsafeArchive(
            [SyntheticTarEntry("/absolute", data: Data("x".utf8))],
            expected: [safe.path: 1], root: root, name: "absolute"
        )
        try expectUnsafeArchive(
            [SyntheticTarEntry(safe.path, type: 50, link: "target")],
            expected: [safe.path: 0], root: root, name: "symlink"
        )
        try expectUnsafeArchive(
            [SyntheticTarEntry(safe.path, type: 49, link: "target")],
            expected: [safe.path: 0], root: root, name: "hardlink"
        )
        try expectUnsafeArchive(
            [safe, SyntheticTarEntry("eng-zho/extra", data: Data("x".utf8))],
            expected: [safe.path: 3], root: root, name: "extra"
        )
        try expectUnsafeArchive(
            [safe, safe], expected: [safe.path: 3], root: root, name: "duplicate"
        )
        try expectUnsafeArchive(
            [safe], expected: [safe.path: 4], root: root, name: "size-mismatch"
        )
        let bomb = SyntheticTarEntry(
            "eng-zho/bomb", data: Data(repeating: 0, count: 128 * 1024)
        )
        try expectUnsafeArchive(
            [bomb], expected: [bomb.path: UInt64(bomb.data.count)],
            maximumExpandedBytes: 1_024, root: root, name: "expanded-limit"
        )
    }

    private static func expectUnsafeArchive(
        _ entries: [SyntheticTarEntry], expected: [String: UInt64],
        maximumExpandedBytes: UInt64 = 1_000_000,
        root: URL, name: String
    ) throws {
        let archive = try compressedTar(entries, root: root, name: name)
        do {
            try FreeDictSecurityTestHooks.inspectArchive(
                archive, expected: expected, maximumExpandedBytes: maximumExpandedBytes
            )
            fatalError("hostile archive was accepted: \(name)")
        } catch FreeDictResourceError.unsafeArchive {}
    }

    private static func compressedTar(
        _ entries: [SyntheticTarEntry], root: URL, name: String
    ) throws -> URL {
        var tar = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            put(entry.path, in: &header, at: 0, length: 100)
            put("0000644\0", in: &header, at: 100, length: 8)
            put("0000000\0", in: &header, at: 108, length: 8)
            put("0000000\0", in: &header, at: 116, length: 8)
            put(String(format: "%011o", entry.data.count) + "\0",
                in: &header, at: 124, length: 12)
            put("00000000000\0", in: &header, at: 136, length: 12)
            for index in 148..<156 { header[index] = 32 }
            header[156] = entry.type
            put(entry.link, in: &header, at: 157, length: 100)
            put("ustar\0", in: &header, at: 257, length: 6)
            put("00", in: &header, at: 263, length: 2)
            put("root", in: &header, at: 265, length: 32)
            put("root", in: &header, at: 297, length: 32)
            let checksum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", checksum) + "\0 ",
                in: &header, at: 148, length: 8)
            tar.append(contentsOf: header)
            tar.append(entry.data)
            let padding = (512 - (entry.data.count % 512)) % 512
            if padding > 0 { tar.append(Data(repeating: 0, count: padding)) }
        }
        tar.append(Data(repeating: 0, count: 1_024))
        let tarURL = root.appendingPathComponent("\(name).tar")
        let archiveURL = root.appendingPathComponent("\(name).tar.xz")
        try tar.write(to: tarURL, options: .withoutOverwriting)
        _ = FileManager.default.createFile(atPath: archiveURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: archiveURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xz", "-z", "-c", tarURL.path]
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
            throw NSError(domain: "OpenResourceConverterSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return archiveURL
    }

    private static func put(_ value: String, in bytes: inout [UInt8],
                            at offset: Int, length: Int) {
        for (index, byte) in value.utf8.prefix(length).enumerated() {
            bytes[offset + index] = byte
        }
    }
}
