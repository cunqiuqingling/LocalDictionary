import CryptoKit
import Darwin
import Foundation

private struct SmokeFailure: Error { let message: String }
private struct Smoke {
    var assertions = 0
    mutating func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
        guard try value() else { throw SmokeFailure(message: name) }; assertions += 1
    }
    @MainActor mutating func expect(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
        do { try await body(); throw SmokeFailure(message: "\(name): unexpectedly succeeded") }
        catch is OpenResourceInstallationError { assertions += 1 }
    }
}

@main
struct OpenResourceInstallationSmoke {
    @MainActor
    static func main() async throws {
        var smoke = Smoke()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-OpenInstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        let dictionaries = root.appendingPathComponent("Dictionaries", isDirectory: true)
        let catalog = DictionaryCatalogStore(directoryURL: root.appendingPathComponent("Catalog", isDirectory: true))
        let payload = Data("synthetic mDX payload".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let identity = try OpenResourceInstallationIdentity(
            dictionaryID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", resourceID: "synthetic-open",
            resourceRevision: 1, resourceVersion: "1.0", manifestVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64), verifiedKeyID: "test-key",
            payloadSHA256: digest, payloadBytes: UInt64(payload.count), languages: ["en"],
            license: OpenResourceLicenseMetadata(name: "Synthetic", version: "1", url: "https://example.test/license", attribution: "Synthetic"),
            sourceProject: "https://example.test/project", officialPageReference: "https://example.test/page",
            expectedEntryCount: OpenResourceEntryCountMetadata(minimum: 1, maximum: 3),
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let policy = try ResourcePayloadDownloadPolicy(applicationAllowedHosts: ["example.test"], applicationHardLimit: 4096,
                                                        diskSafetyMargin: 0, maximumRedirects: 0, requestTimeout: 1, resourceTimeout: 1)
        let plan = ResourcePayloadDownloadPlan(resourceID: identity.resourceID, resourceRevision: 1,
                                               downloadURL: URL(string: "https://example.test/payload.mdx")!,
                                               signedFileName: "payload.mdx", expectedBytes: UInt64(payload.count),
                                               maximumBytes: UInt64(payload.count), expectedSHA256: digest,
                                               allowedHosts: ["example.test"], stagingRoot: staging, policy: policy,
                                               installationIdentity: identity)
        let stagingStore = ResourcePayloadStagingStore(operationIDFactory: {
            UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        })
        let operation = try stagingStore.prepare(plan: plan)
        _ = try operation.append(payload, maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        let completed = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest)
        let result = VerifiedPayloadStagingResult(resourceID: identity.resourceID, resourceRevision: identity.resourceRevision,
                                                  operationID: operation.operationID, verifiedFileURL: operation.verifiedFile,
                                                  signedFileName: plan.signedFileName, actualByteCount: completed.bytes,
                                                  verifiedSHA256: completed.digest, stagingRootURL: operation.stagingRootURL,
                                                  verifiedDirectoryComponent: operation.verifiedDirectoryComponent,
                                                  payloadComponent: operation.publishedPayloadComponent,
                                                  sidecarComponent: operation.publishedSidecarComponent,
                                                  installationIdentity: identity)
        let coordinator = OpenResourceInstallationCoordinator(
            lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator()
        )
        let descriptor = try await coordinator.install(result, dictionariesRoot: dictionaries, catalogStore: catalog)
        try smoke.check("open descriptor source", descriptor.sourceKind == .openResource)
        try smoke.check("open ownership", descriptor.storageOwnership == .appManagedOpenResource)
        try smoke.check("fallback pending index", descriptor.queryLevel == .fallback && descriptor.state == .pendingIndex)
        try smoke.check("catalog sidecar relative", descriptor.openResourceMetadata?.sidecarRelativePath == "Dictionaries/\(identity.dictionaryID)/resource-installation.json")
        try smoke.check("final payload", FileManager.default.fileExists(atPath: dictionaries.appendingPathComponent(identity.dictionaryID).appendingPathComponent("payload.mdx").path))
        try smoke.check("final sidecar", FileManager.default.fileExists(atPath: dictionaries.appendingPathComponent(identity.dictionaryID).appendingPathComponent("resource-installation.json").path))
        try smoke.check("catalog v2", catalog.loadResult().provenance == .loadedPrimary)
        try await smoke.expect("resource single instance") {
            _ = try await coordinator.install(result, dictionariesRoot: dictionaries, catalogStore: catalog)
        }
        let illegal = DictionaryDescriptor(dictionaryID: UUID().uuidString.lowercased(), displayName: "bad", sourceKind: .openResource,
                                           queryLevel: .fallback, sortPosition: 0, enabled: true, state: .pendingIndex,
                                           indexMetadata: DictionaryIndexMetadata(schemaVersion: nil, entryCount: nil, indexFileSize: nil,
                                                                                  sourceFileSize: nil, sourceModifiedAt: nil, sourceSHA256: nil, indexedAt: nil),
                                           formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
                                           capabilities: .unknown, relativePaths: .empty, createdAt: Date(), updatedAt: Date(),
                                           storageOwnership: .externalReference, openResourceMetadata: nil)
        do { _ = try DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion, createdAt: Date(), updatedAt: Date(), dictionaries: [illegal]).validated(); throw SmokeFailure(message: "illegal ownership") }
        catch DictionaryCatalogValidationError.invalidStorageOwnership { smoke.assertions += 1 }
        try await testSourceNameSubstitution(root: root, smoke: &smoke)
        try await testPayloadInPlaceTamper(root: root, smoke: &smoke)
        print("Open resource installation smoke passed (\(smoke.assertions) total runtime assertions)")
    }

    private struct Fixture {
        let identity: OpenResourceInstallationIdentity
        let result: VerifiedPayloadStagingResult
        let catalog: DictionaryCatalogStore
        let coordinator: OpenResourceInstallationCoordinator
        let dictionaries: URL
    }

    @MainActor
    private static func fixture(root: URL, name: String, dictionaryID: String) throws -> Fixture {
        let staging = root.appendingPathComponent("\(name)-staging", isDirectory: true)
        let dictionaries = root.appendingPathComponent("\(name)-dictionaries", isDirectory: true)
        let catalog = DictionaryCatalogStore(directoryURL: root.appendingPathComponent("\(name)-catalog", isDirectory: true))
        let payload = Data("synthetic mDX payload".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let identity = try OpenResourceInstallationIdentity(
            dictionaryID: dictionaryID, resourceID: "synthetic-\(name)",
            resourceRevision: 1, resourceVersion: "1.0", manifestVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64), verifiedKeyID: "test-key",
            payloadSHA256: digest, payloadBytes: UInt64(payload.count), languages: ["en"],
            license: OpenResourceLicenseMetadata(name: "Synthetic", version: "1", url: "https://example.test/license", attribution: "Synthetic"),
            sourceProject: "https://example.test/project", officialPageReference: "https://example.test/page",
            expectedEntryCount: OpenResourceEntryCountMetadata(minimum: 1, maximum: 3),
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let policy = try ResourcePayloadDownloadPolicy(applicationAllowedHosts: ["example.test"], applicationHardLimit: 4096,
                                                        diskSafetyMargin: 0, maximumRedirects: 0, requestTimeout: 1, resourceTimeout: 1)
        let plan = ResourcePayloadDownloadPlan(resourceID: identity.resourceID, resourceRevision: 1,
                                               downloadURL: URL(string: "https://example.test/payload.mdx")!,
                                               signedFileName: "payload.mdx", expectedBytes: UInt64(payload.count),
                                               maximumBytes: UInt64(payload.count), expectedSHA256: digest,
                                               allowedHosts: ["example.test"], stagingRoot: staging, policy: policy,
                                               installationIdentity: identity)
        let operation = try ResourcePayloadStagingStore().prepare(plan: plan)
        _ = try operation.append(payload, maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        let completed = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest)
        let result = VerifiedPayloadStagingResult(resourceID: identity.resourceID, resourceRevision: identity.resourceRevision,
                                                  operationID: operation.operationID, verifiedFileURL: operation.verifiedFile,
                                                  signedFileName: plan.signedFileName, actualByteCount: completed.bytes,
                                                  verifiedSHA256: completed.digest, stagingRootURL: operation.stagingRootURL,
                                                  verifiedDirectoryComponent: operation.verifiedDirectoryComponent,
                                                  payloadComponent: operation.publishedPayloadComponent,
                                                  sidecarComponent: operation.publishedSidecarComponent,
                                                  installationIdentity: identity)
        return Fixture(identity: identity, result: result, catalog: catalog,
                       coordinator: OpenResourceInstallationCoordinator(
                           lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator()
                       ), dictionaries: dictionaries)
    }

    @MainActor
    private static func testSourceNameSubstitution(root: URL, smoke: inout Smoke) async throws {
        let fixture = try fixture(root: root, name: "source-substitution",
                                  dictionaryID: "11111111-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let source = fixture.result.stagingRootURL.appendingPathComponent(fixture.result.verifiedDirectoryComponent,
                                                                            isDirectory: true)
        let retainedOriginal = fixture.result.stagingRootURL.appendingPathComponent("retained-original", isDirectory: true)
        OpenResourceInstallationCoordinator.setBeforeRenameForResourceTest {
            try FileManager.default.moveItem(at: source, to: retainedOriginal)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        }
        defer { OpenResourceInstallationCoordinator.clearBeforeRenameForResourceTest() }
        do {
            _ = try await fixture.coordinator.install(fixture.result, dictionariesRoot: fixture.dictionaries,
                                                       catalogStore: fixture.catalog)
            throw SmokeFailure(message: "source substitution unexpectedly succeeded")
        } catch let error as OpenResourceInstallationError {
            try smoke.check("source substitution exact error", error == .finalPublishedButDirectoryIdentityMismatch)
        }
        let final = fixture.dictionaries.appendingPathComponent(fixture.identity.dictionaryID, isDirectory: true)
        try smoke.check("source substitution retains final object", FileManager.default.fileExists(atPath: final.path))
        try smoke.check("source substitution retains original object", FileManager.default.fileExists(atPath: retainedOriginal.path))
        try smoke.check("source substitution does not commit catalog", fixture.catalog.load().dictionaries.isEmpty)
    }

    @MainActor
    private static func testPayloadInPlaceTamper(root: URL, smoke: inout Smoke) async throws {
        let fixture = try fixture(root: root, name: "payload-tamper",
                                  dictionaryID: "22222222-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let payload = fixture.result.verifiedFileURL
        let before = try fileIdentity(at: payload)
        OpenResourceInstallationCoordinator.setBeforeRenameForResourceTest {
            let fd = payload.path.withCString { Darwin.open($0, O_WRONLY | O_CLOEXEC) }
            guard fd >= 0 else { throw SmokeFailure(message: "payload open") }
            defer { Darwin.close(fd) }
            let replacement = Array("Synthetic mDX payload".utf8)
            let written = replacement.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }
            guard written == replacement.count else { throw SmokeFailure(message: "payload pwrite") }
            guard Darwin.fsync(fd) == 0 else { throw SmokeFailure(message: "payload fsync") }
        }
        defer { OpenResourceInstallationCoordinator.clearBeforeRenameForResourceTest() }
        do {
            _ = try await fixture.coordinator.install(fixture.result, dictionariesRoot: fixture.dictionaries,
                                                       catalogStore: fixture.catalog)
            throw SmokeFailure(message: "payload tamper unexpectedly succeeded")
        } catch let error as OpenResourceInstallationError {
            try smoke.check("payload tamper exact error", error == .filesystemPublishedButIdentityUnconfirmed)
        }
        let finalPayload = fixture.dictionaries.appendingPathComponent(fixture.identity.dictionaryID)
            .appendingPathComponent(OpenResourceInstallationIdentity.payloadComponent)
        let after = try fileIdentity(at: finalPayload)
        try smoke.check("payload tamper preserves inode", before.inode == after.inode)
        try smoke.check("payload tamper preserves byte count", before.size == after.size)
        try smoke.check("payload tamper retains final object", FileManager.default.fileExists(atPath: finalPayload.path))
        try smoke.check("payload tamper does not commit catalog", fixture.catalog.load().dictionaries.isEmpty)
    }

    private static func fileIdentity(at url: URL) throws -> (inode: UInt64, size: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw SmokeFailure(message: "file identity")
        }
        return (inode, size)
    }
}
