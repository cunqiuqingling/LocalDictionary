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
    case removalStageIdentityMismatch
    case removalRollbackIdentityMismatch
    case filesystemPublishedButIdentityUnconfirmed
    case catalogWriteFailed
    case rollbackFailed
    indirect case stageFailureRuntimeRemainsSuspended(ManagedDictionaryRemovalError)

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
        case .removalStageIdentityMismatch: return "托管词典目录在验证后发生变化，未执行移除。"
        case .removalRollbackIdentityMismatch: return "暂存目录在恢复前发生变化，未执行恢复。"
        case .filesystemPublishedButIdentityUnconfirmed:
            return "文件系统操作完成但无法确认词典目录身份；目录已保留。"
        case .catalogWriteFailed: return "无法保存 Catalog，词典目录已恢复。"
        case .rollbackFailed: return "Catalog 未改变，但托管目录暂时无法恢复；请重新启动应用。"
        case .stageFailureRuntimeRemainsSuspended(let primary):
            let description = primary.errorDescription ?? "无法安全暂存托管词典目录。"
            return description + " 为保证安全，该词典将在本次启动中保持暂停；重新启动后会再次验证目录。"
        }
    }
}

struct ManagedDictionaryDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t
    let type: mode_t

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        owner = value.st_uid
        type = value.st_mode & mode_t(S_IFMT)
    }
}

enum ManagedDictionaryRemovalRenamePhase: Sendable { case stage, rollback }

#if OWNED_LIFECYCLE_TESTING
enum ManagedDictionaryRemovalTestObserver {
    nonisolated(unsafe) static var beforeRenameBinding:
        (@Sendable (ManagedDictionaryRemovalRenamePhase, String) throws -> Void)?
    nonisolated(unsafe) static var afterRenameBeforeIdentityConfirmation:
        (@Sendable (ManagedDictionaryRemovalRenamePhase, String) throws -> Void)?
    nonisolated(unsafe) static var runtimeDisposition:
        (@Sendable (Bool) -> Void)?
}
#endif

struct ManagedDictionaryRemovalPlan: Sendable {
    let dictionaryID: String
    let descriptor: DictionaryDescriptor
    let managedDirectoryURL: URL
    let pendingDeletionRootURL: URL
    let pendingDirectoryURL: URL
    let expectedIdentity: ManagedDictionaryDirectoryIdentity
}

struct ManagedDictionaryRemovalRecoveryReport: Equatable, Sendable {
    var restoredDictionaryIDs: [String] = []
    var cleanedDictionaryIDs: [String] = []
    var deferredDictionaryIDs: [String] = []
}

struct ManagedDictionaryRemovalHooks: Sendable {
    let removeItem: @Sendable (URL) throws -> Void

    static let live = ManagedDictionaryRemovalHooks(
        // A fault-injection gate only. Production deletion is descriptor-relative and
        // inventories every allowed entry before unlinking anything.
        removeItem: { _ in }
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
        guard DictionaryOwnershipPolicy.policy(
            for: descriptor.sourceKind, ownership: descriptor.storageOwnership
        )?.isRemovable == true else {
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
        let expectedIdentity = try validateOwnedIdentity(
            descriptor,
            parentURL: roots.dictionariesRoot,
            component: dictionaryID
        )

        return ManagedDictionaryRemovalPlan(
            dictionaryID: dictionaryID,
            descriptor: descriptor,
            managedDirectoryURL: roots.managedDirectory,
            pendingDeletionRootURL: roots.pendingDeletionRoot,
            pendingDirectoryURL: roots.pendingDirectory,
            expectedIdentity: expectedIdentity
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
            let validated = try validateOwnedIdentity(
                plan.descriptor,
                parentURL: plan.managedDirectoryURL.deletingLastPathComponent(),
                component: plan.dictionaryID
            )
            guard validated == plan.expectedIdentity else {
                throw ManagedDictionaryRemovalError.removalStageIdentityMismatch
            }
            try renameNoReplace(source: plan.managedDirectoryURL,
                                destination: plan.pendingDirectoryURL,
                                expected: plan.expectedIdentity,
                                phase: .stage)
            try synchronizeDirectory(plan.managedDirectoryURL.deletingLastPathComponent())
            try synchronizeDirectory(plan.pendingDeletionRootURL)
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
            let validated = try validateOwnedIdentity(
                plan.descriptor,
                parentURL: plan.pendingDeletionRootURL,
                component: plan.dictionaryID
            )
            guard validated == plan.expectedIdentity else {
                throw ManagedDictionaryRemovalError.removalRollbackIdentityMismatch
            }
            try renameNoReplace(source: plan.pendingDirectoryURL,
                                destination: plan.managedDirectoryURL,
                                expected: plan.expectedIdentity,
                                phase: .rollback)
            try synchronizeDirectory(plan.managedDirectoryURL.deletingLastPathComponent())
            try synchronizeDirectory(plan.pendingDeletionRootURL)
        } catch let error as ManagedDictionaryRemovalError {
            throw error
        } catch {
            throw ManagedDictionaryRemovalError.rollbackFailed
        }
    }

    func finalize(_ plan: ManagedDictionaryRemovalPlan) throws {
        try hooks.removeItem(plan.pendingDirectoryURL)
        _ = try validateOwnedIdentity(
            plan.descriptor,
            parentURL: plan.pendingDeletionRootURL,
            component: plan.dictionaryID
        )
        try safelyDeleteOwnedDirectory(
            plan.pendingDirectoryURL, descriptor: plan.descriptor
        )
        try synchronizeDirectory(plan.pendingDeletionRootURL)
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

        let managedDescriptors: [String: DictionaryDescriptor] = Dictionary(
            uniqueKeysWithValues:
            catalog.dictionaries.compactMap { descriptor in
                guard DictionaryOwnershipPolicy.policy(
                    for: descriptor.sourceKind,
                    ownership: descriptor.storageOwnership
                )?.isRemovable == true else { return nil }
                return (descriptor.dictionaryID, descriptor)
            }
        )
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
                if let descriptor = managedDescriptors[dictionaryID],
                   !fileManager.fileExists(atPath: managedDirectory.path) {
                    let identity = try validateOwnedIdentity(
                        descriptor,
                        parentURL: roots.pendingDeletionRoot,
                        component: dictionaryID
                    )
                    try renameNoReplace(
                        source: child, destination: managedDirectory,
                        expected: identity, phase: .rollback
                    )
                    try synchronizeDirectory(roots.dictionariesRoot)
                    try synchronizeDirectory(roots.pendingDeletionRoot)
                    report.restoredDictionaryIDs.append(dictionaryID)
                } else if managedDescriptors[dictionaryID] == nil {
                    try hooks.removeItem(child)
                    try safelyDeleteOwnedDirectory(child, descriptor: nil)
                    try synchronizeDirectory(roots.pendingDeletionRoot)
                    report.cleanedDictionaryIDs.append(dictionaryID)
                } else {
                    report.deferredDictionaryIDs.append(dictionaryID)
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

    private func renameNoReplace(source: URL,
                                 destination: URL,
                                 expected: ManagedDictionaryDirectoryIdentity,
                                 phase: ManagedDictionaryRemovalRenamePhase) throws {
        let sourceParent = Darwin.open(
            source.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceParent >= 0 else { throw ManagedDictionaryRemovalError.stagingFailed }
        defer { Darwin.close(sourceParent) }
        let destinationParent = Darwin.open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationParent >= 0 else {
            throw ManagedDictionaryRemovalError.stagingFailed
        }
        defer { Darwin.close(destinationParent) }
 #if OWNED_LIFECYCLE_TESTING
        try ManagedDictionaryRemovalTestObserver.beforeRenameBinding?(phase, source.lastPathComponent)
 #endif
        var before = stat()
        guard source.lastPathComponent.withCString({
            Darwin.fstatat(sourceParent, $0, &before, AT_SYMLINK_NOFOLLOW)
        }) == 0, ManagedDictionaryDirectoryIdentity(before) == expected else {
            throw phase == .stage
                ? ManagedDictionaryRemovalError.removalStageIdentityMismatch
                : ManagedDictionaryRemovalError.removalRollbackIdentityMismatch
        }
        let result = source.lastPathComponent.withCString { sourceName in
            destination.lastPathComponent.withCString { destinationName in
                Darwin.renameatx_np(
                    sourceParent, sourceName, destinationParent, destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw ManagedDictionaryRemovalError.stagingConflict }
            throw ManagedDictionaryRemovalError.stagingFailed
        }
#if OWNED_LIFECYCLE_TESTING
        try ManagedDictionaryRemovalTestObserver.afterRenameBeforeIdentityConfirmation?(
            phase, destination.lastPathComponent
        )
#endif
        var after = stat()
        guard destination.lastPathComponent.withCString({
            Darwin.fstatat(destinationParent, $0, &after, AT_SYMLINK_NOFOLLOW)
        }) == 0, ManagedDictionaryDirectoryIdentity(after) == expected else {
            throw ManagedDictionaryRemovalError.filesystemPublishedButIdentityUnconfirmed
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ManagedDictionaryRemovalError.stagingFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedDictionaryRemovalError.stagingFailed
        }
    }

    private func validateOwnedIdentity(_ descriptor: DictionaryDescriptor,
                                       parentURL: URL,
                                       component: String) throws -> ManagedDictionaryDirectoryIdentity {
        guard component == descriptor.dictionaryID else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        let parent = Darwin.open(
            parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { throw ManagedDictionaryRemovalError.unsafeManagedPath }
        defer { Darwin.close(parent) }
        let directory = component.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { throw ManagedDictionaryRemovalError.unsafeManagedPath }
        defer { Darwin.close(directory) }
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(directory, &opened) == 0,
              component.withCString({
                  Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              sameDirectoryIdentity(opened, named),
              opened.st_uid == geteuid(),
              (opened.st_mode & mode_t(0o022)) == 0 else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        switch descriptor.storageOwnership {
        case .appManagedOpenResource:
            try validateOpenResourceIdentity(descriptor, directory: directory)
        case .appManagedImported:
            try validateManagedImportedIdentity(descriptor, directory: directory)
        case .externalReference, .bundledReadOnly:
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        return ManagedDictionaryDirectoryIdentity(opened)
    }

    /// A failed stage may be resumed only if the canonical final name still
    /// resolves to the same object that was validated when its plan was made.
    /// This deliberately compares against `plan.expectedIdentity` instead of
    /// treating a freshly valid replacement as equivalent.
    func canonicalFinalMatchesExpectedIdentity(_ plan: ManagedDictionaryRemovalPlan) -> Bool {
        do {
            return try validateOwnedIdentity(
                plan.descriptor,
                parentURL: plan.managedDirectoryURL.deletingLastPathComponent(),
                component: plan.dictionaryID
            ) == plan.expectedIdentity
        } catch {
            return false
        }
    }

    private func validateOpenResourceIdentity(_ descriptor: DictionaryDescriptor,
                                              directory: Int32) throws {
        guard descriptor.sourceKind == .openResource,
              descriptor.storageOwnership == .appManagedOpenResource,
              let expected = descriptor.openResourceMetadata,
              descriptor.relativePaths.dictionary ==
                "Dictionaries/\(descriptor.dictionaryID)/payload.mdx" else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        let entries = try directoryEntries(directory)
        guard entries.isSubset(of: [
            OpenResourceInstallationIdentity.payloadComponent,
            OpenResourceInstallationIdentity.sidecarComponent,
            "index"
        ]) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        let sidecarFD = try openRegular(
            parent: directory,
            component: OpenResourceInstallationIdentity.sidecarComponent,
            exactMode: 0o600
        )
        defer { Darwin.close(sidecarFD) }
        let sidecarData = try readBounded(sidecarFD, maximum: 64 * 1024)
        guard let sidecar = try? OpenResourceInstallationSidecar.decode(sidecarData),
              sidecar.dictionaryID == descriptor.dictionaryID,
              sidecar.sourceKind == .openResource,
              sidecar.storageOwnership == .appManagedOpenResource,
              sidecar.payloadRelativePath ==
                OpenResourceInstallationIdentity.payloadComponent,
              sidecar.formatterIdentifier == descriptor.formatterIdentifier,
              metadata(from: sidecar) == expected else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        let payloadFD = try openRegular(
            parent: directory,
            component: OpenResourceInstallationIdentity.payloadComponent,
            exactMode: 0o600
        )
        defer { Darwin.close(payloadFD) }
        var payload = stat()
        guard Darwin.fstat(payloadFD, &payload) == 0,
              payload.st_size >= 0,
              UInt64(payload.st_size) == sidecar.payloadBytes else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
    }

    private func metadata(from sidecar: OpenResourceInstallationSidecar)
        -> OpenResourceInstallationMetadata {
        OpenResourceInstallationMetadata(
            resourceID: sidecar.resourceID,
            resourceRevision: sidecar.resourceRevision,
            resourceVersion: sidecar.resourceVersion,
            manifestVersion: sidecar.manifestVersion,
            manifestSHA256: sidecar.manifestSHA256,
            verifiedKeyID: sidecar.verifiedKeyID,
            payloadSHA256: sidecar.payloadSHA256,
            payloadBytes: sidecar.payloadBytes,
            sidecarRelativePath:
                "Dictionaries/\(sidecar.dictionaryID)/\(OpenResourceInstallationIdentity.sidecarComponent)",
            languages: sidecar.languages,
            license: sidecar.license,
            sourceProject: sidecar.sourceProject,
            officialPageReference: sidecar.officialPageReference,
            expectedEntryCount: sidecar.expectedEntryCount,
            installedAt: sidecar.installedAt
        )
    }

    private func openRegular(parent: Int32,
                             component: String,
                             exactMode: mode_t) throws -> Int32 {
        let descriptor = component.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ManagedDictionaryRemovalError.unsafeManagedPath }
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              component.withCString({
                  Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              opened.st_uid == geteuid(), opened.st_nlink == 1,
              (opened.st_mode & mode_t(0o777)) == exactMode,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            Darwin.close(descriptor)
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        return descriptor
    }

    private func readBounded(_ descriptor: Int32, maximum: Int) throws -> Data {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_size > 0, before.st_size <= Int64(maximum) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        var data = Data(count: Int(before.st_size))
        var offset = 0
        let byteCount = data.count
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes {
                Darwin.pread(
                    descriptor,
                    $0.baseAddress!.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw ManagedDictionaryRemovalError.unsafeManagedPath
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        return data
    }

    private func sameDirectoryIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
            (lhs.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
            (rhs.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private func validateManagedImportedIdentity(
        _ descriptor: DictionaryDescriptor,
        directory: Int32
    ) throws {
        guard descriptor.sourceKind == .managedLocal,
              descriptor.storageOwnership == .appManagedImported,
              let sourcePath = descriptor.relativePaths.dictionary,
              let sourceComponents = relativeComponents(
                sourcePath, dictionaryID: descriptor.dictionaryID
              ) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        let ownedSource = Array(sourceComponents.dropFirst(2))
        guard ownedSource.count == 1 ||
                (ownedSource.count == 2 && ownedSource[0] == "source") else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        let entries = try directoryEntries(directory)
        var rootFiles = Set<String>()
        var sourceFiles = Set<String>()
        for path in [descriptor.relativePaths.dictionary].compactMap({ $0 }) +
            descriptor.relativePaths.resources {
            guard let components = relativeComponents(
                path, dictionaryID: descriptor.dictionaryID
            ) else {
                throw ManagedDictionaryRemovalError.unsafeManagedPath
            }
            let tail = Array(components.dropFirst(2))
            if tail.count == 1 {
                rootFiles.insert(tail[0])
            } else if tail.count == 2, tail[0] == "source" {
                sourceFiles.insert(tail[1])
            } else {
                throw ManagedDictionaryRemovalError.unsafeManagedPath
            }
        }
        var allowed = rootFiles
        if !sourceFiles.isEmpty { allowed.insert("source") }
        allowed.insert("index")
        guard entries.isSubset(of: allowed),
              rootFiles.isSubset(of: entries),
              sourceFiles.isEmpty || entries.contains("source") else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        for file in rootFiles.intersection(entries) {
            let descriptor = try openRegular(parent: directory,
                                             component: file,
                                             exactMode: fileMode(directory, file))
            Darwin.close(descriptor)
        }
        if entries.contains("source") {
            let sourceDirectory = try openChildDirectory(
                parent: directory, component: "source"
            )
            defer { Darwin.close(sourceDirectory) }
            let children = try directoryEntries(sourceDirectory)
            guard children == sourceFiles else {
                throw ManagedDictionaryRemovalError.unsafeManagedPath
            }
            for file in children {
                let descriptor = try openRegular(
                    parent: sourceDirectory,
                    component: file,
                    exactMode: fileMode(sourceDirectory, file)
                )
                Darwin.close(descriptor)
            }
        }
        if entries.contains("index") {
            try validateIndexInventory(directory)
        }
    }

    private func safelyDeleteOwnedDirectory(
        _ directoryURL: URL,
        descriptor expectedDescriptor: DictionaryDescriptor?
    ) throws {
        var directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else { throw ManagedDictionaryRemovalError.stagingFailed }
        defer {
            if directory >= 0 { Darwin.close(directory) }
        }
        if let expectedDescriptor {
            switch expectedDescriptor.storageOwnership {
            case .appManagedOpenResource:
                try validateOpenResourceIdentity(expectedDescriptor, directory: directory)
            case .appManagedImported:
                try validateManagedImportedIdentity(expectedDescriptor, directory: directory)
            case .externalReference, .bundledReadOnly:
                throw ManagedDictionaryRemovalError.unsafeManagedPath
            }
        }
        let entries = try directoryEntries(directory)
        let openResource = entries.contains(OpenResourceInstallationIdentity.sidecarComponent)
        let allowedRootFiles: Set<String>
        var allowedDirectories = Set(["index"])
        if openResource {
            allowedRootFiles = [
                OpenResourceInstallationIdentity.payloadComponent,
                OpenResourceInstallationIdentity.sidecarComponent
            ]
        } else {
            allowedRootFiles = Set(entries.filter {
                let ext = URL(fileURLWithPath: $0).pathExtension.lowercased()
                return ext == "mdx" || ext == "mdd"
            })
            allowedDirectories.insert("source")
        }
        guard entries.isSubset(of: allowedRootFiles.union(allowedDirectories)) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        var childInventories: [(String, Int32, Set<String>)] = []
        defer { childInventories.forEach { Darwin.close($0.1) } }
        for entry in entries {
            var metadata = stat()
            guard entry.withCString({
                Darwin.fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }) == 0, metadata.st_uid == geteuid() else {
                throw ManagedDictionaryRemovalError.unsafeManagedPath
            }
            if allowedRootFiles.contains(entry) {
                guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                      metadata.st_nlink == 1 else {
                    throw ManagedDictionaryRemovalError.unsafeManagedPath
                }
            } else {
                guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                    throw ManagedDictionaryRemovalError.unsafeManagedPath
                }
                let child = entry.withCString {
                    Darwin.openat(directory, $0,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else {
                    throw ManagedDictionaryRemovalError.unsafeManagedPath
                }
                let childEntries = try directoryEntries(child)
                let allowed: Set<String>
                if entry == "index" {
                    allowed = [
                        "dictionary.sqlite", "dictionary.sqlite.building",
                        "dictionary.sqlite.previous", "dictionary.sqlite-wal",
                        "dictionary.sqlite-shm"
                    ]
                } else {
                    allowed = Set(childEntries.filter {
                        let ext = URL(fileURLWithPath: $0).pathExtension.lowercased()
                        return ext == "mdx" || ext == "mdd"
                    })
                }
                guard childEntries.isSubset(of: allowed) else {
                    Darwin.close(child)
                    throw ManagedDictionaryRemovalError.unsafeManagedPath
                }
                for childEntry in childEntries {
                    var childMetadata = stat()
                    guard childEntry.withCString({
                        Darwin.fstatat(child, $0, &childMetadata, AT_SYMLINK_NOFOLLOW)
                    }) == 0,
                    (childMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                    childMetadata.st_uid == geteuid(), childMetadata.st_nlink == 1 else {
                        Darwin.close(child)
                        throw ManagedDictionaryRemovalError.unsafeManagedPath
                    }
                }
                childInventories.append((entry, child, childEntries))
            }
        }
        for (entry, child, childEntries) in childInventories {
            for childEntry in childEntries {
                guard childEntry.withCString({ Darwin.unlinkat(child, $0, 0) }) == 0 else {
                    throw ManagedDictionaryRemovalError.stagingFailed
                }
            }
            guard Darwin.fsync(child) == 0,
                  entry.withCString({ Darwin.unlinkat(directory, $0, AT_REMOVEDIR) }) == 0 else {
                throw ManagedDictionaryRemovalError.stagingFailed
            }
        }
        // macOS may keep a removed child directory busy until its descriptor is
        // closed; release all child descriptors before removing the empty root.
        childInventories.forEach { Darwin.close($0.1) }
        childInventories.removeAll()
        for entry in allowedRootFiles.intersection(entries) {
            guard entry.withCString({ Darwin.unlinkat(directory, $0, 0) }) == 0 else {
                throw ManagedDictionaryRemovalError.stagingFailed
            }
        }
        guard Darwin.fsync(directory) == 0 else {
            throw ManagedDictionaryRemovalError.stagingFailed
        }
        guard Darwin.close(directory) == 0 else {
            throw ManagedDictionaryRemovalError.stagingFailed
        }
        directory = -1
        let parent = Darwin.open(
            directoryURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { throw ManagedDictionaryRemovalError.stagingFailed }
        defer { Darwin.close(parent) }
        guard directoryURL.lastPathComponent.withCString({
            Darwin.unlinkat(parent, $0, AT_REMOVEDIR)
        }) == 0 else { throw ManagedDictionaryRemovalError.stagingFailed }
    }

    private func directoryEntries(_ descriptor: Int32) throws -> Set<String> {
        let copy = Darwin.openat(
            descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard copy >= 0, let stream = Darwin.fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }
            throw ManagedDictionaryRemovalError.stagingFailed
        }
        defer { Darwin.closedir(stream) }
        var result = Set<String>()
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { result.insert(name) }
        }
        guard errno == 0 else { throw ManagedDictionaryRemovalError.stagingFailed }
        return result
    }

    private func openChildDirectory(parent: Int32, component: String) throws -> Int32 {
        let descriptor = component.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ManagedDictionaryRemovalError.unsafeManagedPath }
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              component.withCString({
                  Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              sameDirectoryIdentity(opened, named),
              opened.st_uid == geteuid(),
              (opened.st_mode & mode_t(0o022)) == 0 else {
            Darwin.close(descriptor)
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        return descriptor
    }

    private func fileMode(_ parent: Int32, _ component: String) throws -> mode_t {
        var metadata = stat()
        guard component.withCString({
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        metadata.st_uid == geteuid(), metadata.st_nlink == 1 else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        return metadata.st_mode & mode_t(0o777)
    }

    private func validateIndexInventory(_ dictionaryDirectory: Int32) throws {
        let index = try openChildDirectory(parent: dictionaryDirectory, component: "index")
        defer { Darwin.close(index) }
        let entries = try directoryEntries(index)
        let allowed: Set<String> = [
            "dictionary.sqlite", "dictionary.sqlite.building",
            "dictionary.sqlite.previous", "dictionary.sqlite-wal",
            "dictionary.sqlite-shm"
        ]
        guard entries.isSubset(of: allowed) else {
            throw ManagedDictionaryRemovalError.unsafeManagedPath
        }
        for entry in entries {
            let descriptor = try openRegular(
                parent: index, component: entry, exactMode: fileMode(index, entry)
            )
            Darwin.close(descriptor)
        }
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

    private let saveCatalog: SaveCatalog?
    private let catalogStore: DictionaryCatalogStore?
    private let queryService: ManagedDictionaryQueryService
    private let lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator
    private let isIndexing: IsIndexing
    private let worker: ManagedDictionaryRemovalWorker
    private(set) var activeDictionaryIDs: Set<String> = []

    init(catalog: DictionaryCatalog = .empty(),
         catalogStore: DictionaryCatalogStore,
         applicationSupportRootURL: URL =
            ManagedDictionaryRemovalCoordinator.defaultApplicationSupportRootURL(),
         queryService: ManagedDictionaryQueryService,
         lifecycleCoordinator: ManagedDictionaryLifecycleCoordinator? = nil,
         isIndexing: @escaping IsIndexing,
         hooks: ManagedDictionaryRemovalHooks = .live,
         saveCatalog: SaveCatalog? = nil) {
        self.catalog = catalog
        self.catalogStore = saveCatalog == nil ? catalogStore : nil
        self.saveCatalog = saveCatalog
        self.queryService = queryService
        self.lifecycleCoordinator = lifecycleCoordinator ?? queryService.lifecycleCoordinator
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
        activeDictionaryIDs.contains(dictionaryID)
    }

    func recoverPendingDeletions() async -> ManagedDictionaryRemovalRecoveryReport {
        let worker = self.worker
        let catalog = self.catalog
        return await Task.detached(priority: .utility) {
            worker.recoverPendingDeletions(catalog: catalog)
        }.value
    }

    func remove(dictionaryID: String) async -> ManagedDictionaryRemovalResult {
        guard activeDictionaryIDs.insert(dictionaryID).inserted else {
            return .failed(.removalAlreadyInProgress)
        }
        guard let descriptor = catalog.dictionaries.first(where: {
            $0.dictionaryID == dictionaryID
        }) else { return .failed(.dictionaryNotFound) }
        guard DictionaryOwnershipPolicy.policy(
            for: descriptor.sourceKind, ownership: descriptor.storageOwnership
        )?.isRemovable == true else { return .failed(.notManagedLocal) }
        guard descriptor.state != .indexing,
              !isIndexing(dictionaryID) else {
            return .failed(.indexingInProgress)
        }

        defer { activeDictionaryIDs.remove(dictionaryID) }

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
        let permit: ManagedDictionaryLifecyclePermit
        do {
            permit = try await lifecycleCoordinator.acquireExclusiveOperation(
                for: dictionaryID, operation: .remove
            )
        } catch {
            return .failed(.removalAlreadyInProgress)
        }
        func finished(_ result: ManagedDictionaryRemovalResult,
                      _ disposition: ManagedDictionaryLifecycleDisposition)
            async -> ManagedDictionaryRemovalResult {
            await lifecycleCoordinator.complete(permit, disposition: disposition)
            return result
        }
        await queryService.invalidateRuntime(dictionaryID: dictionaryID)
        guard !isIndexing(dictionaryID) else {
            return await finished(.failed(.indexingInProgress),
                                  .available(incrementGeneration: true))
        }
        beforeRemoval?(dictionaryID)

        do {
            try await Task.detached(priority: .userInitiated) {
                try worker.stage(plan)
            }.value
        } catch let error as ManagedDictionaryRemovalError {
            if await resumeAfterFailedStageIfSafe(plan) {
                return await finished(.failed(error), .available(incrementGeneration: true))
            }
            return await finished(.failed(.stageFailureRuntimeRemainsSuspended(error)),
                                  .suspended(incrementGeneration: true))
        } catch {
            let error = ManagedDictionaryRemovalError.stagingFailed
            if await resumeAfterFailedStageIfSafe(plan) {
                return await finished(.failed(error), .available(incrementGeneration: true))
            }
            return await finished(.failed(.stageFailureRuntimeRemainsSuspended(error)),
                                  .suspended(incrementGeneration: true))
        }

        let updated: DictionaryCatalog
        do {
            if let catalogStore {
                let mutation = try catalogStore.mutate { latest, _ in
                    guard latest.dictionaries.contains(where: {
                        $0.dictionaryID == dictionaryID && $0 == descriptor
                    }) else {
                        throw ManagedDictionaryRemovalError.dictionaryNotFound
                    }
                    latest = try DictionaryCatalogOrdering.removingAndCompacting(dictionaryID, from: latest)
                }
                updated = mutation.catalog
            } else {
                updated = try DictionaryCatalogOrdering.removingAndCompacting(
                    dictionaryID, from: catalog
                )
                guard let saveCatalog else { throw ManagedDictionaryRemovalError.catalogWriteFailed }
                try saveCatalog(updated)
            }
        } catch {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try worker.rollback(plan)
                }.value
                return await finished(.failed(.catalogWriteFailed),
                                      .available(incrementGeneration: true))
            } catch let error as ManagedDictionaryRemovalError {
                return await finished(.failed(error), .suspended(incrementGeneration: true))
            } catch {
                return await finished(.failed(.rollbackFailed),
                                      .suspended(incrementGeneration: true))
            }
        }

        catalog = updated
        await queryService.commitCatalog(updated)
        onCatalogChanged?(updated)
        do {
            try await Task.detached(priority: .utility) {
                try worker.finalize(plan)
            }.value
            return await finished(.removed(cleanupDeferred: false), .retired)
        } catch {
            return await finished(.removed(cleanupDeferred: true), .retired)
        }
    }

    private func resumeAfterFailedStageIfSafe(_ plan: ManagedDictionaryRemovalPlan) async -> Bool {
        let worker = self.worker
        let matchesExpectedIdentity = await Task.detached(priority: .userInitiated) {
            worker.canonicalFinalMatchesExpectedIdentity(plan)
        }.value
        guard matchesExpectedIdentity else {
#if OWNED_LIFECYCLE_TESTING
            ManagedDictionaryRemovalTestObserver.runtimeDisposition?(false)
#endif
            return false
        }
#if OWNED_LIFECYCLE_TESTING
        ManagedDictionaryRemovalTestObserver.runtimeDisposition?(true)
#endif
        return true
    }
}
