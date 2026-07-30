import Foundation

private enum ImportSmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    case injectedPublicationFailure

    var description: String {
        switch self {
        case .failed(let message): return message
        case .injectedPublicationFailure: return "injected publication failure"
        }
    }
}

@main
@MainActor
enum DictionaryImportSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-ImportSmoke-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try makeFixture(at: root.appendingPathComponent("fixture", isDirectory: true))
        try testSinglePreviewDoesNotInspectSiblingMDD(fixture: fixture)
        try testFolderSelectionRejected(fixture: fixture)
        try await testImportWithoutMDD(fixture: fixture, root: root)
        try await testCancelledImport(fixture: fixture, root: root)
        try await testInsufficientSpace(fixture: fixture, root: root)
        try await testMissingSourceRollback(root: root)
        try await testDuplicateDetection(fixture: fixture, root: root)
        try await testRelativeCatalogAndManagedFiles(fixture: fixture, root: root)
        try await testStagingRollback(fixture: fixture, root: root)
        try await testDifferentContentWithSameName(root: root)
        try await testConcurrentCatalogMutationIsRejected(fixture: fixture, root: root)
        try testNoIndexArtifacts(root: root)
        print("DictionaryImportSmoke PASS (12/12)")
    }

    private struct Fixture {
        let directory: URL
        let alphaMDX: URL
        let gammaMDX: URL
    }

    private static func makeFixture(at directory: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alpha = directory.appendingPathComponent("Alpha Dictionary.mdx")
        let beta = directory.appendingPathComponent("Beta Dictionary.mdx")
        let gamma = directory.appendingPathComponent("Gamma Dictionary.mdx")
        try writeFakeMDX(alpha, title: "Alpha Dictionary")
        try writeFakeMDX(beta, title: "Beta Dictionary")
        try writeFakeMDX(gamma, title: "Gamma Dictionary")
        try Data(repeating: 0x41, count: 128).write(
            to: directory.appendingPathComponent("Alpha Dictionary.mdd"))
        try Data(repeating: 0x42, count: 96).write(
            to: directory.appendingPathComponent("Beta Dictionary.mdd"))
        try Data(repeating: 0x43, count: 80).write(
            to: directory.appendingPathComponent("Beta Dictionary.1.mdd"))
        try Data(repeating: 0x44, count: 64).write(
            to: directory.appendingPathComponent("Unrelated Resource.mdd"))
        return Fixture(directory: directory, alphaMDX: alpha, gammaMDX: gamma)
    }

    private static func testSinglePreviewDoesNotInspectSiblingMDD(fixture: Fixture) throws {
        let previews = try MDictImportInspector().previews(for: fixture.alphaMDX)
        try expect(previews.count == 1, "single MDX did not produce one preview")
        guard let preview = previews.first else { return }
        try expect(preview.displayName == "Alpha Dictionary", "header title was not used")
        try expect(preview.header.engineVersion == "2.0", "MDict version missing")
        try expect(preview.header.encoding == "UTF-8", "encoding missing")
        try expect(preview.header.compression == .compressed, "compression marker missing")
        try expect(!preview.header.isEncrypted, "unencrypted fixture reported encryption")
        try expect(preview.mddCandidates.isEmpty,
                   "single-MDX import inspected a sibling MDD")
        try expect(preview.automaticallySelectedMDDIDs.isEmpty,
                   "single-MDX import selected an unsupported MDD")
        try expect(preview.queryLevel == .normal && preview.enabled &&
                   preview.state == .pendingIndex,
                   "preview defaults changed")
    }

    private static func testFolderSelectionRejected(fixture: Fixture) throws {
        do {
            _ = try MDictImportInspector().previews(for: fixture.directory)
            throw ImportSmokeFailure.failed("folder selection unexpectedly scanned MDX files")
        } catch DictionaryImportError.invalidSelection {
            // M23 reads only the one MDX explicitly selected by the user.
        }
    }

    private static func testImportWithoutMDD(fixture: Fixture, root: URL) async throws {
        let preview = try onlyPreview(fixture.gammaMDX)
        let environment = makeEnvironment(root: root, name: "without-mdd")
        let updated = try await environment.service.importSelections(
            [DictionaryImportSelection(preview: preview, selectedMDDIDs: [])],
            into: .empty(now: fixedDate), now: fixedDate)
        try expect(updated.dictionaries.count == 1, "MDX-only import failed")
        try expect(updated.dictionaries[0].relativePaths.resources.isEmpty,
                   "MDX-only import wrote a resource path")
    }

    private static func testCancelledImport(fixture: Fixture, root: URL) async throws {
        let preview = try onlyPreview(fixture.alphaMDX)
        let environment = makeEnvironment(root: root, name: "cancelled")
        let cancellationToken = DictionaryImportCancellationToken()
        cancellationToken.cancel()
        do {
            _ = try await environment.service.importSelections(
                [DictionaryImportSelection(preview: preview,
                                           selectedMDDIDs: preview.automaticallySelectedMDDIDs)],
                into: .empty(now: fixedDate), cancellationToken: cancellationToken,
                now: fixedDate)
            throw ImportSmokeFailure.failed("cancelled import unexpectedly succeeded")
        } catch DictionaryImportError.cancelled {
            // Expected.
        }
        try expect(environment.store.load().dictionaries.isEmpty,
                   "cancelled import wrote a Catalog record")
        try expect(!hasManagedDictionaryDirectories(environment.dictionariesRoot),
                   "cancelled import left managed files")
    }

    private static func testInsufficientSpace(fixture: Fixture, root: URL) async throws {
        let preview = try onlyPreview(fixture.alphaMDX)
        let hooks = DictionaryImportServiceHooks(
            availableCapacity: { _ in 0 }, beforeCopy: { _ in }, beforePublish: {})
        let environment = makeEnvironment(root: root, name: "no-space", hooks: hooks)
        do {
            _ = try await environment.service.importSelections(
                [DictionaryImportSelection(preview: preview, selectedMDDIDs: [])],
                into: .empty(now: fixedDate), now: fixedDate)
            throw ImportSmokeFailure.failed("insufficient-space import unexpectedly succeeded")
        } catch DictionaryImportError.insufficientDiskSpace {
            // Expected.
        }
        try expect(environment.store.load().dictionaries.isEmpty,
                   "insufficient-space failure wrote a Catalog record")
    }

    private static func testMissingSourceRollback(root: URL) async throws {
        let directory = root.appendingPathComponent("missing-source-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Disappearing.mdx")
        try writeFakeMDX(source, title: "Disappearing")
        let preview = try onlyPreview(source)
        let hooks = DictionaryImportServiceHooks(
            availableCapacity: { _ in UInt64.max },
            beforeCopy: { url in try FileManager.default.removeItem(at: url) },
            beforePublish: {})
        let environment = makeEnvironment(root: root, name: "source-missing", hooks: hooks)
        do {
            _ = try await environment.service.importSelections(
                [DictionaryImportSelection(preview: preview, selectedMDDIDs: [])],
                into: .empty(now: fixedDate), now: fixedDate)
            throw ImportSmokeFailure.failed("missing-source import unexpectedly succeeded")
        } catch DictionaryImportError.sourceMissing {
            // Expected.
        }
        try expect(environment.store.load().dictionaries.isEmpty,
                   "missing-source failure wrote a Catalog record")
        try expect(!hasManagedDictionaryDirectories(environment.dictionariesRoot),
                   "missing-source failure published files")
    }

    private static func testDuplicateDetection(fixture: Fixture, root: URL) async throws {
        let preview = try onlyPreview(fixture.alphaMDX)
        let environment = makeEnvironment(root: root, name: "duplicate")
        let selection = DictionaryImportSelection(preview: preview, selectedMDDIDs: [])
        let first = try await environment.service.importSelections([selection],
                                                                    into: .empty(now: fixedDate),
                                                                    now: fixedDate)
        do {
            _ = try await environment.service.importSelections([selection], into: first,
                                                                now: fixedDate)
            throw ImportSmokeFailure.failed("duplicate content was imported twice")
        } catch DictionaryImportError.duplicate {
            // Expected.
        }
        try expect(environment.store.load().dictionaries.count == 1,
                   "duplicate attempt changed the Catalog")
        let independent = try await environment.service.importSelections(
            [selection],
            into: first,
            allowDuplicateContent: true,
            now: fixedDate.addingTimeInterval(1)
        )
        try expect(independent.dictionaries.count == 2,
                   "explicit independent duplicate import was not honored")
    }

    private static func testRelativeCatalogAndManagedFiles(fixture: Fixture,
                                                           root: URL) async throws {
        let preview = try onlyPreview(fixture.alphaMDX)
        let environment = makeEnvironment(root: root, name: "relative")
        let updated = try await environment.service.importSelections(
            [DictionaryImportSelection(preview: preview,
                                       selectedMDDIDs: preview.automaticallySelectedMDDIDs)],
            into: .empty(now: fixedDate), now: fixedDate)
        guard let descriptor = updated.dictionaries.first,
              let relativeMDX = descriptor.relativePaths.dictionary else {
            throw ImportSmokeFailure.failed("managed descriptor missing")
        }
        try expect(!NSString(string: relativeMDX).isAbsolutePath,
                   "Catalog persisted an absolute MDX path")
        try expect(descriptor.relativePaths.resources.allSatisfy {
            !NSString(string: $0).isAbsolutePath
        }, "Catalog persisted an absolute MDD path")
        try expect(descriptor.sourceKind == .managedLocal &&
                   descriptor.state == .pendingIndex && descriptor.enabled,
                   "managed descriptor defaults are incorrect")
        try expect(descriptor.formatterIdentifier ==
                   DictionaryFormatterIdentifier.genericMDictV1,
                   "new imports must use the canonical generic formatter identifier")
        try expect(descriptor.relativePaths.index == nil &&
                   descriptor.indexMetadata.indexedAt == nil,
                   "import unexpectedly created index metadata")
        let managedMDX = environment.applicationSupportRoot.appendingPathComponent(relativeMDX)
        try expect(FileManager.default.fileExists(atPath: managedMDX.path),
                   "managed MDX was not published")
    }

    private static func testStagingRollback(fixture: Fixture, root: URL) async throws {
        let preview = try onlyPreview(fixture.alphaMDX)
        let hooks = DictionaryImportServiceHooks(
            availableCapacity: { _ in UInt64.max }, beforeCopy: { _ in },
            beforePublish: { throw ImportSmokeFailure.injectedPublicationFailure })
        let environment = makeEnvironment(root: root, name: "staging-failure", hooks: hooks)
        do {
            _ = try await environment.service.importSelections(
                [DictionaryImportSelection(preview: preview, selectedMDDIDs: [])],
                into: .empty(now: fixedDate), now: fixedDate)
            throw ImportSmokeFailure.failed("injected staging failure unexpectedly succeeded")
        } catch DictionaryImportError.publicationFailed {
            // Expected.
        }
        try expect(environment.store.load().dictionaries.isEmpty,
                   "staging failure wrote a Catalog record")
        try expect(!hasManagedDictionaryDirectories(environment.dictionariesRoot),
                   "staging failure left a published dictionary")
        try expect(!FileManager.default.fileExists(
            atPath: environment.dictionariesRoot.appendingPathComponent(".staging").path),
                   "staging failure did not clean staging")
    }

    private static func testDifferentContentWithSameName(root: URL) async throws {
        let firstDirectory = root.appendingPathComponent("same-name-a", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("same-name-b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstURL = firstDirectory.appendingPathComponent("Same Name.mdx")
        let secondURL = secondDirectory.appendingPathComponent("Same Name.mdx")
        try writeFakeMDX(firstURL, title: "Same Name", payloadByte: 0x51)
        try writeFakeMDX(secondURL, title: "Same Name", payloadByte: 0x52)
        let firstPreview = try onlyPreview(firstURL)
        let secondPreview = try onlyPreview(secondURL)
        try expect(firstPreview.mdxSHA256 != secondPreview.mdxSHA256,
                   "different same-name files produced the same digest")
        let environment = makeEnvironment(root: root, name: "same-name")
        let first = try await environment.service.importSelections(
            [DictionaryImportSelection(preview: firstPreview, selectedMDDIDs: [])],
            into: .empty(now: fixedDate), now: fixedDate)
        let second = try await environment.service.importSelections(
            [DictionaryImportSelection(preview: secondPreview, selectedMDDIDs: [])],
            into: first, now: fixedDate.addingTimeInterval(1))
        try expect(second.dictionaries.count == 2,
                   "same-name files with different content were rejected")
    }

    private static func testConcurrentCatalogMutationIsRejected(
        fixture: Fixture,
        root: URL
    ) async throws {
        let enteredWorker = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let hooks = DictionaryImportServiceHooks(
            availableCapacity: { _ in UInt64.max },
            beforeCopy: { _ in
                enteredWorker.signal()
                _ = releaseWorker.wait(timeout: .now() + 5)
            },
            beforePublish: {}
        )
        let environment = makeEnvironment(root: root, name: "concurrent", hooks: hooks)
        let preview = try onlyPreview(fixture.gammaMDX)
        let selection = DictionaryImportSelection(preview: preview, selectedMDDIDs: [])
        let firstImport = Task { @MainActor in
            try await environment.service.importSelections(
                [selection], into: .empty(now: fixedDate), now: fixedDate)
        }
        await Task.yield()
        try expect(enteredWorker.wait(timeout: .now() + 5) == .success,
                   "first import did not enter the file worker")

        do {
            _ = try await environment.service.importSelections(
                [selection], into: .empty(now: fixedDate), now: fixedDate)
            throw ImportSmokeFailure.failed("concurrent import unexpectedly reached Catalog save")
        } catch DictionaryImportError.importAlreadyInProgress {
            // Expected: one main-actor coordinator owns Catalog mutation.
        }
        releaseWorker.signal()
        let updated = try await firstImport.value
        try expect(updated.dictionaries.count == 1 &&
                   environment.store.load().dictionaries.count == 1,
                   "serialized import did not commit exactly one Catalog record")
    }

    private static func testNoIndexArtifacts(root: URL) throws {
        let enumerator = FileManager.default.enumerator(at: root,
                                                        includingPropertiesForKeys: nil)
        let indexArtifacts = (enumerator?.allObjects as? [URL] ?? []).filter {
            ["sqlite", "sqlite-wal", "sqlite-shm", "building"].contains($0.pathExtension)
        }
        try expect(indexArtifacts.isEmpty, "import smoke created an index artifact")
    }

    private struct Environment {
        let applicationSupportRoot: URL
        let dictionariesRoot: URL
        let store: DictionaryCatalogStore
        let service: DictionaryImportService
    }

    private static func makeEnvironment(
        root: URL,
        name: String,
        hooks: DictionaryImportServiceHooks = DictionaryImportServiceHooks(
            availableCapacity: { _ in UInt64.max }, beforeCopy: { _ in }, beforePublish: {})
    ) -> Environment {
        let appRoot = root.appendingPathComponent(name, isDirectory: true)
        let dictionaries = appRoot.appendingPathComponent("Dictionaries", isDirectory: true)
        let store = DictionaryCatalogStore(directoryURL:
            appRoot.appendingPathComponent("Catalog", isDirectory: true))
        let service = DictionaryImportService(
            dictionariesRootURL: dictionaries,
            catalogStore: store,
            hooks: hooks
        )
        return Environment(applicationSupportRoot: appRoot, dictionariesRoot: dictionaries,
                           store: store, service: service)
    }

    private static func onlyPreview(_ url: URL) throws -> DictionaryImportPreview {
        let previews = try MDictImportInspector().previews(for: url)
        guard previews.count == 1, let preview = previews.first else {
            throw ImportSmokeFailure.failed("expected one preview")
        }
        return preview
    }

    private static func writeFakeMDX(_ url: URL, title: String,
                                     payloadByte: UInt8 = 0x50) throws {
        let xml = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encoding=\"UTF-8\" Encrypted=\"No\" Title=\"\(title)\"/>"
        guard let header = xml.data(using: .utf16LittleEndian) else {
            throw ImportSmokeFailure.failed("failed to encode fixture header")
        }
        var data = Data()
        let size = UInt32(header.count)
        data.append(contentsOf: [
            UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff)
        ])
        data.append(header)
        data.append(Data(repeating: 0, count: 4)) // Header checksum.
        data.append(Data(repeating: 0, count: 40)) // Version 2 key-block header.
        data.append(Data(repeating: 0, count: 4)) // Key-block header checksum.
        data.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 0]) // zlib marker + checksum.
        data.append(Data(repeating: payloadByte, count: 256))
        try data.write(to: url)
    }

    private static func hasManagedDictionaryDirectories(_ root: URL) -> Bool {
        guard let values = try? FileManager.default.contentsOfDirectory(at: root,
                                                                        includingPropertiesForKeys: nil)
        else { return false }
        return values.contains { !$0.lastPathComponent.hasPrefix(".") }
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw ImportSmokeFailure.failed(message) }
    }
}
