import CryptoKit
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
        let coordinator = OpenResourceInstallationCoordinator()
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
        print("Open resource installation smoke passed (\(smoke.assertions) total runtime assertions)")
    }
}
