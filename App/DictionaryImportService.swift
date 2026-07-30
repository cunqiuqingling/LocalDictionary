import CryptoKit
import Darwin
import Foundation

struct DictionaryImportServiceHooks: Sendable {
    let availableCapacity: @Sendable (URL) throws -> UInt64
    let beforeCopy: @Sendable (URL) throws -> Void
    let beforePublish: @Sendable () throws -> Void

    static let live = DictionaryImportServiceHooks(
        availableCapacity: { url in
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 {
                return UInt64(capacity)
            }
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            return (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        },
        beforeCopy: { _ in },
        beforePublish: {}
    )
}

/// Executes only staged file-system work. It owns no mutable reference state,
/// Catalog store, or AppKit object and can therefore cross execution domains.
struct DictionaryImportFileWorker: Sendable {
    typealias ProgressHandler = @Sendable (UInt64, UInt64) -> Void

    let dictionariesRootURL: URL
    let hooks: DictionaryImportServiceHooks

    func execute(
        plan: DictionaryImportPlan,
        cancellationToken: DictionaryImportCancellationToken,
        progress: ProgressHandler?
    ) -> DictionaryImportWorkerOutcome {
        do {
            return .success(try executeThrowing(
                plan: plan,
                cancellationToken: cancellationToken,
                progress: progress
            ))
        } catch let error as DictionaryImportError {
            return .failure(error)
        } catch {
            return .failure(.publicationFailed)
        }
    }

    func rollbackPublished(_ result: DictionaryImportExecutionResult) {
        let fileManager = FileManager()
        for item in result.publishedItems {
            try? fileManager.removeItem(at: item.directoryURL)
        }
    }

    private func executeThrowing(
        plan: DictionaryImportPlan,
        cancellationToken: DictionaryImportCancellationToken,
        progress: ProgressHandler?
    ) throws -> DictionaryImportExecutionResult {
        let fileManager = FileManager()
        if cancellationToken.isCancelled { throw DictionaryImportError.cancelled }

        try fileManager.createDirectory(at: dictionariesRootURL,
                                        withIntermediateDirectories: true)
        let availableBytes = try hooks.availableCapacity(dictionariesRootURL)
        guard availableBytes >= plan.requiredDiskBytes else {
            throw DictionaryImportError.insufficientDiskSpace(
                required: plan.requiredDiskBytes,
                available: availableBytes
            )
        }

        let stagingParent = dictionariesRootURL.appendingPathComponent(".staging",
                                                                       isDirectory: true)
        let operationURL = stagingParent.appendingPathComponent(plan.operationID,
                                                                 isDirectory: true)
        try fileManager.createDirectory(at: operationURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: operationURL)
            try? fileManager.removeItem(at: stagingParent)
        }

        var completedBytes: UInt64 = 0
        var pending: [(item: DictionaryImportPlanItem, staged: URL, final: URL)] = []

        for item in plan.items {
            if cancellationToken.isCancelled { throw DictionaryImportError.cancelled }
            let dictionaryID = item.descriptor.dictionaryID
            let stagedDirectory = operationURL.appendingPathComponent(dictionaryID,
                                                                       isDirectory: true)
            let finalDirectory = dictionariesRootURL.appendingPathComponent(dictionaryID,
                                                                              isDirectory: true)
            guard !fileManager.fileExists(atPath: finalDirectory.path) else {
                throw DictionaryImportError.publicationFailed
            }
            try fileManager.createDirectory(at: stagedDirectory,
                                            withIntermediateDirectories: true)

            for file in item.files {
                let destination = stagedDirectory.appendingPathComponent(file.destinationFileName)
                let copiedDigest = try copyFile(
                    file,
                    to: destination,
                    fileManager: fileManager,
                    cancellationToken: cancellationToken,
                    completedBytes: &completedBytes,
                    totalBytes: plan.totalCopyBytes,
                    progress: progress
                )
                if let expectedSHA256 = file.expectedSHA256,
                   copiedDigest != expectedSHA256 {
                    throw DictionaryImportError.sourceChanged(file.destinationFileName)
                }
            }
            pending.append((item, stagedDirectory, finalDirectory))
        }

        if cancellationToken.isCancelled { throw DictionaryImportError.cancelled }

        var published: [DictionaryImportPublishedItem] = []
        do {
            try hooks.beforePublish()
            for item in pending {
                try renameAtomically(source: item.staged, destination: item.final)
                published.append(DictionaryImportPublishedItem(
                    dictionaryID: item.item.descriptor.dictionaryID,
                    directoryURL: item.final
                ))
            }
            return DictionaryImportExecutionResult(
                descriptors: pending.map(\.item.descriptor),
                publishedItems: published
            )
        } catch {
            for item in published { try? fileManager.removeItem(at: item.directoryURL) }
            if let importError = error as? DictionaryImportError { throw importError }
            throw DictionaryImportError.publicationFailed
        }
    }

    private func copyFile(
        _ file: DictionaryImportPlanFile,
        to destination: URL,
        fileManager: FileManager,
        cancellationToken: DictionaryImportCancellationToken,
        completedBytes: inout UInt64,
        totalBytes: UInt64,
        progress: ProgressHandler?
    ) throws -> String {
        try hooks.beforeCopy(file.sourceURL)
        guard fileManager.fileExists(atPath: file.sourceURL.path),
              fileManager.isReadableFile(atPath: file.sourceURL.path) else {
            throw DictionaryImportError.sourceMissing(file.destinationFileName)
        }
        let values = try file.sourceURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let sourceFileSize = values.fileSize, sourceFileSize >= 0,
              UInt64(sourceFileSize) == file.expectedSize else {
            throw DictionaryImportError.sourceChanged(file.destinationFileName)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw DictionaryImportError.copyVerificationFailed(file.destinationFileName)
        }

        let input = try FileHandle(forReadingFrom: file.sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        while true {
            if cancellationToken.isCancelled { throw DictionaryImportError.cancelled }
            let data = try input.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            hasher.update(data: data)
            completedBytes &+= UInt64(data.count)
            progress?(completedBytes, totalBytes)
        }
        try output.synchronize()
        let copiedValues = try destination.resourceValues(forKeys: [.fileSizeKey])
        guard let copiedFileSize = copiedValues.fileSize, copiedFileSize >= 0,
              UInt64(copiedFileSize) == file.expectedSize else {
            throw DictionaryImportError.copyVerificationFailed(file.destinationFileName)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func renameAtomically(source: URL, destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

/// Main-actor coordinator. Catalog mutation is serialized here; detached work
/// receives only the immutable plan, value worker, cancellation token and
/// `@Sendable` progress callback.
@MainActor
final class DictionaryImportService {
    typealias ProgressHandler = DictionaryImportFileWorker.ProgressHandler

    let dictionariesRootURL: URL
    let catalogStore: DictionaryCatalogStore

    private let fileWorker: DictionaryImportFileWorker
    private let identifierProvider: () -> UUID
    private var importInProgress = false

    init(
        dictionariesRootURL: URL = DictionaryImportService.defaultDictionariesRootURL(),
        catalogStore: DictionaryCatalogStore,
        hooks: DictionaryImportServiceHooks = .live,
        identifierProvider: @escaping () -> UUID = UUID.init
    ) {
        self.dictionariesRootURL = dictionariesRootURL
        self.catalogStore = catalogStore
        fileWorker = DictionaryImportFileWorker(dictionariesRootURL: dictionariesRootURL,
                                                hooks: hooks)
        self.identifierProvider = identifierProvider
    }

    nonisolated static func defaultApplicationSupportRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("LocalDictionary", isDirectory: true)
    }

    nonisolated static func defaultDictionariesRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        defaultApplicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent("Dictionaries", isDirectory: true)
    }

    func duplicateDescriptor(for preview: DictionaryImportPreview,
                             in catalog: DictionaryCatalog) -> DictionaryDescriptor? {
        catalog.dictionaries.first {
            $0.sourceKind == .managedLocal &&
                $0.indexMetadata.sourceSHA256 == preview.mdxSHA256
        }
    }

    func importSelections(
        _ selections: [DictionaryImportSelection],
        into catalog: DictionaryCatalog,
        cancellationToken: DictionaryImportCancellationToken = DictionaryImportCancellationToken(),
        progress: ProgressHandler? = nil,
        allowDuplicateContent: Bool = false,
        now: Date = Date()
    ) async throws -> DictionaryCatalog {
        guard !importInProgress else { throw DictionaryImportError.importAlreadyInProgress }
        importInProgress = true
        defer { importInProgress = false }

        let plan = try makePlan(
            selections,
            catalog: catalog,
            allowDuplicateContent: allowDuplicateContent,
            now: now
        )
        let worker = fileWorker
        let outcome = await Task.detached(priority: .userInitiated) {
            worker.execute(plan: plan,
                           cancellationToken: cancellationToken,
                           progress: progress)
        }.value

        switch outcome {
        case .failure(let error):
            throw error
        case .success(let executionResult):
            if cancellationToken.isCancelled {
                await Task.detached(priority: .utility) {
                    worker.rollbackPublished(executionResult)
                }.value
                throw DictionaryImportError.cancelled
            }

            do {
                let mutation = try catalogStore.mutate { latest, _ in
                    for descriptor in executionResult.descriptors {
                        guard !latest.dictionaries.contains(where: { $0.dictionaryID == descriptor.dictionaryID }) else {
                            throw DictionaryImportError.publicationFailed
                        }
                    }
                    latest.dictionaries.append(contentsOf: executionResult.descriptors)
                    latest.updatedAt = now
                }
                return mutation.catalog
            } catch {
                await Task.detached(priority: .utility) {
                    worker.rollbackPublished(executionResult)
                }.value
                throw DictionaryImportError.publicationFailed
            }
        }
    }

    private func makePlan(_ selections: [DictionaryImportSelection],
                          catalog: DictionaryCatalog,
                          allowDuplicateContent: Bool,
                          now: Date) throws -> DictionaryImportPlan {
        guard !selections.isEmpty else { throw DictionaryImportError.invalidSelection }

        for selection in selections {
            guard selection.preview.mddCandidates.isEmpty,
                  selection.selectedMDDIDs.isEmpty else {
                throw DictionaryImportError.invalidSelection
            }
            if !allowDuplicateContent,
               let duplicate = duplicateDescriptor(for: selection.preview, in: catalog) {
                throw DictionaryImportError.duplicate(
                    existingDictionaryID: duplicate.dictionaryID,
                    displayName: duplicate.displayName
                )
            }
            let validCandidateIDs = Set(selection.preview.mddCandidates.map(\.id))
            guard selection.selectedMDDIDs.isSubset(of: validCandidateIDs) else {
                throw DictionaryImportError.invalidSelection
            }
        }

        let totalBytes = selections.reduce(UInt64(0)) {
            $0 &+ $1.preview.mdxFileSize &+
                $1.selectedMDDCandidates.reduce(UInt64(0)) { $0 &+ $1.fileSize }
        }
        let requiredBytes = selections.reduce(UInt64(0)) {
            $0 &+ $1.preview.estimatedDiskBytes(selectedMDDIDs: $1.selectedMDDIDs)
        }
        var nextPosition = (catalog.dictionaries
            .filter { $0.queryLevel == .normal }
            .map(\.sortPosition).max() ?? 0) + 1
        var items: [DictionaryImportPlanItem] = []

        for selection in selections {
            let preview = selection.preview
            let dictionaryID = identifierProvider().uuidString.lowercased()
            let selectedMDDs = selection.selectedMDDCandidates
            let resourcePaths = selectedMDDs.map {
                "Dictionaries/\(dictionaryID)/\($0.fileName)"
            }
            let descriptor = DictionaryDescriptor(
                dictionaryID: dictionaryID,
                displayName: preview.displayName,
                sourceKind: .managedLocal,
                queryLevel: .normal,
                sortPosition: nextPosition,
                enabled: true,
                state: .pendingIndex,
                indexMetadata: DictionaryIndexMetadata(
                    schemaVersion: nil,
                    entryCount: nil,
                    indexFileSize: nil,
                    sourceFileSize: preview.mdxFileSize,
                    sourceModifiedAt: preview.sourceModifiedAt,
                    sourceSHA256: preview.mdxSHA256,
                    indexedAt: nil
                ),
                formatterIdentifier: DictionaryImportPreview.defaultFormatterIdentifier,
                capabilities: .unknown,
                relativePaths: DictionaryRelativePaths(
                    dictionary: "Dictionaries/\(dictionaryID)/\(preview.originalFileName)",
                    resources: resourcePaths,
                    index: nil
                ),
                createdAt: now,
                updatedAt: now
            )
            var files = [DictionaryImportPlanFile(
                sourceURL: preview.sourceMDXURL,
                destinationFileName: preview.originalFileName,
                expectedSize: preview.mdxFileSize,
                expectedSHA256: preview.mdxSHA256
            )]
            files.append(contentsOf: selectedMDDs.map {
                DictionaryImportPlanFile(sourceURL: $0.url,
                                         destinationFileName: $0.fileName,
                                         expectedSize: $0.fileSize,
                                         expectedSHA256: nil)
            })
            items.append(DictionaryImportPlanItem(descriptor: descriptor, files: files))
            nextPosition += 1
        }

        return DictionaryImportPlan(
            operationID: UUID().uuidString.lowercased(),
            totalCopyBytes: totalBytes,
            requiredDiskBytes: requiredBytes,
            items: items
        )
    }
}
