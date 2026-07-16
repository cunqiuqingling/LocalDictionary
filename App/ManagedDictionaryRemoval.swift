import Darwin
import Foundation

enum ManagedDictionaryRemovalError: LocalizedError, Equatable, Sendable {
    case dictionaryNotFound
    case notManagedLocal
    case indexingInProgress
    case invalidDictionaryID
    case unsafeManagedPath
    case managedDirectoryMissing
    case removalAlreadyInProgress
    case stagingConflict
    case stagingFailed
    case catalogWriteFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .dictionaryNotFound: return "找不到要移除的词典。"
        case .notManagedLocal: return "只有由 LocalDictionary 托管的词典可以移除。"
        case .indexingInProgress: return "该词典正在建立索引，请先取消索引。"
        case .invalidDictionaryID: return "托管词典标识无效。"
        case .unsafeManagedPath: return "托管词典目录未通过安全检查。"
        case .managedDirectoryMissing: return "托管词典目录已不存在。"
        case .removalAlreadyInProgress: return "已有词典移除操作正在进行。"
        case .stagingConflict: return "该词典存在尚未清理的移除暂存目录。"
        case .stagingFailed: return "无法安全暂存托管词典目录。"
        case .catalogWriteFailed: return "无法保存 Catalog，词典目录已恢复。"
        case .rollbackFailed: return "Catalog 未改变，但托管目录暂时无法恢复；请重新启动应用。"
        }
    }
}

struct ManagedDictionaryRemovalPlan: Sendable {
    let dictionaryID: String
    let managedDirectoryURL: URL
    let pendingDeletionRootURL: URL
    let pendingDirectoryURL: URL
}

struct ManagedDictionaryRemovalRecoveryReport: Equatable, Sendable {
    var restoredDictionaryIDs: [String] = []
    var cleanedDictionaryIDs: [String] = []
    var deferredDictionaryIDs: [String] = []
}

struct ManagedDictionaryRemovalHooks: Sendable {
    let removeItem: @Sendable (URL) throws -> Void

    static let live = ManagedDictionaryRemovalHooks(
        removeItem: { try FileManager().removeItem(at: $0) }
    )
}

/// Pure managed-directory work. It owns no AppKit object, Catalog store,
/// runtime, or shared FileManager; every operation receives immutable values.
struct ManagedDictionaryRemovalWorker: Sendable {
    let applicationSupportRootURL: URL
    let hooks: ManagedDictionaryRemovalHooks

    init(applicationSupportRootURL: URL,
         hooks: ManagedDictionaryRemovalHooks = .live) {
        self.applicationSupportRootURL = applicationSupportRootURL
        self.hooks = hooks
    }

    func makePlan(for descriptor: DictionaryDescriptor) throws
        -> ManagedDictionaryRemovalPlan {
        guard descriptor.sourceKind == .managedLocal else {
            throw ManagedDictionaryRemovalError.notManagedLocal
        }
        let dictionaryID = try canonicalUUID(descriptor.dictionaryID)
        try validateCatalogPaths(descriptor.relativePaths, dictionaryID: dictionaryID)

        let fileManager = FileManager()
        let roots = try managedRoots(dictionaryID: dictionaryID,
                                     createContainers: false,
                                     fileManager: fileManager)
        guard fileManager.fileExists(atPath: roots.managedDirectory.path) else {
            throw ManagedDictionaryRemovalError.managedDirectoryMissing
        }
        let values = try roots.managedDirectory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              Self.isDirectDescendant(roots.managedDirectory,
                                      of: roots.dictionariesRoot) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }

        for relativePath in [descriptor.relativePaths.dictionary,
                             descriptor.relativePaths.index].compactMap({ $0 }) +
            descriptor.relativePaths.resources {
            let resolved = applicationSupportRootURL
                .appendingPathComponent(relativePath).standardizedFileURL
                .resolvingSymlinksInPath()
            guard Self.isDescendant(resolved, of: roots.managedDirectory) else {
                throw ManagedDictionaryRemovalError.unsafeManagedPath
            }
        }

        return ManagedDictionaryRemovalPlan(
            dictionaryID: dictionaryID,
            managedDirectoryURL: roots.managedDirectory,
            pendingDeletionRootURL: roots.pendingDeletionRoot,
            pendingDirectoryURL: roots.pendingDirectory
        )
    }

    func stage(_ plan: ManagedDictionaryRemovalPlan) throws {
        let fileManager = FileManager()
        try fileManager.createDirectory(at: plan.pendingDeletionRootURL,
                                        withIntermediateDirectories: true)
        let pendingRoot = plan.pendingDeletionRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let applicationRoot = applicationSupportRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let rootValues = try pendingRoot.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              Self.isDirectDescendant(pendingRoot, of: applicationRoot),
              Self.isDirectDescendant(plan.pendingDirectoryURL, of: pendingRoot) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        guard !fileManager.fileExists(atPath: plan.pendingDirectoryURL.path) else {
            throw ManagedDictionaryRemovalError.stagingConflict
        }
        do {
            try renameAtomically(source: plan.managedDirectoryURL,
                                 destination: plan.pendingDirectoryURL)
            synchronizeDirectory(plan.managedDirectoryURL.deletingLastPathComponent())
            synchronizeDirectory(plan.pendingDeletionRootURL)
        } catch let error as ManagedDictionaryRemovalError {
            throw error
        } catch {
            throw ManagedDictionaryRemovalError.stagingFailed
        }
    }

    func rollback(_ plan: ManagedDictionaryRemovalPlan) throws {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: plan.pendingDirectoryURL.path),
              !fileManager.fileExists(atPath: plan.managedDirectoryURL.path) else {
            throw ManagedDictionaryRemovalError.rollbackFailed
        }
        do {
            try renameAtomically(source: plan.pendingDirectoryURL,
                                 destination: plan.managedDirectoryURL)
            synchronizeDirectory(plan.managedDirectoryURL.deletingLastPathComponent())
            synchronizeDirectory(plan.pendingDeletionRootURL)
        } catch {
            throw ManagedDictionaryRemovalError.rollbackFailed
        }
    }

    func finalize(_ plan: ManagedDictionaryRemovalPlan) throws {
        try hooks.removeItem(plan.pendingDirectoryURL)
        synchronizeDirectory(plan.pendingDeletionRootURL)
    }

    func recoverPendingDeletions(catalog: DictionaryCatalog)
        -> ManagedDictionaryRemovalRecoveryReport {
        let fileManager = FileManager()
        var report = ManagedDictionaryRemovalRecoveryReport()
        let roots: (dictionariesRoot: URL, pendingDeletionRoot: URL)
        do {
            let resolved = try managedRoots(dictionaryID: UUID().uuidString.lowercased(),
                                            createContainers: true,
                                            fileManager: fileManager)
            roots = (resolved.dictionariesRoot, resolved.pendingDeletionRoot)
        } catch {
            return report
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: roots.pendingDeletionRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return report }

        let managedIDs = Set(catalog.dictionaries.filter {
            $0.sourceKind == .managedLocal
        }.map(\.dictionaryID))
        for child in children {
            let dictionaryID: String
            do { dictionaryID = try canonicalUUID(child.lastPathComponent) }
            catch { continue }
            guard Self.isDirectDescendant(child.standardizedFileURL,
                                          of: roots.pendingDeletionRoot),
                  let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey
                  ]), values.isDirectory == true, values.isSymbolicLink != true else {
                report.deferredDictionaryIDs.append(dictionaryID)
                continue
            }
            let managedDirectory = roots.dictionariesRoot
                .appendingPathComponent(dictionaryID, isDirectory: true)
            do {
                if managedIDs.contains(dictionaryID),
                   !fileManager.fileExists(atPath: managedDirectory.path) {
                    try renameAtomically(source: child, destination: managedDirectory)
                    synchronizeDirectory(roots.dictionariesRoot)
                    synchronizeDirectory(roots.pendingDeletionRoot)
                    report.restoredDictionaryIDs.append(dictionaryID)
                } else {
                    try hooks.removeItem(child)
                    synchronizeDirectory(roots.pendingDeletionRoot)
                    report.cleanedDictionaryIDs.append(dictionaryID)
                }
            } catch {
                report.deferredDictionaryIDs.append(dictionaryID)
            }
        }
        return report
    }

    private func managedRoots(dictionaryID: String,
                              createContainers: Bool,
                              fileManager: FileManager) throws
        -> (dictionariesRoot: URL, managedDirectory: URL,
            pendingDeletionRoot: URL, pendingDirectory: URL) {
        if createContainers {
            try fileManager.createDirectory(at: applicationSupportRootURL,
                                            withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: applicationSupportRootURL.appendingPathComponent(
                    "Dictionaries", isDirectory: true
                ), withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: applicationSupportRootURL.appendingPathComponent(
                    "PendingDeletion", isDirectory: true
                ), withIntermediateDirectories: true
            )
        }
        let applicationRoot = applicationSupportRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let dictionariesRoot = applicationSupportRootURL
            .appendingPathComponent("Dictionaries", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let pendingDeletionRoot = applicationSupportRootURL
            .appendingPathComponent("PendingDeletion", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let managedDirectory = dictionariesRoot
            .appendingPathComponent(dictionaryID, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let pendingDirectory = pendingDeletionRoot
            .appendingPathComponent(dictionaryID, isDirectory: true)
            .standardizedFileURL
        guard Self.isDirectDescendant(dictionariesRoot, of: applicationRoot),
              Self.isDirectDescendant(pendingDeletionRoot, of: applicationRoot),
              Self.isDirectDescendant(managedDirectory, of: dictionariesRoot),
              Self.isDirectDescendant(pendingDirectory, of: pendingDeletionRoot) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        return (dictionariesRoot, managedDirectory,
                pendingDeletionRoot, pendingDirectory)
    }

    private func validateCatalogPaths(_ paths: DictionaryRelativePaths,
                                      dictionaryID: String) throws {
        guard let source = paths.dictionary,
              isAllowedSourcePath(source, dictionaryID: dictionaryID) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        if let index = paths.index,
           !isAllowedIndexPath(index, dictionaryID: dictionaryID) {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        for resource in paths.resources where
            !isAllowedResourcePath(resource, dictionaryID: dictionaryID) {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
    }

    private func isAllowedSourcePath(_ path: String, dictionaryID: String) -> Bool {
        guard let components = relativeComponents(path, dictionaryID: dictionaryID) else {
            return false
        }
        return (components.count == 3 ||
                (components.count == 4 && components[2] == "source")) &&
            URL(fileURLWithPath: components.last!).pathExtension
                .caseInsensitiveCompare("mdx") == .orderedSame
    }

    private func isAllowedIndexPath(_ path: String, dictionaryID: String) -> Bool {
        guard let components = relativeComponents(path, dictionaryID: dictionaryID) else {
            return false
        }
        return components.count == 4 && components[2] == "index"
    }

    private func isAllowedResourcePath(_ path: String, dictionaryID: String) -> Bool {
        guard let components = relativeComponents(path, dictionaryID: dictionaryID) else {
            return false
        }
        return components.count == 3 ||
            (components.count == 4 && components[2] == "source")
    }

    private func relativeComponents(_ path: String, dictionaryID: String) -> [String]? {
        guard !path.isEmpty, !NSString(string: path).isAbsolutePath,
              !path.contains("\\"), !path.contains("://") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count >= 3,
              components[0] == "Dictionaries", components[1] == dictionaryID,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return components
    }

    private func canonicalUUID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw ManagedDictionaryRemovalError.invalidDictionaryID
        }
        return value
    }

    private func renameAtomically(source: URL, destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func synchronizeDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }

    private static func isDirectDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let directoryComponents = directory.standardizedFileURL.pathComponents
        return candidateComponents.count == directoryComponents.count + 1 &&
            candidateComponents.starts(with: directoryComponents)
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let directoryComponents = directory.standardizedFileURL.pathComponents
        return candidateComponents.count > directoryComponents.count &&
            candidateComponents.starts(with: directoryComponents)
    }
}

enum ManagedDictionaryRemovalResult: Equatable, Sendable {
    case removed(cleanupDeferred: Bool)
    case failed(ManagedDictionaryRemovalError)
}

@MainActor
final class ManagedDictionaryRemovalCoordinator {
    typealias CatalogObserver = (DictionaryCatalog) -> Void
    typealias BeforeRemoval = (String) -> Void
    typealias SaveCatalog = (DictionaryCatalog) throws -> Void
    typealias IsIndexing = (String) -> Bool

    private(set) var catalog: DictionaryCatalog
    var onCatalogChanged: CatalogObserver?
    var beforeRemoval: BeforeRemoval?

    private let saveCatalog: SaveCatalog
    private let queryService: ManagedDictionaryQueryService
    private let isIndexing: IsIndexing
    private let worker: ManagedDictionaryRemovalWorker
    private(set) var activeDictionaryID: String?

    init(catalog: DictionaryCatalog = .empty(),
         catalogStore: DictionaryCatalogStore,
         applicationSupportRootURL: URL =
            ManagedDictionaryRemovalCoordinator.defaultApplicationSupportRootURL(),
         queryService: ManagedDictionaryQueryService,
         isIndexing: @escaping IsIndexing,
         hooks: ManagedDictionaryRemovalHooks = .live,
         saveCatalog: SaveCatalog? = nil) {
        self.catalog = catalog
        self.saveCatalog = saveCatalog ?? { try catalogStore.save($0) }
        self.queryService = queryService
        self.isIndexing = isIndexing
        worker = ManagedDictionaryRemovalWorker(
            applicationSupportRootURL: applicationSupportRootURL,
            hooks: hooks
        )
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

    func synchronize(catalog: DictionaryCatalog) {
        self.catalog = catalog
    }

    func isRemoving(_ dictionaryID: String) -> Bool {
        activeDictionaryID == dictionaryID
    }

    func recoverPendingDeletions() async -> ManagedDictionaryRemovalRecoveryReport {
        let worker = self.worker
        let catalog = self.catalog
        return await Task.detached(priority: .utility) {
            worker.recoverPendingDeletions(catalog: catalog)
        }.value
    }

    func remove(dictionaryID: String) async -> ManagedDictionaryRemovalResult {
        guard activeDictionaryID == nil else { return .failed(.removalAlreadyInProgress) }
        guard let descriptor = catalog.dictionaries.first(where: {
            $0.dictionaryID == dictionaryID
        }) else { return .failed(.dictionaryNotFound) }
        guard descriptor.sourceKind == .managedLocal else { return .failed(.notManagedLocal) }
        guard descriptor.state != .indexing,
              !isIndexing(dictionaryID) else {
            return .failed(.indexingInProgress)
        }

        activeDictionaryID = dictionaryID
        defer { activeDictionaryID = nil }

        let worker = self.worker
        let plan: ManagedDictionaryRemovalPlan
        do {
            plan = try await Task.detached(priority: .userInitiated) {
                try worker.makePlan(for: descriptor)
            }.value
        }
        catch let error as ManagedDictionaryRemovalError { return .failed(error) }
        catch { return .failed(.unsafeManagedPath) }

        guard !isIndexing(dictionaryID) else { return .failed(.indexingInProgress) }
        await queryService.suspend(dictionaryID: dictionaryID)
        guard !isIndexing(dictionaryID) else {
            await queryService.resume(dictionaryID: dictionaryID)
            return .failed(.indexingInProgress)
        }
        beforeRemoval?(dictionaryID)

        do {
            try await Task.detached(priority: .userInitiated) {
                try worker.stage(plan)
            }.value
        } catch let error as ManagedDictionaryRemovalError {
            await queryService.resume(dictionaryID: dictionaryID)
            return .failed(error)
        } catch {
            await queryService.resume(dictionaryID: dictionaryID)
            return .failed(.stagingFailed)
        }

        let updated: DictionaryCatalog
        do {
            updated = try DictionaryCatalogOrdering.removingAndCompacting(
                dictionaryID, from: catalog
            )
            try saveCatalog(updated)
        } catch {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try worker.rollback(plan)
                }.value
                await queryService.resume(dictionaryID: dictionaryID)
                return .failed(.catalogWriteFailed)
            } catch {
                return .failed(.rollbackFailed)
            }
        }

        catalog = updated
        await queryService.commitRemoval(dictionaryID: dictionaryID,
                                         updatedCatalog: updated)
        onCatalogChanged?(updated)
        do {
            try await Task.detached(priority: .utility) {
                try worker.finalize(plan)
            }.value
            return .removed(cleanupDeferred: false)
        } catch {
            return .removed(cleanupDeferred: true)
        }
    }
}
