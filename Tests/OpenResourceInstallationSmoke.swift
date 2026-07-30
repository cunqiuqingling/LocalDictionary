import CryptoKit
import Darwin
import Dispatch
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
        try smoke.check("new open resource starts disabled", !descriptor.enabled)
        try smoke.check("catalog sidecar relative", descriptor.openResourceMetadata?.sidecarRelativePath == "Dictionaries/\(identity.dictionaryID)/resource-installation.json")
        try smoke.check("final payload", FileManager.default.fileExists(atPath: dictionaries.appendingPathComponent(identity.dictionaryID).appendingPathComponent("payload.mdx").path))
        try smoke.check("final sidecar", FileManager.default.fileExists(atPath: dictionaries.appendingPathComponent(identity.dictionaryID).appendingPathComponent("resource-installation.json").path))
        try smoke.check("catalog v2", catalog.loadResult().provenance == .loadedPrimary)
        try await smoke.expect("resource single instance") {
            _ = try await coordinator.install(result, dictionariesRoot: dictionaries, catalogStore: catalog)
        }
        let publicationID = "99999999-2222-4333-8444-555555555555"
        _ = try catalog.mutate { latest, _ in
            guard let index = latest.dictionaries.firstIndex(where: {
                $0.dictionaryID == identity.dictionaryID
            }) else { throw SmokeFailure(message: "installed descriptor missing") }
            latest.dictionaries[index].enabled = true
            latest.dictionaries[index].state = .ready
            latest.dictionaries[index].indexMetadata.schemaVersion = 1
            latest.dictionaries[index].indexMetadata.entryCount = 1
            latest.dictionaries[index].indexMetadata.indexFileSize = 4096
            latest.dictionaries[index].indexMetadata.indexedAt = Date(timeIntervalSince1970: 2)
            let relative = "Dictionaries/\(identity.dictionaryID)/index/dictionary.\(publicationID).sqlite"
            latest.dictionaries[index].relativePaths.index = relative
            latest.dictionaries[index].publishedIndexIdentity = PublishedIndexIdentity(
                indexPublicationID: publicationID,
                indexSHA256: String(repeating: "c", count: 64),
                indexFileSize: 4096,
                sourceSHA256: digest,
                sourceFileSize: UInt64(payload.count),
                schemaVersion: 1,
                entryCount: 1,
                indexedAt: Date(timeIntervalSince1970: 2),
                relativePath: relative
            )
        }
        let updatePayload = Data("synthetic mDX payload revision two".utf8)
        let updateDigest = SHA256.hash(data: updatePayload)
            .map { String(format: "%02x", $0) }.joined()
        let updateIdentity = try OpenResourceInstallationIdentity(
            dictionaryID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            resourceID: identity.resourceID,
            resourceRevision: 2,
            resourceVersion: "2.0",
            manifestVersion: 2,
            manifestSHA256: String(repeating: "b", count: 64),
            verifiedKeyID: "test-key",
            payloadSHA256: updateDigest,
            payloadBytes: UInt64(updatePayload.count),
            languages: ["en"],
            license: identity.license,
            sourceProject: identity.sourceProject,
            officialPageReference: identity.officialPageReference,
            expectedEntryCount: identity.expectedEntryCount,
            installedAt: Date(timeIntervalSince1970: 3),
            displayName: "Synthetic Open v2"
        )
        let updatePlan = ResourcePayloadDownloadPlan(
            resourceID: updateIdentity.resourceID,
            resourceRevision: updateIdentity.resourceRevision,
            downloadURL: URL(string: "https://example.test/payload-v2.mdx")!,
            signedFileName: "payload-v2.mdx",
            expectedBytes: UInt64(updatePayload.count),
            maximumBytes: UInt64(updatePayload.count),
            expectedSHA256: updateDigest,
            allowedHosts: ["example.test"],
            stagingRoot: staging,
            policy: policy,
            installationIdentity: updateIdentity
        )
        let updateOperation = try ResourcePayloadStagingStore().prepare(plan: updatePlan)
        _ = try updateOperation.append(
            updatePayload,
            maximumBytes: UInt64(updatePayload.count),
            expectedBytes: UInt64(updatePayload.count)
        )
        let updateCompleted = try updateOperation.finish(
            expectedBytes: UInt64(updatePayload.count),
            expectedSHA256: updateDigest
        )
        let updateResult = VerifiedPayloadStagingResult(
            resourceID: updateIdentity.resourceID,
            resourceRevision: updateIdentity.resourceRevision,
            operationID: updateOperation.operationID,
            verifiedFileURL: updateOperation.verifiedFile,
            signedFileName: updatePlan.signedFileName,
            actualByteCount: updateCompleted.bytes,
            verifiedSHA256: updateCompleted.digest,
            stagingRootURL: updateOperation.stagingRootURL,
            verifiedDirectoryComponent: updateOperation.verifiedDirectoryComponent,
            payloadComponent: updateOperation.publishedPayloadComponent,
            sidecarComponent: updateOperation.publishedSidecarComponent,
            installationIdentity: updateIdentity
        )
        let updateDescriptor = try await coordinator.install(
            updateResult,
            dictionariesRoot: dictionaries,
            catalogStore: catalog,
            mode: .update(replacingDictionaryID: identity.dictionaryID)
        )
        let transition = try catalog.load().validated()
        try smoke.check("update keeps both identity-bound versions",
                        transition.dictionaries.count == 2)
        try smoke.check("update keeps current version ready and enabled",
                        transition.dictionaries.contains {
                            $0.dictionaryID == identity.dictionaryID &&
                                $0.state == .ready && $0.enabled
                        })
        try smoke.check("update replacement starts disabled and pending",
                        updateDescriptor.state == .pendingIndex && !updateDescriptor.enabled)
        try smoke.check("update preserves query sort position",
                        updateDescriptor.sortPosition == descriptor.sortPosition)
        try smoke.check("update uses signed display name",
                        updateDescriptor.displayName == "Synthetic Open v2")
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
        try await testFinalPublicationUsesExclusivePermit(root: root, smoke: &smoke)
        try await testCancelledPermitDoesNotPublish(root: root, smoke: &smoke)
        print("Open resource installation smoke passed (\(smoke.assertions) total runtime assertions)")
    }

    private struct Fixture {
        let identity: OpenResourceInstallationIdentity
        let result: VerifiedPayloadStagingResult
        let catalog: DictionaryCatalogStore
        let coordinator: OpenResourceInstallationCoordinator
        let lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator
        let dictionaries: URL
    }

    /// Test-only deterministic bridge from the synchronous rename hook to async test code.
    private final class PermitInterlock: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)

        func pauseAtRename() throws {
            entered.signal()
            guard released.wait(timeout: .now() + 2) == .success else {
                throw SmokeFailure(message: "install permit interlock timed out")
            }
        }

        func waitForRename() async throws {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    continuation.resume(returning: entered.wait(timeout: .now() + 2))
                }
            }
            guard result == .success else { throw SmokeFailure(message: "rename hook not reached") }
        }

        func releaseRename() { released.signal() }
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
        let lifecycleCoordinator = ManagedDictionaryLifecycleCoordinator()
        return Fixture(identity: identity, result: result, catalog: catalog,
                       coordinator: OpenResourceInstallationCoordinator(
                           lifecycleCoordinator: lifecycleCoordinator
                       ), lifecycleCoordinator: lifecycleCoordinator, dictionaries: dictionaries)
    }

    @MainActor
    private static func testFinalPublicationUsesExclusivePermit(root: URL,
                                                                 smoke: inout Smoke) async throws {
        let fixture = try fixture(root: root, name: "permit-boundary",
                                  dictionaryID: "33333333-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let interlock = PermitInterlock()
        OpenResourceInstallationCoordinator.setBeforeRenameForResourceTest {
            try interlock.pauseAtRename()
        }
        defer { OpenResourceInstallationCoordinator.clearBeforeRenameForResourceTest() }
        let install = Task {
            try await fixture.coordinator.install(fixture.result, dictionariesRoot: fixture.dictionaries,
                                                  catalogStore: fixture.catalog)
        }
        try await interlock.waitForRename()
        let final = fixture.dictionaries.appendingPathComponent(fixture.identity.dictionaryID,
                                                                 isDirectory: true)
        try smoke.check("final directory is not published before rename",
                        !FileManager.default.fileExists(atPath: final.path))
        let removal = Task {
            try await fixture.lifecycleCoordinator.acquireExclusiveOperation(
                for: fixture.identity.dictionaryID, operation: .remove
            )
        }
        while await fixture.lifecycleCoordinator.snapshot(for: fixture.identity.dictionaryID)?.queuedOperationCount != 1 {
            await Task.yield()
        }
        interlock.releaseRename()
        let descriptor = try await install.value
        let permit = try await removal.value
        try smoke.check("install final publish holds keyed exclusive permit",
                        FileManager.default.fileExists(atPath: final.path) && !descriptor.enabled)
        await fixture.lifecycleCoordinator.complete(permit, disposition: .retired)
    }

    @MainActor
    private static func testCancelledPermitDoesNotPublish(root: URL,
                                                           smoke: inout Smoke) async throws {
        let fixture = try fixture(root: root, name: "permit-cancel",
                                  dictionaryID: "44444444-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let held = try await fixture.lifecycleCoordinator.acquireExclusiveOperation(
            for: fixture.identity.dictionaryID, operation: .remove
        )
        let install = Task {
            try await fixture.coordinator.install(fixture.result, dictionariesRoot: fixture.dictionaries,
                                                  catalogStore: fixture.catalog)
        }
        while await fixture.lifecycleCoordinator.snapshot(for: fixture.identity.dictionaryID)?.queuedOperationCount != 1 {
            await Task.yield()
        }
        install.cancel()
        let result = await install.result
        if case .failure(let error as ManagedDictionaryLifecycleError) = result {
            try smoke.check("cancelled install waiter returns fixed error",
                            error == .lifecycleOperationCancelled)
        } else {
            throw SmokeFailure(message: "cancelled install unexpectedly published")
        }
        let final = fixture.dictionaries.appendingPathComponent(fixture.identity.dictionaryID,
                                                                 isDirectory: true)
        try smoke.check("cancelled install before permit leaves no final directory",
                        !FileManager.default.fileExists(atPath: final.path))
        try smoke.check("cancelled install before permit leaves Catalog unchanged",
                        fixture.catalog.load().dictionaries.isEmpty)
        await fixture.lifecycleCoordinator.complete(held, disposition: .available(incrementGeneration: false))
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
