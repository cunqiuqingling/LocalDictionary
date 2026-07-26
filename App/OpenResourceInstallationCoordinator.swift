import CryptoKit
import Darwin
import Foundation

/// Owns only the short verified-to-final installation step.  It deliberately does not reconcile
/// orphaned directories or expose open resources to indexing/query code; those are later phases.
actor OpenResourceInstallationCoordinator {
    private var activeResourceIDs: Set<String> = []

    func install(_ verified: VerifiedPayloadStagingResult,
                 dictionariesRoot: URL,
                 catalogStore: DictionaryCatalogStore) async throws -> DictionaryDescriptor {
        let resourceID = verified.installationIdentity.resourceID
        guard activeResourceIDs.insert(resourceID).inserted else {
            throw OpenResourceInstallationError.installationInProgress
        }
        defer { activeResourceIDs.remove(resourceID) }

        let prepared = try await Task.detached(priority: .utility) {
            try OpenResourceInstallationFileWorker.prepare(verified: verified)
        }.value

        return try await MainActor.run {
            try catalogStore.withMutationLock {
                let current = catalogStore.loadResult()
                guard let catalog = current.catalog else {
                    throw OpenResourceInstallationError.invalidIdentity
                }
                guard !catalog.dictionaries.contains(where: { $0.dictionaryID == prepared.identity.dictionaryID ||
                    $0.openResourceMetadata?.resourceID == prepared.identity.resourceID }) else {
                    throw OpenResourceInstallationError.conflict
                }

                let published: OpenResourceInstallationFileWorker.PublishedDirectory
                do {
                    published = try OpenResourceInstallationFileWorker.publish(prepared: prepared,
                                                                                dictionariesRoot: dictionariesRoot)
                } catch let error as OpenResourceInstallationError {
                    throw error
                } catch {
                    throw OpenResourceInstallationError.unsafeVerifiedPayload
                }
                let now = Date()
                let descriptor = DictionaryDescriptor(
                    dictionaryID: prepared.identity.dictionaryID,
                    displayName: prepared.identity.resourceID,
                    sourceKind: .openResource,
                    queryLevel: .fallback,
                    sortPosition: Self.nextFallbackPosition(in: catalog),
                    enabled: true,
                    state: .pendingIndex,
                    indexMetadata: DictionaryIndexMetadata(schemaVersion: nil, entryCount: nil,
                                                           indexFileSize: nil, sourceFileSize: prepared.identity.payloadBytes,
                                                           sourceModifiedAt: nil, sourceSHA256: prepared.identity.payloadSHA256,
                                                           indexedAt: nil),
                    formatterIdentifier: prepared.identity.formatterIdentifier,
                    capabilities: .unknown,
                    relativePaths: DictionaryRelativePaths(
                        dictionary: "Dictionaries/\(prepared.identity.dictionaryID)/\(OpenResourceInstallationIdentity.payloadComponent)",
                        resources: [], index: nil),
                    createdAt: now, updatedAt: now,
                    storageOwnership: .appManagedOpenResource,
                    openResourceMetadata: prepared.identity.catalogMetadata
                )
                var updated = catalog
                updated.dictionaries.append(descriptor)
                updated.updatedAt = now
                do {
                    try catalogStore.save(updated)
                } catch {
                    // The filesystem publication is now intentionally retained for 2B recovery.
                    _ = published
                    throw OpenResourceInstallationError.catalogCommitFailedAfterFilesystemPublish
                }
                return descriptor
            }
        }
    }

    private nonisolated static func nextFallbackPosition(in catalog: DictionaryCatalog) -> Int64 {
        (catalog.dictionaries.filter { $0.queryLevel == .fallback }.map(\.sortPosition).max() ?? -1) + 1
    }
}

private enum OpenResourceInstallationFileWorker {
    struct Prepared: Sendable {
        let verified: VerifiedPayloadStagingResult
        let identity: OpenResourceInstallationIdentity
        let directoryIdentity: PayloadFileIdentity
        let payloadIdentity: PayloadFileIdentity
        let sidecarIdentity: PayloadFileIdentity
    }
    struct PublishedDirectory: Sendable { let directoryURL: URL }

    static func prepare(verified: VerifiedPayloadStagingResult) throws -> Prepared {
        guard verified.resourceID == verified.installationIdentity.resourceID,
              verified.resourceRevision == verified.installationIdentity.resourceRevision,
              verified.actualByteCount == verified.installationIdentity.payloadBytes,
              verified.verifiedSHA256 == verified.installationIdentity.payloadSHA256,
              verified.payloadComponent == OpenResourceInstallationIdentity.payloadComponent,
              verified.sidecarComponent == OpenResourceInstallationIdentity.sidecarComponent else {
            throw OpenResourceInstallationError.invalidIdentity
        }
        try component(verified.verifiedDirectoryComponent)
        let root = try openDirectory(verified.stagingRootURL, create: false)
        defer { Darwin.close(root) }
        let directory = try openChildDirectory(root, verified.verifiedDirectoryComponent)
        defer { Darwin.close(directory) }
        let directoryStat = try metadata(directory)
        try secureDirectory(directoryStat)
        let entry = try entryMetadata(root, verified.verifiedDirectoryComponent)
        guard same(directoryStat, entry) else { throw OpenResourceInstallationError.unsafeVerifiedPayload }
        let names = try directoryEntries(directory)
        guard names == Set([OpenResourceInstallationIdentity.payloadComponent,
                            OpenResourceInstallationIdentity.sidecarComponent]) else {
            throw OpenResourceInstallationError.unsafeVerifiedPayload
        }
        let payload = try openRegular(directory, OpenResourceInstallationIdentity.payloadComponent)
        defer { Darwin.close(payload) }
        let sidecar = try openRegular(directory, OpenResourceInstallationIdentity.sidecarComponent)
        defer { Darwin.close(sidecar) }
        let payloadStat = try metadata(payload); let sidecarStat = try metadata(sidecar)
        try secureFile(payloadStat, size: Int64(verified.installationIdentity.payloadBytes))
        try secureFile(sidecarStat, size: nil)
        guard same(payloadStat, try entryMetadata(directory, OpenResourceInstallationIdentity.payloadComponent)),
              same(sidecarStat, try entryMetadata(directory, OpenResourceInstallationIdentity.sidecarComponent)) else {
            throw OpenResourceInstallationError.unsafeVerifiedPayload
        }
        let digest = try hash(payload)
        guard digest == verified.installationIdentity.payloadSHA256 else {
            throw OpenResourceInstallationError.unsafeVerifiedPayload
        }
        let sidecarData = try read(sidecar, maximum: 64 * 1024)
        _ = try OpenResourceInstallationSidecar.decode(sidecarData).validated(expected: verified.installationIdentity)
        return Prepared(verified: verified, identity: verified.installationIdentity,
                        directoryIdentity: PayloadFileIdentity(directoryStat),
                        payloadIdentity: PayloadFileIdentity(payloadStat), sidecarIdentity: PayloadFileIdentity(sidecarStat))
    }

    static func publish(prepared: Prepared, dictionariesRoot: URL) throws -> PublishedDirectory {
        let stagingRoot = try openDirectory(prepared.verified.stagingRootURL, create: false)
        defer { Darwin.close(stagingRoot) }
        let dictionaries = try openDirectory(dictionariesRoot, create: true)
        defer { Darwin.close(dictionaries) }
        let verifiedFD = try openChildDirectory(stagingRoot, prepared.verified.verifiedDirectoryComponent)
        defer { Darwin.close(verifiedFD) }
        let verifiedStat = try metadata(verifiedFD)
        try secureDirectory(verifiedStat)
        guard PayloadFileIdentity(verifiedStat) == prepared.directoryIdentity else {
            throw OpenResourceInstallationError.unsafeVerifiedPayload
        }
        let payloadFD = try openRegular(verifiedFD, OpenResourceInstallationIdentity.payloadComponent)
        defer { Darwin.close(payloadFD) }
        let sidecarFD = try openRegular(verifiedFD, OpenResourceInstallationIdentity.sidecarComponent)
        defer { Darwin.close(sidecarFD) }
        guard PayloadFileIdentity(try metadata(payloadFD)) == prepared.payloadIdentity,
              PayloadFileIdentity(try metadata(sidecarFD)) == prepared.sidecarIdentity,
              try directoryEntries(verifiedFD) == Set([OpenResourceInstallationIdentity.payloadComponent,
                                                        OpenResourceInstallationIdentity.sidecarComponent]) else {
            throw OpenResourceInstallationError.unsafeVerifiedPayload
        }
        try component(prepared.identity.dictionaryID)
        let result = prepared.verified.verifiedDirectoryComponent.withCString { source in
            prepared.identity.dictionaryID.withCString { destination in
                Darwin.renameatx_np(stagingRoot, source, dictionaries, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EXDEV { throw OpenResourceInstallationError.crossDevicePublication }
            if errno == EEXIST { throw OpenResourceInstallationError.conflict }
            throw OpenResourceInstallationError.unsafeVerifiedPayload
        }
        let finalEntry = try entryMetadata(dictionaries, prepared.identity.dictionaryID)
        guard same(verifiedStat, finalEntry) else { throw OpenResourceInstallationError.unsafeVerifiedPayload }
        guard Darwin.fsync(dictionaries) == 0 else { throw OpenResourceInstallationError.durabilityFailure }
        return PublishedDirectory(directoryURL: dictionariesRoot.standardizedFileURL
            .appendingPathComponent(prepared.identity.dictionaryID, isDirectory: true))
    }

    private static func component(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
              !value.contains("\\"), !value.contains("\0"), !NSString(string: value).isAbsolutePath else {
            throw OpenResourceInstallationError.unsafeVerifiedPayload
        }
    }
    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        if create {
            let result = url.path.withCString { Darwin.mkdir($0, 0o700) }
            guard result == 0 || errno == EEXIST else { throw OpenResourceInstallationError.unsafeVerifiedPayload }
        }
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload }
        let value = try metadata(fd); try secureDirectory(value); return fd
    }
    private static func openChildDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        try component(name); let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload }; return fd
    }
    private static func openRegular(_ parent: Int32, _ name: String) throws -> Int32 {
        try component(name); let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload }; return fd
    }
    private static func metadata(_ fd: Int32) throws -> stat { var value = stat(); guard Darwin.fstat(fd, &value) == 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload }; return value }
    private static func entryMetadata(_ parent: Int32, _ name: String) throws -> stat { try component(name); var value = stat(); guard name.withCString({ Darwin.fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload }; return value }
    private static func secureDirectory(_ value: stat) throws { guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), value.st_uid == geteuid(), (value.st_mode & mode_t(0o022)) == 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload } }
    private static func secureFile(_ value: stat, size: Int64?) throws { guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), value.st_uid == geteuid(), (value.st_mode & mode_t(0o777)) == mode_t(0o600), value.st_nlink == 1, size.map({ value.st_size == $0 }) ?? true else { throw OpenResourceInstallationError.unsafeVerifiedPayload } }
    private static func same(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && (lhs.st_mode & mode_t(S_IFMT)) == (rhs.st_mode & mode_t(S_IFMT)) && lhs.st_uid == rhs.st_uid }
    private static func hash(_ fd: Int32) throws -> String { guard Darwin.lseek(fd, 0, SEEK_SET) >= 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload }; var hasher = SHA256(); var buffer = [UInt8](repeating: 0, count: 65_536); while true { let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }; if count > 0 { hasher.update(data: Data(buffer[0..<Int(count)])) } else if count == 0 { break } else if errno != EINTR { throw OpenResourceInstallationError.unsafeVerifiedPayload } }; return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
    private static func read(_ fd: Int32, maximum: Int) throws -> Data { guard Darwin.lseek(fd, 0, SEEK_SET) >= 0 else { throw OpenResourceInstallationError.unsafeVerifiedPayload }; var output = Data(); var buffer = [UInt8](repeating: 0, count: 4096); while true { let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }; if count > 0 { guard output.count + Int(count) <= maximum else { throw OpenResourceInstallationError.invalidSidecar }; output.append(buffer, count: Int(count)) } else if count == 0 { return output } else if errno != EINTR { throw OpenResourceInstallationError.unsafeVerifiedPayload } } }
    private static func directoryEntries(_ fd: Int32) throws -> Set<String> {
        let copy = Darwin.dup(fd); guard copy >= 0, let directory = Darwin.fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw OpenResourceInstallationError.unsafeVerifiedPayload }
        defer { Darwin.closedir(directory) }
        var names = Set<String>()
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.insert(name) }
        }
        return names
    }
}
