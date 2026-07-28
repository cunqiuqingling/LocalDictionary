import CryptoKit
import Darwin
import Foundation

enum OwnedDictionaryLifecycleErrorCode: String, Error, Equatable, Sendable {
    case lifecycleBlockedByCorruptCatalog
    case lifecycleBlockedByUnsupportedCatalog
    case invalidOwnedDirectory
    case invalidInstallationSidecar
    case payloadIdentityMismatch
    case dictionaryDirectoryMissing
    case unexpectedOwnedEntry
    case duplicateResourceIdentity
    case dictionaryIdentityConflict
    case quarantineConflict
    case quarantineDurabilityFailure
    case pendingDeletionConflict
    case pendingDeletionRestoreFailed
    case pendingDeletionCleanupDeferred
    case catalogCommitFailedAfterFilesystemMutation
    case interruptedIndexReset
    case directoryEnumerationFailure
    case invalidOwnedOperationComponent
    case sourceIdentityChangedBeforeRename
    case destinationIdentityMismatchAfterRename
    case pendingDeletionIdentityChanged
    case indexInventoryContainsUnknownEntries
    case unsafePath
    case permissionDenied
    case cancelled
    case ioFailure
}

private enum OwnedOperationComponent {
    case partial(UUID)
    case verified(UUID)

    static func parse(_ component: String) -> OwnedOperationComponent? {
        let prefix: String
        let make: (UUID) -> OwnedOperationComponent
        if component.hasPrefix(".partial-") {
            prefix = ".partial-"
            make = OwnedOperationComponent.partial
        } else if component.hasPrefix("verified-") {
            prefix = "verified-"
            make = OwnedOperationComponent.verified
        } else {
            return nil
        }
        let suffix = String(component.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix),
              uuid.uuidString.lowercased() == suffix else { return nil }
        return make(uuid)
    }

    static func hasReservedPrefix(_ component: String) -> Bool {
        component.hasPrefix(".partial-") || component.hasPrefix("verified-")
    }
}

private struct OwnedDirectoryIdentity: Equatable {
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

#if OWNED_LIFECYCLE_TESTING
enum OwnedDictionaryLifecycleTestObserver {
    nonisolated(unsafe) static var beforeRenameBinding: (@Sendable (String) throws -> Void)?
    nonisolated(unsafe) static var beforeIndexInventory: (@Sendable () throws -> Void)?
}
#endif

struct OwnedDictionaryLifecycleIssue: Equatable, Sendable {
    let code: OwnedDictionaryLifecycleErrorCode
    let dictionaryID: String?
}

struct OwnedDictionaryLifecycleReport: Equatable, Sendable {
    var catalogProvenance: DictionaryCatalogLoadProvenance
    var acceptedDictionaryIDs: [String] = []
    var recoveredDictionaryIDs: [String] = []
    var downgradedDictionaryIDs: [String] = []
    var restoredDictionaryIDs: [String] = []
    var completedDeletionDictionaryIDs: [String] = []
    var quarantinedDictionaryIDs: [String] = []
    var preservedDictionaryIDs: [String] = []
    var blocked = false
    var issues: [OwnedDictionaryLifecycleIssue] = []

    mutating func issue(_ code: OwnedDictionaryLifecycleErrorCode,
                        dictionaryID: String? = nil) {
        issues.append(OwnedDictionaryLifecycleIssue(code: code, dictionaryID: dictionaryID))
    }
}

struct OwnedDictionaryLifecycleResult: Sendable {
    let catalog: DictionaryCatalog
    let report: OwnedDictionaryLifecycleReport
}

/// One reconciler and one detached worker share only this cooperative cancellation bit.
/// Every access is protected by the lock; the token owns no filesystem or Catalog state.
final class OwnedDictionaryLifecycleCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct OwnedDictionaryLifecycleHooks: Sendable {
    let renameNoReplaceAt: @Sendable (Int32, String, Int32, String) throws -> Void
    let synchronize: @Sendable (Int32) throws -> Void
    let beforeDelete: @Sendable (String) throws -> Void

    static let live = OwnedDictionaryLifecycleHooks(
        renameNoReplaceAt: { sourceDirectory, source, destinationDirectory, destination in
            let result = source.withCString { sourceName in
                destination.withCString { destinationName in
                    Darwin.renameatx_np(sourceDirectory, sourceName,
                                        destinationDirectory, destinationName,
                                        UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else {
                throw OwnedDictionaryLifecyclePOSIX.mappedError()
            }
        },
        synchronize: { descriptor in
            guard Darwin.fsync(descriptor) == 0 else {
                throw OwnedDictionaryLifecycleErrorCode.ioFailure
            }
        },
        beforeDelete: { _ in }
    )
}

private struct OwnedDictionaryLifecyclePrepared: Sendable {
    let originalCatalog: DictionaryCatalog
    let proposedCatalog: DictionaryCatalog
    let report: OwnedDictionaryLifecycleReport
}

private enum OwnedDictionaryLifecyclePOSIX {
    static func mappedError(_ value: Int32 = errno) -> OwnedDictionaryLifecycleErrorCode {
        switch value {
        case EEXIST: return .pendingDeletionConflict
        case EACCES, EPERM: return .permissionDenied
        case ELOOP, ENOTDIR: return .unsafePath
        default: return .ioFailure
        }
    }

    static func requireComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.contains("\0"), !value.contains("://"),
              !NSString(string: value).isAbsolutePath else {
            throw OwnedDictionaryLifecycleErrorCode.unsafePath
        }
    }

    static func canonicalUUID(_ value: String) throws -> String {
        try requireComponent(value)
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw OwnedDictionaryLifecycleErrorCode.unsafePath
        }
        return value
    }

    static func metadata(_ descriptor: Int32) throws -> stat {
        var result = stat()
        guard Darwin.fstat(descriptor, &result) == 0 else { throw mappedError() }
        return result
    }

    static func entryMetadata(_ parent: Int32, _ component: String) throws -> stat {
        try requireComponent(component)
        var result = stat()
        let status = component.withCString {
            Darwin.fstatat(parent, $0, &result, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { throw mappedError() }
        return result
    }

    static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
            (lhs.st_mode & mode_t(S_IFMT)) == (rhs.st_mode & mode_t(S_IFMT)) &&
            lhs.st_uid == rhs.st_uid
    }

    static func directoryIdentity(_ descriptor: Int32) throws -> OwnedDirectoryIdentity {
        let value = try metadata(descriptor)
        try validateDirectory(value)
        return OwnedDirectoryIdentity(value)
    }

    static func validateDirectory(_ value: stat) throws {
        guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw OwnedDictionaryLifecycleErrorCode.invalidOwnedDirectory
        }
        guard value.st_uid == geteuid(),
              (value.st_mode & mode_t(0o022)) == 0 else {
            throw OwnedDictionaryLifecycleErrorCode.permissionDenied
        }
    }

    static func validateRegularFile(_ value: stat,
                                    exactMode: mode_t? = nil,
                                    expectedSize: UInt64? = nil) throws {
        guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              value.st_nlink == 1 else {
            throw OwnedDictionaryLifecycleErrorCode.invalidOwnedDirectory
        }
        guard value.st_uid == geteuid() else {
            throw OwnedDictionaryLifecycleErrorCode.permissionDenied
        }
        if let exactMode,
           (value.st_mode & mode_t(0o777)) != exactMode {
            throw OwnedDictionaryLifecycleErrorCode.permissionDenied
        }
        if let expectedSize,
           value.st_size < 0 || UInt64(value.st_size) != expectedSize {
            throw OwnedDictionaryLifecycleErrorCode.payloadIdentityMismatch
        }
    }

    static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/") else {
            throw OwnedDictionaryLifecycleErrorCode.unsafePath
        }
        if create {
            let status = url.path.withCString { Darwin.mkdir($0, 0o700) }
            guard status == 0 || errno == EEXIST else { throw mappedError() }
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw mappedError() }
        do {
            try validateDirectory(metadata(descriptor))
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func openChildDirectory(_ parent: Int32, _ component: String) throws -> Int32 {
        try requireComponent(component)
        let descriptor = component.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw mappedError() }
        do {
            let descriptorMetadata = try metadata(descriptor)
            try validateDirectory(descriptorMetadata)
            let nameMetadata = try entryMetadata(parent, component)
            guard sameIdentity(descriptorMetadata, nameMetadata) else {
                throw OwnedDictionaryLifecycleErrorCode.invalidOwnedDirectory
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func openRegular(_ parent: Int32, _ component: String) throws -> Int32 {
        try requireComponent(component)
        let descriptor = component.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw mappedError() }
        do {
            let descriptorMetadata = try metadata(descriptor)
            try validateRegularFile(descriptorMetadata)
            let nameMetadata = try entryMetadata(parent, component)
            guard sameIdentity(descriptorMetadata, nameMetadata) else {
                throw OwnedDictionaryLifecycleErrorCode.invalidOwnedDirectory
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func entries(_ directory: Int32) throws -> Set<String> {
        let copy = Darwin.openat(
            directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard copy >= 0, let stream = Darwin.fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }
            throw OwnedDictionaryLifecycleErrorCode.directoryEnumerationFailure
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
        guard errno == 0 else {
            throw OwnedDictionaryLifecycleErrorCode.directoryEnumerationFailure
        }
        return result
    }

    static func read(_ descriptor: Int32, maximum: Int) throws -> Data {
        let before = try metadata(descriptor)
        guard before.st_size > 0, before.st_size <= Int64(maximum) else {
            throw OwnedDictionaryLifecycleErrorCode.invalidInstallationSidecar
        }
        var data = Data(count: Int(before.st_size))
        var offset = 0
        let byteCount = data.count
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress!.advanced(by: offset),
                             byteCount - offset, off_t(offset))
            }
            if count > 0 { offset += count }
            else if count < 0, errno == EINTR { continue }
            else { throw OwnedDictionaryLifecycleErrorCode.ioFailure }
        }
        let after = try metadata(descriptor)
        guard sameIdentity(before, after), before.st_size == after.st_size else {
            throw OwnedDictionaryLifecycleErrorCode.invalidInstallationSidecar
        }
        return data
    }

    static func sha256(_ descriptor: Int32) throws -> String {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw mappedError() }
        let before = try metadata(descriptor)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 { hasher.update(data: Data(buffer[0..<Int(count)])) }
            else if count == 0 { break }
            else if errno != EINTR { throw mappedError() }
        }
        let after = try metadata(descriptor)
        guard sameIdentity(before, after), before.st_size == after.st_size else {
            throw OwnedDictionaryLifecycleErrorCode.payloadIdentityMismatch
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isAbsent(_ parent: Int32, _ component: String) throws -> Bool {
        try requireComponent(component)
        var value = stat()
        let result = component.withCString {
            Darwin.fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return false }
        if errno == ENOENT { return true }
        throw mappedError()
    }

    static func unlink(_ parent: Int32, _ component: String, directory: Bool) throws {
        try requireComponent(component)
        let flags: Int32 = directory ? AT_REMOVEDIR : 0
        let result = component.withCString { Darwin.unlinkat(parent, $0, flags) }
        guard result == 0 else { throw mappedError() }
    }
}

private struct OwnedDictionaryLifecycleWorker: Sendable {
    let applicationSupportRootURL: URL
    let stagingRootURL: URL
    let hooks: OwnedDictionaryLifecycleHooks
    let cancellationToken: OwnedDictionaryLifecycleCancellationToken

    func prepare(catalog original: DictionaryCatalog,
                 provenance: DictionaryCatalogLoadProvenance) -> OwnedDictionaryLifecyclePrepared {
        var catalog = original
        var report = OwnedDictionaryLifecycleReport(catalogProvenance: provenance)
        do {
            try checkCancellation()
            let roots = try openRoots()
            defer { roots.close() }
            let durabilityUncertainIDs = try reconcileStaging(
                roots: roots, catalog: &catalog, report: &report
            )
            let inspection = try inspectCatalogDirectories(
                roots: roots, catalog: &catalog, report: &report
            )
            let restored = try reconcilePendingDeletions(
                roots: roots, catalog: &catalog, report: &report
            )
            try recoverFinalOrphans(
                roots: roots,
                excluding: durabilityUncertainIDs,
                catalog: &catalog,
                report: &report
            )
            try reconcileIndexes(roots: roots, catalog: &catalog,
                                 validatedDirectoryIDs: inspection.validatedDirectoryIDs,
                                 report: &report)
            let unresolved = inspection.missingDictionaryIDs.subtracting(restored)
            try markMissing(
                unresolved, roots: roots, catalog: &catalog, report: &report
            )
        } catch let code as OwnedDictionaryLifecycleErrorCode {
            report.issue(code)
        } catch {
            report.issue(.ioFailure)
        }
        if catalog != original { catalog.updatedAt = Date() }
        return OwnedDictionaryLifecyclePrepared(
            originalCatalog: original, proposedCatalog: catalog, report: report
        )
    }

    private struct CatalogDirectoryInspection {
        var missingDictionaryIDs = Set<String>()
        var validatedDirectoryIDs = Set<String>()
    }

    private final class ValidatedDirectoryCapability {
        let descriptor: Int32

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        deinit { Darwin.close(descriptor) }
    }

    private struct ValidatedOpenResourceDirectory {
        let sidecar: OpenResourceInstallationSidecar
        let identity: OwnedDirectoryIdentity
        let capability: ValidatedDirectoryCapability
    }

    private struct ValidatedOwnedDirectory {
        let identity: OwnedDirectoryIdentity
        let capability: ValidatedDirectoryCapability
    }

    private struct Roots {
        let dictionaries: Int32
        let staging: Int32
        let pendingDeletion: Int32
        func close() {
            Darwin.close(dictionaries)
            Darwin.close(staging)
            Darwin.close(pendingDeletion)
        }
    }

    private func openRoots() throws -> Roots {
        let app = try OwnedDictionaryLifecyclePOSIX.openDirectory(applicationSupportRootURL,
                                                                  create: true)
        defer { Darwin.close(app) }
        func child(_ name: String) throws -> Int32 {
            let result = name.withCString { Darwin.mkdirat(app, $0, 0o700) }
            guard result == 0 || errno == EEXIST else {
                throw OwnedDictionaryLifecyclePOSIX.mappedError()
            }
            return try OwnedDictionaryLifecyclePOSIX.openChildDirectory(app, name)
        }
        let dictionaries = try child("Dictionaries")
        do {
            let staging: Int32
            if stagingRootURL.standardizedFileURL ==
                applicationSupportRootURL.appendingPathComponent("Staging").standardizedFileURL {
                staging = try child("Staging")
            } else {
                staging = try OwnedDictionaryLifecyclePOSIX.openDirectory(stagingRootURL,
                                                                          create: true)
            }
            do {
                let pending = try child("PendingDeletion")
                return Roots(
                    dictionaries: dictionaries,
                    staging: staging,
                    pendingDeletion: pending
                )
            } catch {
                Darwin.close(staging); throw error
            }
        } catch {
            Darwin.close(dictionaries); throw error
        }
    }

    private func reconcileStaging(roots: Roots,
                                  catalog: inout DictionaryCatalog,
                                  report: inout OwnedDictionaryLifecycleReport) throws
        -> Set<String> {
        var durabilityUncertainIDs = Set<String>()
        for component in try OwnedDictionaryLifecyclePOSIX.entries(roots.staging).sorted() {
            try checkCancellation()
            guard let operation = OwnedOperationComponent.parse(component) else {
                report.preservedDictionaryIDs.append(component)
                report.issue(OwnedOperationComponent.hasReservedPrefix(component)
                    ? .invalidOwnedOperationComponent : .unexpectedOwnedEntry)
                continue
            }
            switch operation {
            case .partial:
                do {
                    try removePartial(parent: roots.staging, component: component)
                    report.completedDeletionDictionaryIDs.append(component)
                } catch let code as OwnedDictionaryLifecycleErrorCode {
                    report.preservedDictionaryIDs.append(component)
                    report.issue(code)
                }
                continue
            case .verified:
                break
            }
            var publishedDictionaryID: String?
            do {
                let validated = try validateOpenResourceDirectory(
                    parent: roots.staging, component: component, fullHash: true,
                    expectedDictionaryID: nil, allowIndex: false
                )
                let sidecar = validated.sidecar
                let dictionaryID = try OwnedDictionaryLifecyclePOSIX.canonicalUUID(
                    sidecar.dictionaryID
                )
                if try OwnedDictionaryLifecyclePOSIX.isAbsent(roots.dictionaries, dictionaryID) {
                    if catalog.dictionaries.contains(where: {
                        $0.dictionaryID == dictionaryID ||
                            $0.openResourceMetadata?.resourceID == sidecar.resourceID
                    }) {
                        report.preservedDictionaryIDs.append(component)
                        report.issue(
                            catalog.dictionaries.contains(where: {
                                $0.openResourceMetadata?.resourceID == sidecar.resourceID
                            }) ? .duplicateResourceIdentity : .dictionaryIdentityConflict,
                            dictionaryID: dictionaryID
                        )
                        continue
                    }
                    publishedDictionaryID = dictionaryID
                    try renameValidatedDirectory(
                        sourceParent: roots.staging, sourceComponent: component,
                        destinationParent: roots.dictionaries,
                        destinationComponent: dictionaryID,
                        expected: validated.identity,
                        validatedCapability: validated.capability,
                        sourceRaceError: .sourceIdentityChangedBeforeRename
                    )
                    try hooks.synchronize(roots.dictionaries)
                    try hooks.synchronize(roots.staging)
                    publishedDictionaryID = nil
                    report.recoveredDictionaryIDs.append(dictionaryID)
                } else {
                    let final = try validateOpenResourceDirectory(
                        parent: roots.dictionaries, component: dictionaryID,
                        fullHash: true, expectedDictionaryID: dictionaryID, allowIndex: true
                    ).sidecar
                    guard final == sidecar else {
                        report.preservedDictionaryIDs.append(component)
                        report.issue(.dictionaryIdentityConflict, dictionaryID: dictionaryID)
                        continue
                    }
                    try removeOwnedDirectory(parent: roots.staging, component: component,
                                             ownership: .appManagedOpenResource,
                                             descriptor: nil, allowIndex: false)
                    try hooks.synchronize(roots.staging)
                }
            } catch let code as OwnedDictionaryLifecycleErrorCode {
                if let publishedDictionaryID {
                    durabilityUncertainIDs.insert(publishedDictionaryID)
                }
                report.preservedDictionaryIDs.append(component)
                report.issue(code)
            } catch {
                if let publishedDictionaryID {
                    durabilityUncertainIDs.insert(publishedDictionaryID)
                }
                report.preservedDictionaryIDs.append(component)
                report.issue(.ioFailure)
            }
        }
        _ = catalog
        return durabilityUncertainIDs
    }

    private func removePartial(parent: Int32, component: String) throws {
        var directory = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(parent, component)
        defer {
            if directory >= 0 { Darwin.close(directory) }
        }
        let allowed = Set(["payload.mdx.part", "payload.mdx",
                           OpenResourceInstallationIdentity.sidecarComponent])
        let entries = try OwnedDictionaryLifecyclePOSIX.entries(directory)
        guard entries.isSubset(of: allowed) else {
            throw OwnedDictionaryLifecycleErrorCode.unexpectedOwnedEntry
        }
        for entry in entries {
            let metadata = try OwnedDictionaryLifecyclePOSIX.entryMetadata(directory, entry)
            try OwnedDictionaryLifecyclePOSIX.validateRegularFile(metadata)
        }
        try hooks.beforeDelete(component)
        for entry in entries.sorted() {
            try OwnedDictionaryLifecyclePOSIX.unlink(directory, entry, directory: false)
        }
        try hooks.synchronize(directory)
        guard Darwin.close(directory) == 0 else {
            throw OwnedDictionaryLifecycleErrorCode.ioFailure
        }
        directory = -1
        try OwnedDictionaryLifecyclePOSIX.unlink(parent, component, directory: true)
        try hooks.synchronize(parent)
    }

    /// Bind a name-based rename to the directory that has just completed the
    /// full fd-relative validation pass.  The validation descriptor is kept
    /// alive through both name re-binding and the
    /// post-rename destination verification.
    private func renameValidatedDirectory(
        sourceParent: Int32,
        sourceComponent: String,
        destinationParent: Int32,
        destinationComponent: String,
        expected: OwnedDirectoryIdentity,
        validatedCapability: ValidatedDirectoryCapability,
        sourceRaceError: OwnedDictionaryLifecycleErrorCode
    ) throws {
#if OWNED_LIFECYCLE_TESTING
        try OwnedDictionaryLifecycleTestObserver.beforeRenameBinding?(sourceComponent)
#endif
        guard try OwnedDictionaryLifecyclePOSIX.directoryIdentity(
            validatedCapability.descriptor
        ) == expected,
              OwnedDirectoryIdentity(try OwnedDictionaryLifecyclePOSIX.entryMetadata(
                sourceParent, sourceComponent
              )) == expected else {
            throw sourceRaceError
        }

        try hooks.renameNoReplaceAt(
            sourceParent, sourceComponent, destinationParent, destinationComponent
        )

        let destination = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(
            destinationParent, destinationComponent
        )
        defer { Darwin.close(destination) }
        guard try OwnedDictionaryLifecyclePOSIX.directoryIdentity(destination) == expected,
              OwnedDirectoryIdentity(try OwnedDictionaryLifecyclePOSIX.entryMetadata(
                destinationParent, destinationComponent
              )) == expected else {
            throw OwnedDictionaryLifecycleErrorCode.destinationIdentityMismatchAfterRename
        }
    }

    private func inspectCatalogDirectories(
        roots: Roots,
        catalog: inout DictionaryCatalog,
        report: inout OwnedDictionaryLifecycleReport
    ) throws -> CatalogDirectoryInspection {
        var inspection = CatalogDirectoryInspection()
        for index in catalog.dictionaries.indices {
            try checkCancellation()
            let descriptor = catalog.dictionaries[index]
            guard DictionaryOwnershipPolicy.policy(
                for: descriptor.sourceKind, ownership: descriptor.storageOwnership
            )?.isAppManaged == true else { continue }
            let dictionaryID: String
            do {
                dictionaryID = try OwnedDictionaryLifecyclePOSIX.canonicalUUID(
                    descriptor.dictionaryID
                )
            } catch {
                disable(&catalog.dictionaries[index], state: .invalid)
                report.issue(.unsafePath, dictionaryID: descriptor.dictionaryID)
                continue
            }
            guard !(try OwnedDictionaryLifecyclePOSIX.isAbsent(
                roots.dictionaries, dictionaryID
            )) else {
                inspection.missingDictionaryIDs.insert(dictionaryID)
                continue
            }
            do {
                switch descriptor.storageOwnership {
                case .appManagedOpenResource:
                    let sidecar = try validateOpenResourceDirectory(
                        parent: roots.dictionaries, component: dictionaryID,
                        fullHash: false, expectedDictionaryID: dictionaryID, allowIndex: true
                    )
                    try match(sidecar: sidecar.sidecar, descriptor: descriptor)
                case .appManagedImported:
                    _ = try validateManagedLocalDirectory(
                        parent: roots.dictionaries, descriptor: descriptor
                    )
                case .externalReference, .bundledReadOnly:
                    continue
                }
                report.acceptedDictionaryIDs.append(dictionaryID)
                inspection.validatedDirectoryIDs.insert(dictionaryID)
            } catch let code as OwnedDictionaryLifecycleErrorCode {
                disable(&catalog.dictionaries[index], state: .corrupt)
                report.preservedDictionaryIDs.append(dictionaryID)
                report.issue(code, dictionaryID: dictionaryID)
            } catch {
                disable(&catalog.dictionaries[index], state: .corrupt)
                report.preservedDictionaryIDs.append(dictionaryID)
                report.issue(.invalidInstallationSidecar, dictionaryID: dictionaryID)
            }
        }
        return inspection
    }

    private func reconcilePendingDeletions(
        roots: Roots,
        catalog: inout DictionaryCatalog,
        report: inout OwnedDictionaryLifecycleReport
    ) throws -> Set<String> {
        var restored = Set<String>()
        for component in try OwnedDictionaryLifecyclePOSIX.entries(
            roots.pendingDeletion
        ).sorted() {
            try checkCancellation()
            let dictionaryID: String
            do {
                dictionaryID = try OwnedDictionaryLifecyclePOSIX.canonicalUUID(component)
            } catch {
                report.preservedDictionaryIDs.append(component)
                report.issue(.unexpectedOwnedEntry)
                continue
            }
            if let descriptorIndex = catalog.dictionaries.firstIndex(where: {
                $0.dictionaryID == dictionaryID
            }) {
                let descriptor = catalog.dictionaries[descriptorIndex]
                guard DictionaryOwnershipPolicy.policy(
                    for: descriptor.sourceKind, ownership: descriptor.storageOwnership
                )?.isRemovable == true else {
                    report.preservedDictionaryIDs.append(dictionaryID)
                    report.issue(.invalidOwnedDirectory, dictionaryID: dictionaryID)
                    continue
                }
                do {
                    let validated = try validateOwnedDirectory(
                        parent: roots.pendingDeletion, descriptor: descriptor, fullHash: false
                    )
                    guard try OwnedDictionaryLifecyclePOSIX.isAbsent(
                        roots.dictionaries, dictionaryID
                    ) else {
                        throw OwnedDictionaryLifecycleErrorCode.pendingDeletionConflict
                    }
                    try renameValidatedDirectory(
                        sourceParent: roots.pendingDeletion, sourceComponent: component,
                        destinationParent: roots.dictionaries,
                        destinationComponent: dictionaryID,
                        expected: validated.identity,
                        validatedCapability: validated.capability,
                        sourceRaceError: .pendingDeletionIdentityChanged
                    )
                    try hooks.synchronize(roots.dictionaries)
                    try hooks.synchronize(roots.pendingDeletion)
                    restored.insert(dictionaryID)
                    report.restoredDictionaryIDs.append(dictionaryID)
                } catch let code as OwnedDictionaryLifecycleErrorCode {
                    if code == .destinationIdentityMismatchAfterRename {
                        disable(&catalog.dictionaries[descriptorIndex], state: .corrupt)
                    }
                    report.preservedDictionaryIDs.append(dictionaryID)
                    let exactIdentityFailure = code == .pendingDeletionIdentityChanged ||
                        code == .destinationIdentityMismatchAfterRename
                    report.issue(code == .pendingDeletionConflict || exactIdentityFailure
                        ? code : .pendingDeletionRestoreFailed, dictionaryID: dictionaryID)
                } catch {
                    report.preservedDictionaryIDs.append(dictionaryID)
                    report.issue(.pendingDeletionRestoreFailed, dictionaryID: dictionaryID)
                }
            } else {
                do {
                    let ownership = try inferPendingOwnership(
                        parent: roots.pendingDeletion, component: component
                    )
                    try removeOwnedDirectory(parent: roots.pendingDeletion,
                                             component: component,
                                             ownership: ownership,
                                             descriptor: nil,
                                             allowIndex: true)
                    try hooks.synchronize(roots.pendingDeletion)
                    report.completedDeletionDictionaryIDs.append(dictionaryID)
                } catch let code as OwnedDictionaryLifecycleErrorCode {
                    report.preservedDictionaryIDs.append(dictionaryID)
                    report.issue(code == .unexpectedOwnedEntry
                        ? code : .pendingDeletionCleanupDeferred,
                        dictionaryID: dictionaryID)
                } catch {
                    report.preservedDictionaryIDs.append(dictionaryID)
                    report.issue(.pendingDeletionCleanupDeferred,
                                 dictionaryID: dictionaryID)
                }
            }
        }
        return restored
    }

    private func recoverFinalOrphans(
        roots: Roots,
        excluding durabilityUncertainIDs: Set<String>,
        catalog: inout DictionaryCatalog,
        report: inout OwnedDictionaryLifecycleReport
    ) throws {
        let knownIDs = Set(catalog.dictionaries.map(\.dictionaryID))
        var candidates: [(String, OpenResourceInstallationSidecar)] = []
        for component in try OwnedDictionaryLifecyclePOSIX.entries(
            roots.dictionaries
        ).sorted() where !knownIDs.contains(component) &&
            !durabilityUncertainIDs.contains(component) {
            try checkCancellation()
            do {
                let dictionaryID = try OwnedDictionaryLifecyclePOSIX.canonicalUUID(component)
                let sidecar = try validateOpenResourceDirectory(
                    parent: roots.dictionaries, component: component, fullHash: true,
                    expectedDictionaryID: dictionaryID, allowIndex: true
                )
                candidates.append((dictionaryID, sidecar.sidecar))
            } catch let code as OwnedDictionaryLifecycleErrorCode {
                report.preservedDictionaryIDs.append(component)
                report.issue(code)
            } catch {
                report.preservedDictionaryIDs.append(component)
                report.issue(.invalidInstallationSidecar)
            }
        }
        let grouped = Dictionary(grouping: candidates, by: { $0.1.resourceID })
        for (_, group) in grouped {
            guard group.count == 1 else {
                for (dictionaryID, _) in group {
                    report.preservedDictionaryIDs.append(dictionaryID)
                    report.issue(.duplicateResourceIdentity, dictionaryID: dictionaryID)
                }
                continue
            }
            let (dictionaryID, sidecar) = group[0]
            guard !catalog.dictionaries.contains(where: {
                $0.dictionaryID == dictionaryID ||
                    $0.openResourceMetadata?.resourceID == sidecar.resourceID
            }) else {
                report.preservedDictionaryIDs.append(dictionaryID)
                report.issue(.dictionaryIdentityConflict, dictionaryID: dictionaryID)
                continue
            }
            catalog.dictionaries.append(descriptor(from: sidecar, in: catalog))
            report.recoveredDictionaryIDs.append(dictionaryID)
        }
    }

    private func reconcileIndexes(roots: Roots,
                                  catalog: inout DictionaryCatalog,
                                  validatedDirectoryIDs: Set<String>,
                                  report: inout OwnedDictionaryLifecycleReport) throws {
        let now = Date()
        for index in catalog.dictionaries.indices {
            try checkCancellation()
            guard DictionaryOwnershipPolicy.policy(
                for: catalog.dictionaries[index].sourceKind,
                ownership: catalog.dictionaries[index].storageOwnership
            )?.isIndexable == true else { continue }
            let dictionaryID = catalog.dictionaries[index].dictionaryID
            guard (try? OwnedDictionaryLifecyclePOSIX.canonicalUUID(dictionaryID)) != nil,
                  !(try OwnedDictionaryLifecyclePOSIX.isAbsent(
                    roots.dictionaries, dictionaryID
                  )), validatedDirectoryIDs.contains(dictionaryID) else { continue }

            if catalog.dictionaries[index].state == .indexing {
                resetIndex(&catalog.dictionaries[index], now: now)
                report.downgradedDictionaryIDs.append(dictionaryID)
                report.issue(.interruptedIndexReset, dictionaryID: dictionaryID)
            }
            do {
                try removeKnownBuildingIfPresent(
                    parent: roots.dictionaries, dictionaryID: dictionaryID
                )
            } catch let code as OwnedDictionaryLifecycleErrorCode {
                report.preservedDictionaryIDs.append(dictionaryID)
                report.issue(code, dictionaryID: dictionaryID)
                continue
            }
            if catalog.dictionaries[index].state == .ready {
                let finalExists = try finalIndexExists(
                    parent: roots.dictionaries, dictionaryID: dictionaryID
                )
                if !finalExists {
                    resetIndex(&catalog.dictionaries[index], now: now)
                    report.downgradedDictionaryIDs.append(dictionaryID)
                }
            }
        }
    }

    private func markMissing(_ dictionaryIDs: Set<String>,
                             roots: Roots,
                             catalog: inout DictionaryCatalog,
                             report: inout OwnedDictionaryLifecycleReport) throws {
        for index in catalog.dictionaries.indices
        where dictionaryIDs.contains(catalog.dictionaries[index].dictionaryID) {
            let dictionaryID = catalog.dictionaries[index].dictionaryID
            // A no-replace restore may have completed before a directory fsync failed.
            // Preserve the prior Catalog state whenever the final name now exists; the
            // next startup will revalidate that directory instead of recording a false
            // missingResources state.
            guard try OwnedDictionaryLifecyclePOSIX.isAbsent(
                roots.dictionaries, dictionaryID
            ) else { continue }
            disable(&catalog.dictionaries[index], state: .missingResources)
            clearIndex(&catalog.dictionaries[index])
            report.downgradedDictionaryIDs.append(dictionaryID)
            report.issue(.dictionaryDirectoryMissing,
                         dictionaryID: dictionaryID)
        }
    }

    private func validateOpenResourceDirectory(
        parent: Int32,
        component: String,
        fullHash: Bool,
        expectedDictionaryID: String?,
        allowIndex: Bool
    ) throws -> ValidatedOpenResourceDirectory {
        let directory = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(parent, component)
        let capability = ValidatedDirectoryCapability(directory)
        let identity = try OwnedDictionaryLifecyclePOSIX.directoryIdentity(capability.descriptor)
        let allowed = allowIndex
            ? Set([OpenResourceInstallationIdentity.payloadComponent,
                   OpenResourceInstallationIdentity.sidecarComponent, "index"])
            : Set([OpenResourceInstallationIdentity.payloadComponent,
                   OpenResourceInstallationIdentity.sidecarComponent])
        guard try OwnedDictionaryLifecyclePOSIX.entries(capability.descriptor).isSubset(of: allowed) else {
            throw OwnedDictionaryLifecycleErrorCode.unexpectedOwnedEntry
        }
        let sidecarFD = try OwnedDictionaryLifecyclePOSIX.openRegular(
            capability.descriptor, OpenResourceInstallationIdentity.sidecarComponent
        )
        defer { Darwin.close(sidecarFD) }
        try OwnedDictionaryLifecyclePOSIX.validateRegularFile(
            OwnedDictionaryLifecyclePOSIX.metadata(sidecarFD), exactMode: 0o600
        )
        let sidecar: OpenResourceInstallationSidecar
        do {
            sidecar = try OpenResourceInstallationSidecar.decode(
                OwnedDictionaryLifecyclePOSIX.read(sidecarFD, maximum: 64 * 1024)
            )
        } catch {
            throw OwnedDictionaryLifecycleErrorCode.invalidInstallationSidecar
        }
        if let expectedDictionaryID, sidecar.dictionaryID != expectedDictionaryID {
            throw OwnedDictionaryLifecycleErrorCode.dictionaryIdentityConflict
        }
        let payloadFD = try OwnedDictionaryLifecyclePOSIX.openRegular(
            capability.descriptor, OpenResourceInstallationIdentity.payloadComponent
        )
        defer { Darwin.close(payloadFD) }
        try OwnedDictionaryLifecyclePOSIX.validateRegularFile(
            OwnedDictionaryLifecyclePOSIX.metadata(payloadFD), exactMode: 0o600,
            expectedSize: sidecar.payloadBytes
        )
        if fullHash,
           try OwnedDictionaryLifecyclePOSIX.sha256(payloadFD) != sidecar.payloadSHA256 {
            throw OwnedDictionaryLifecycleErrorCode.payloadIdentityMismatch
        }
        if allowIndex,
           !(try OwnedDictionaryLifecyclePOSIX.isAbsent(capability.descriptor, "index")) {
            try validateIndexDirectory(capability.descriptor, inventoryOnly: true)
        }
        return ValidatedOpenResourceDirectory(
            sidecar: sidecar, identity: identity, capability: capability
        )
    }

    private func validateManagedLocalDirectory(parent: Int32,
                                               descriptor: DictionaryDescriptor)
        throws -> ValidatedDirectoryCapability {
        let directory = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(
            parent, descriptor.dictionaryID
        )
        let capability = ValidatedDirectoryCapability(directory)
        let entries = try OwnedDictionaryLifecyclePOSIX.entries(capability.descriptor)
        try inventory(entries: entries, directory: capability.descriptor,
                      ownership: .appManagedImported,
                      descriptor: descriptor, allowIndex: true)
        guard let relativePath = descriptor.relativePaths.dictionary,
              let sourceComponents = ownedTail(relativePath,
                                               dictionaryID: descriptor.dictionaryID),
              sourceComponents.count == 1 || sourceComponents.count == 2 else {
            throw OwnedDictionaryLifecycleErrorCode.unsafePath
        }
        if sourceComponents.count == 1 {
            let file = try OwnedDictionaryLifecyclePOSIX.openRegular(
                capability.descriptor, sourceComponents[0]
            )
            Darwin.close(file)
        } else {
            guard sourceComponents[0] == "source" else {
                throw OwnedDictionaryLifecycleErrorCode.unsafePath
            }
            let source = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(
                capability.descriptor, "source"
            )
            defer { Darwin.close(source) }
            let file = try OwnedDictionaryLifecyclePOSIX.openRegular(source, sourceComponents[1])
            Darwin.close(file)
        }
        return capability
    }

    private func validateOwnedDirectory(parent: Int32,
                                        descriptor: DictionaryDescriptor,
                                        fullHash: Bool) throws -> ValidatedOwnedDirectory {
        switch descriptor.storageOwnership {
        case .appManagedOpenResource:
            let sidecar = try validateOpenResourceDirectory(
                parent: parent, component: descriptor.dictionaryID,
                fullHash: fullHash, expectedDictionaryID: descriptor.dictionaryID,
                allowIndex: true
            )
            try match(sidecar: sidecar.sidecar, descriptor: descriptor)
            return ValidatedOwnedDirectory(
                identity: sidecar.identity, capability: sidecar.capability
            )
        case .appManagedImported:
            let capability = try validateManagedLocalDirectory(
                parent: parent, descriptor: descriptor
            )
            let identity = try OwnedDictionaryLifecyclePOSIX.directoryIdentity(
                capability.descriptor
            )
            return ValidatedOwnedDirectory(identity: identity, capability: capability)
        case .externalReference, .bundledReadOnly:
            throw OwnedDictionaryLifecycleErrorCode.invalidOwnedDirectory
        }
    }

    private func match(sidecar: OpenResourceInstallationSidecar,
                       descriptor: DictionaryDescriptor) throws {
        guard descriptor.dictionaryID == sidecar.dictionaryID,
              descriptor.sourceKind == .openResource,
              descriptor.storageOwnership == .appManagedOpenResource,
              descriptor.formatterIdentifier == sidecar.formatterIdentifier,
              descriptor.relativePaths.dictionary ==
                "Dictionaries/\(sidecar.dictionaryID)/\(sidecar.payloadRelativePath)",
              descriptor.openResourceMetadata ==
                metadata(from: sidecar) else {
            throw OwnedDictionaryLifecycleErrorCode.dictionaryIdentityConflict
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

    private func descriptor(from sidecar: OpenResourceInstallationSidecar,
                            in catalog: DictionaryCatalog) -> DictionaryDescriptor {
        let position = (catalog.dictionaries.filter {
            $0.queryLevel == .fallback
        }.map(\.sortPosition).max() ?? -1) + 1
        return DictionaryDescriptor(
            dictionaryID: sidecar.dictionaryID,
            displayName: sidecar.resourceID,
            sourceKind: .openResource,
            queryLevel: .fallback,
            sortPosition: position,
            enabled: false,
            state: .pendingIndex,
            indexMetadata: DictionaryIndexMetadata(
                schemaVersion: nil, entryCount: nil, indexFileSize: nil,
                sourceFileSize: sidecar.payloadBytes, sourceModifiedAt: nil,
                sourceSHA256: sidecar.payloadSHA256, indexedAt: nil
            ),
            formatterIdentifier: sidecar.formatterIdentifier,
            capabilities: .unknown,
            relativePaths: DictionaryRelativePaths(
                dictionary:
                    "Dictionaries/\(sidecar.dictionaryID)/\(sidecar.payloadRelativePath)",
                resources: [], index: nil
            ),
            createdAt: sidecar.installedAt,
            updatedAt: Date(),
            storageOwnership: .appManagedOpenResource,
            openResourceMetadata: metadata(from: sidecar)
        )
    }

    private func inferPendingOwnership(parent: Int32, component: String) throws
        -> DictionaryStorageOwnership {
        let directory = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(parent, component)
        defer { Darwin.close(directory) }
        let entries = try OwnedDictionaryLifecyclePOSIX.entries(directory)
        if entries.contains(OpenResourceInstallationIdentity.sidecarComponent) {
            _ = try validateOpenResourceDirectory(
                parent: parent, component: component, fullHash: false,
                expectedDictionaryID: component, allowIndex: true
            )
            return .appManagedOpenResource
        }
        guard entries.contains(where: {
            URL(fileURLWithPath: $0).pathExtension.caseInsensitiveCompare("mdx") == .orderedSame
        }) || entries.contains("source") else {
            throw OwnedDictionaryLifecycleErrorCode.invalidOwnedDirectory
        }
        return .appManagedImported
    }

    private func removeOwnedDirectory(parent: Int32,
                                      component: String,
                                      ownership: DictionaryStorageOwnership,
                                      descriptor: DictionaryDescriptor?,
                                      allowIndex: Bool) throws {
        if let descriptor {
            _ = try validateOwnedDirectory(parent: parent, descriptor: descriptor, fullHash: false)
        } else if ownership == .appManagedOpenResource {
            _ = try validateOpenResourceDirectory(
                parent: parent, component: component, fullHash: false,
                expectedDictionaryID: nil, allowIndex: allowIndex
            )
        }
        var directory = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(parent, component)
        defer {
            if directory >= 0 { Darwin.close(directory) }
        }
        let entries = try OwnedDictionaryLifecyclePOSIX.entries(directory)
        try inventory(entries: entries, directory: directory, ownership: ownership,
                      descriptor: descriptor, allowIndex: allowIndex)
        try hooks.beforeDelete(component)
        for entry in entries.sorted() {
            let metadata = try OwnedDictionaryLifecyclePOSIX.entryMetadata(directory, entry)
            if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                let child = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(directory, entry)
                do {
                    let childEntries = try OwnedDictionaryLifecyclePOSIX.entries(child)
                    for childEntry in childEntries.sorted() {
                        try OwnedDictionaryLifecyclePOSIX.unlink(
                            child, childEntry, directory: false
                        )
                    }
                    try hooks.synchronize(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                guard Darwin.close(child) == 0 else {
                    throw OwnedDictionaryLifecycleErrorCode.ioFailure
                }
                try OwnedDictionaryLifecyclePOSIX.unlink(directory, entry, directory: true)
            } else {
                try OwnedDictionaryLifecyclePOSIX.unlink(directory, entry, directory: false)
            }
        }
        try hooks.synchronize(directory)
        guard Darwin.close(directory) == 0 else {
            throw OwnedDictionaryLifecycleErrorCode.ioFailure
        }
        directory = -1
        try OwnedDictionaryLifecyclePOSIX.unlink(parent, component, directory: true)
    }

    private func inventory(entries: Set<String>,
                           directory: Int32,
                           ownership: DictionaryStorageOwnership,
                           descriptor: DictionaryDescriptor?,
                           allowIndex: Bool) throws {
        var allowedFiles = Set<String>()
        var allowedDirectories = Set<String>()
        switch ownership {
        case .appManagedOpenResource:
            allowedFiles = [
                OpenResourceInstallationIdentity.payloadComponent,
                OpenResourceInstallationIdentity.sidecarComponent
            ]
            if allowIndex { allowedDirectories.insert("index") }
        case .appManagedImported:
            if let descriptor {
                for path in [descriptor.relativePaths.dictionary].compactMap({ $0 }) +
                    descriptor.relativePaths.resources {
                    guard let tail = ownedTail(path, dictionaryID: descriptor.dictionaryID)
                    else { throw OwnedDictionaryLifecycleErrorCode.unsafePath }
                    if tail.count == 1 { allowedFiles.insert(tail[0]) }
                    else if tail.count == 2, tail[0] == "source" {
                        allowedDirectories.insert("source")
                    } else { throw OwnedDictionaryLifecycleErrorCode.unsafePath }
                }
            } else {
                for entry in entries {
                    let ext = URL(fileURLWithPath: entry).pathExtension.lowercased()
                    if ext == "mdx" || ext == "mdd" { allowedFiles.insert(entry) }
                }
                allowedDirectories.insert("source")
            }
            if allowIndex { allowedDirectories.insert("index") }
        case .externalReference, .bundledReadOnly:
            throw OwnedDictionaryLifecycleErrorCode.invalidOwnedDirectory
        }
        guard entries.isSubset(of: allowedFiles.union(allowedDirectories)) else {
            throw OwnedDictionaryLifecycleErrorCode.unexpectedOwnedEntry
        }
        for file in allowedFiles.intersection(entries) {
            try OwnedDictionaryLifecyclePOSIX.validateRegularFile(
                OwnedDictionaryLifecyclePOSIX.entryMetadata(directory, file)
            )
        }
        for childName in allowedDirectories.intersection(entries) {
            if childName == "index" {
                try validateIndexDirectory(directory, inventoryOnly: false)
            } else {
                let child = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(
                    directory, childName
                )
                defer { Darwin.close(child) }
                let childEntries = try OwnedDictionaryLifecyclePOSIX.entries(child)
                guard childEntries.allSatisfy({
                    let ext = URL(fileURLWithPath: $0).pathExtension.lowercased()
                    return ext == "mdx" || ext == "mdd"
                }) else {
                    throw OwnedDictionaryLifecycleErrorCode.unexpectedOwnedEntry
                }
                for entry in childEntries {
                    try OwnedDictionaryLifecyclePOSIX.validateRegularFile(
                        OwnedDictionaryLifecyclePOSIX.entryMetadata(child, entry)
                    )
                }
            }
        }
    }

    private func validateIndexDirectory(_ dictionaryDirectory: Int32,
                                        inventoryOnly: Bool) throws {
        let index = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(
            dictionaryDirectory, "index"
        )
        defer { Darwin.close(index) }
        let allowed = Set([
            "dictionary.sqlite", "dictionary.sqlite.building",
            "dictionary.sqlite.previous", "dictionary.sqlite-wal",
            "dictionary.sqlite-shm"
        ])
#if OWNED_LIFECYCLE_TESTING
        try OwnedDictionaryLifecycleTestObserver.beforeIndexInventory?()
#endif
        let entries = try OwnedDictionaryLifecyclePOSIX.entries(index)
        guard entries.isSubset(of: allowed) else {
            throw OwnedDictionaryLifecycleErrorCode.indexInventoryContainsUnknownEntries
        }
        for entry in entries {
            try OwnedDictionaryLifecyclePOSIX.validateRegularFile(
                OwnedDictionaryLifecyclePOSIX.entryMetadata(index, entry)
            )
        }
        _ = inventoryOnly
    }

    private func removeKnownBuildingIfPresent(parent: Int32,
                                              dictionaryID: String) throws {
        let directory = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(
            parent, dictionaryID
        )
        defer { Darwin.close(directory) }
        guard !(try OwnedDictionaryLifecyclePOSIX.isAbsent(directory, "index")) else {
            return
        }
        let index = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(directory, "index")
        defer { Darwin.close(index) }
        // Validate the complete inventory at the deletion boundary.  A
        // descriptor accepted earlier in this run is not authority to remove
        // a known file after an unknown entry has appeared.
        try validateIndexDirectory(directory, inventoryOnly: true)
        guard !(try OwnedDictionaryLifecyclePOSIX.isAbsent(
            index, "dictionary.sqlite.building"
        )) else { return }
        try OwnedDictionaryLifecyclePOSIX.validateRegularFile(
            OwnedDictionaryLifecyclePOSIX.entryMetadata(index,
                                                        "dictionary.sqlite.building")
        )
        try OwnedDictionaryLifecyclePOSIX.unlink(
            index, "dictionary.sqlite.building", directory: false
        )
        try hooks.synchronize(index)
    }

    private func finalIndexExists(parent: Int32, dictionaryID: String) throws -> Bool {
        let directory = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(
            parent, dictionaryID
        )
        defer { Darwin.close(directory) }
        guard !(try OwnedDictionaryLifecyclePOSIX.isAbsent(directory, "index")) else {
            return false
        }
        let index = try OwnedDictionaryLifecyclePOSIX.openChildDirectory(directory, "index")
        defer { Darwin.close(index) }
        guard !(try OwnedDictionaryLifecyclePOSIX.isAbsent(
            index, "dictionary.sqlite"
        )) else { return false }
        try OwnedDictionaryLifecyclePOSIX.validateRegularFile(
            OwnedDictionaryLifecyclePOSIX.entryMetadata(index, "dictionary.sqlite")
        )
        return true
    }

    private func ownedTail(_ path: String, dictionaryID: String) -> [String]? {
        guard !path.isEmpty, !NSString(string: path).isAbsolutePath,
              !path.contains("\\"), !path.contains("://") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count >= 3,
              components[0] == "Dictionaries",
              components[1] == dictionaryID,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        return Array(components.dropFirst(2))
    }

    private func disable(_ descriptor: inout DictionaryDescriptor,
                         state: DictionaryState) {
        descriptor.enabled = false
        descriptor.state = state
        descriptor.updatedAt = Date()
    }

    private func resetIndex(_ descriptor: inout DictionaryDescriptor, now: Date) {
        descriptor.state = .pendingIndex
        descriptor.relativePaths.index = nil
        clearIndex(&descriptor)
        descriptor.updatedAt = now
    }

    private func clearIndex(_ descriptor: inout DictionaryDescriptor) {
        descriptor.indexMetadata.schemaVersion = nil
        descriptor.indexMetadata.entryCount = nil
        descriptor.indexMetadata.indexFileSize = nil
        descriptor.indexMetadata.indexedAt = nil
        descriptor.relativePaths.index = nil
    }

    private func checkCancellation() throws {
        if cancellationToken.isCancelled {
            throw OwnedDictionaryLifecycleErrorCode.cancelled
        }
    }
}

@MainActor
final class OwnedDictionaryLifecycleReconciler {
    private let catalogStore: DictionaryCatalogStore
    private let worker: OwnedDictionaryLifecycleWorker
    private var reconciliationInProgress = false

    init(
        catalogStore: DictionaryCatalogStore,
        applicationSupportRootURL: URL =
            OwnedDictionaryLifecycleReconciler.defaultApplicationSupportRootURL(),
        stagingRootURL: URL? = nil,
        hooks: OwnedDictionaryLifecycleHooks = .live,
        cancellationToken: OwnedDictionaryLifecycleCancellationToken =
            OwnedDictionaryLifecycleCancellationToken()
    ) {
        self.catalogStore = catalogStore
        let staging = stagingRootURL ??
            applicationSupportRootURL.appendingPathComponent("Staging", isDirectory: true)
        worker = OwnedDictionaryLifecycleWorker(
            applicationSupportRootURL: applicationSupportRootURL,
            stagingRootURL: staging,
            hooks: hooks,
            cancellationToken: cancellationToken
        )
    }

    nonisolated static func defaultApplicationSupportRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("LocalDictionary", isDirectory: true)
    }

    func reconcile() async -> OwnedDictionaryLifecycleResult {
        let loaded = catalogStore.loadResult()
        guard let catalog = loaded.catalog else {
            var report = OwnedDictionaryLifecycleReport(
                catalogProvenance: loaded.provenance, blocked: true
            )
            report.issue(loaded.provenance == .unsupportedVersion
                ? .lifecycleBlockedByUnsupportedCatalog
                : .lifecycleBlockedByCorruptCatalog)
            return OwnedDictionaryLifecycleResult(catalog: .empty(), report: report)
        }
        guard !reconciliationInProgress else {
            var report = OwnedDictionaryLifecycleReport(
                catalogProvenance: loaded.provenance, blocked: true
            )
            report.issue(.ioFailure)
            return OwnedDictionaryLifecycleResult(catalog: catalog, report: report)
        }
        reconciliationInProgress = true
        defer { reconciliationInProgress = false }

        let worker = self.worker
        let prepared = await Task.detached(priority: .utility) {
            worker.prepare(catalog: catalog, provenance: loaded.provenance)
        }.value
        guard prepared.proposedCatalog != prepared.originalCatalog else {
            return OwnedDictionaryLifecycleResult(
                catalog: prepared.originalCatalog, report: prepared.report
            )
        }
        do {
            let mutation = try catalogStore.mutate { latest, provenance in
                let sameSnapshot = latest == prepared.originalCatalog ||
                    (provenance == .missing &&
                     prepared.report.catalogProvenance == .missing &&
                     latest.dictionaries.isEmpty &&
                     prepared.originalCatalog.dictionaries.isEmpty)
                guard sameSnapshot else {
                    throw OwnedDictionaryLifecycleErrorCode
                        .catalogCommitFailedAfterFilesystemMutation
                }
                latest = prepared.proposedCatalog
            }
            return OwnedDictionaryLifecycleResult(
                catalog: mutation.catalog, report: prepared.report
            )
        } catch {
            var report = prepared.report
            report.issue(.catalogCommitFailedAfterFilesystemMutation)
            return OwnedDictionaryLifecycleResult(
                catalog: catalogStore.loadResult().catalog ?? prepared.originalCatalog,
                report: report
            )
        }
    }
}
