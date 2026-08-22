import CryptoKit
import Darwin
import Foundation

enum ResourcePayloadCapacitySample: Equatable, Sendable {
    case value(Int64)
    case unavailable
    case failed
}

struct ResourcePayloadCapacityMeasurement: Equatable, Sendable {
    let ordinary: ResourcePayloadCapacitySample
    let important: ResourcePayloadCapacitySample
    let opportunistic: ResourcePayloadCapacitySample
}

enum ResourcePayloadCapacityAdmission {
    static func effectiveCapacity(
        for measurement: ResourcePayloadCapacityMeasurement
    ) -> UInt64? {
        let trusted = [measurement.ordinary, measurement.important].compactMap {
            sample -> UInt64? in
            guard case .value(let value) = sample, value >= 0 else { return nil }
            return UInt64(value)
        }
        return trusted.max()
    }
}

/// The small injectable surface is used by synthetic payload tests. Production operations remain
/// rooted in directory descriptors; no hook receives or resolves a descendant absolute path.
struct ResourcePayloadFileSystemHooks: Sendable {
    let capacityMeasurement: @Sendable (URL) throws -> ResourcePayloadCapacityMeasurement
    let writeAll: @Sendable (Int32, Data) throws -> Void
    let synchronize: @Sendable (Int32) throws -> Void
    let close: @Sendable (Int32) throws -> Void
    let renameNoReplaceAt: @Sendable (Int32, String, Int32, String) throws -> Void

    static let production = ResourcePayloadFileSystemHooks(
        capacityMeasurement: { root in
            let values = try root.resourceValues(forKeys: [
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityForOpportunisticUsageKey
            ])
            return ResourcePayloadCapacityMeasurement(
                ordinary: values.volumeAvailableCapacity.map {
                    .value(Int64($0))
                } ?? .unavailable,
                important: values.volumeAvailableCapacityForImportantUsage.map {
                    .value($0)
                } ?? .unavailable,
                opportunistic: values.volumeAvailableCapacityForOpportunisticUsage.map {
                    .value($0)
                } ?? .unavailable
            )
        },
        writeAll: { descriptor, data in
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if result > 0 {
                        offset += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        throw ResourcePayloadDownloadError.writeFailure
                    }
                }
            }
        },
        synchronize: { descriptor in
            guard Darwin.fsync(descriptor) == 0 else {
                throw ResourcePayloadDownloadError.durabilityFailure
            }
        },
        close: { descriptor in
            guard Darwin.close(descriptor) == 0 else {
                throw ResourcePayloadDownloadError.ioFailure
            }
        },
        renameNoReplaceAt: { sourceDirectory, source, destinationDirectory, destination in
            let result = source.withCString { sourceName in
                destination.withCString { destinationName in
                    Darwin.renameatx_np(
                        sourceDirectory,
                        sourceName,
                        destinationDirectory,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                throw ResourcePayloadStagingPOSIX.error(for: errno, durability: false)
            }
        }
    )

    init(
        capacityMeasurement: @escaping @Sendable (URL) throws
            -> ResourcePayloadCapacityMeasurement,
        writeAll: @escaping @Sendable (Int32, Data) throws -> Void,
        synchronize: @escaping @Sendable (Int32) throws -> Void,
        close: @escaping @Sendable (Int32) throws -> Void,
        renameNoReplaceAt: @escaping @Sendable (Int32, String, Int32, String) throws -> Void
    ) {
        self.capacityMeasurement = capacityMeasurement
        self.writeAll = writeAll
        self.synchronize = synchronize
        self.close = close
        self.renameNoReplaceAt = renameNoReplaceAt
    }

    /// Compatibility initializer for existing synthetic downloader tests. The supplied value is
    /// treated as one raw ordinary-capacity sample; admission still runs through production policy.
    init(
        availableCapacity: @escaping @Sendable (URL) throws -> UInt64,
        writeAll: @escaping @Sendable (Int32, Data) throws -> Void,
        synchronize: @escaping @Sendable (Int32) throws -> Void,
        close: @escaping @Sendable (Int32) throws -> Void,
        renameNoReplaceAt: @escaping @Sendable (Int32, String, Int32, String) throws -> Void
    ) {
        self.init(
            capacityMeasurement: { root in
                let capacity = try availableCapacity(root)
                return ResourcePayloadCapacityMeasurement(
                    ordinary: .value(Int64(clamping: capacity)),
                    important: .unavailable,
                    opportunistic: .unavailable
                )
            },
            writeAll: writeAll,
            synchronize: synchronize,
            close: close,
            renameNoReplaceAt: renameNoReplaceAt
        )
    }
}

fileprivate final class OwnedFileDescriptor {
    private var descriptor: Int32
    private let closeAction: (Int32) throws -> Void

    init(_ descriptor: Int32, closeAction: @escaping (Int32) throws -> Void) {
        self.descriptor = descriptor
        self.closeAction = closeAction
    }

    var isOpen: Bool { descriptor >= 0 }

    func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        guard descriptor >= 0 else { throw ResourcePayloadDownloadError.ioFailure }
        return try body(descriptor)
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let current = descriptor
        descriptor = -1
        try closeAction(current)
    }

    deinit {
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }
}

struct PayloadFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let fileType: mode_t
    let owner: uid_t
    let linkCount: UInt64
    let size: Int64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        fileType = metadata.st_mode & mode_t(S_IFMT)
        owner = metadata.st_uid
        linkCount = UInt64(metadata.st_nlink)
        size = Int64(metadata.st_size)
    }
}

private enum ResourcePayloadStagingPOSIX {
    static func error(
        for value: Int32 = errno,
        durability: Bool = false,
        missing: ResourcePayloadDownloadError = .temporaryFileMissing
    ) -> ResourcePayloadDownloadError {
        if durability { return .durabilityFailure }
        switch value {
        case ENOENT: return missing
        case EEXIST: return .conflict
        case ELOOP, ENOTDIR: return .unsafePath
        case EACCES, EPERM: return .permissionDenied
        case ENOSPC, EDQUOT: return .insufficientDiskSpace
        case EXDEV: return .crossDevicePublication
        case EIO: return .ioFailure
        default: return .ioFailure
        }
    }

    static func requireSingleComponent(_ value: String) throws {
        guard !value.isEmpty,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.contains("\0"),
              !value.contains("://"),
              !NSString(string: value).isAbsolutePath else {
            throw ResourcePayloadDownloadError.invalidPathComponent
        }
    }

    static func metadata(for descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw error() }
        return value
    }

    static func entryMetadata(parent: Int32, component: String) throws -> stat {
        try requireSingleComponent(component)
        var value = stat()
        let result = component.withCString { name in
            Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw error() }
        return value
    }

    static func entryIsAbsent(parent: Int32, component: String) throws {
        try requireSingleComponent(component)
        var value = stat()
        let result = component.withCString { name in
            Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { throw ResourcePayloadDownloadError.conflict }
        guard errno == ENOENT else { throw error() }
    }

    static func validateDirectory(_ metadata: stat) throws {
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ResourcePayloadDownloadError.unexpectedFileType
        }
        guard metadata.st_uid == geteuid() else { throw ResourcePayloadDownloadError.permissionDenied }
        guard (metadata.st_mode & 0o022) == 0 else { throw ResourcePayloadDownloadError.permissionDenied }
    }

    static func validatePayloadFile(_ metadata: stat, expectedSize: Int64? = nil) throws {
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ResourcePayloadDownloadError.unexpectedFileType
        }
        guard metadata.st_uid == geteuid() else { throw ResourcePayloadDownloadError.permissionDenied }
        guard (metadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw ResourcePayloadDownloadError.unexpectedPermissions
        }
        if metadata.st_nlink == 0 { throw ResourcePayloadDownloadError.identityChanged }
        guard metadata.st_nlink == 1 else { throw ResourcePayloadDownloadError.unexpectedLinkCount }
        if let expectedSize, metadata.st_size != expectedSize {
            throw ResourcePayloadDownloadError.identityChanged
        }
    }

    static func identitiesMatch(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
            (left.st_mode & mode_t(S_IFMT)) == (right.st_mode & mode_t(S_IFMT))
    }

    static func readBoundedExactly(_ descriptor: Int32, maximum: Int) throws -> Data {
        let metadata = try metadata(for: descriptor)
        guard metadata.st_size >= 0, metadata.st_size <= Int64(maximum) else {
            throw ResourcePayloadDownloadError.sidecarIdentityMismatch
        }
        let expected = Int(metadata.st_size)
        var output = Data(count: expected)
        var offset = 0
        while offset < expected {
            let count = output.withUnsafeMutableBytes { buffer in
                Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: offset),
                             expected - offset, off_t(offset))
            }
            if count > 0 { offset += count }
            else if count < 0, errno == EINTR { continue }
            else { throw ResourcePayloadDownloadError.sidecarIdentityMismatch }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0, after.st_size == metadata.st_size else {
            throw ResourcePayloadDownloadError.sidecarIdentityMismatch
        }
        return output
    }

    static func unlinkKnown(parent: Int32, component: String, directory: Bool = false) {
        guard (try? requireSingleComponent(component)) != nil else { return }
        let flags: Int32 = directory ? AT_REMOVEDIR : 0
        let result = component.withCString { Darwin.unlinkat(parent, $0, flags) }
        if result != 0, errno != ENOENT { return }
    }
}

struct ResourcePayloadStagingStore: Sendable {
    let hooks: ResourcePayloadFileSystemHooks
    let operationIDFactory: @Sendable () -> UUID

    init(hooks: ResourcePayloadFileSystemHooks = .production,
         operationIDFactory: @escaping @Sendable () -> UUID = { UUID() }) {
        self.hooks = hooks
        self.operationIDFactory = operationIDFactory
    }

    /// Internal only: synthetic staging tests exercise the same component gate used by all
    /// descriptor-relative operations. It is not exposed outside this module.
    static func validatePathComponentForTesting(_ value: String) throws {
        try ResourcePayloadStagingPOSIX.requireSingleComponent(value)
    }

    func prepare(plan: ResourcePayloadDownloadPlan) throws -> ResourcePayloadStagingOperation {
        let rootURL = plan.stagingRoot.standardizedFileURL
        guard rootURL.isFileURL, rootURL.baseURL == nil, rootURL.path.hasPrefix("/") else {
            throw ResourcePayloadDownloadError.unsafePath
        }
        let required = plan.maximumBytes.addingReportingOverflow(plan.policy.diskSafetyMargin)
        guard !required.overflow else { throw ResourcePayloadDownloadError.insufficientDiskSpace }

        let root = try openRoot(rootURL)
        do {
            let measurement: ResourcePayloadCapacityMeasurement
            do {
                measurement = try hooks.capacityMeasurement(rootURL)
            } catch {
                throw ResourcePayloadDownloadError.insufficientDiskSpace
            }
            guard let effectiveCapacity =
                    ResourcePayloadCapacityAdmission.effectiveCapacity(for: measurement),
                  effectiveCapacity >= required.partialValue else {
                throw ResourcePayloadDownloadError.insufficientDiskSpace
            }
            let operationID = operationIDFactory()
            let canonicalID = operationID.uuidString.lowercased()
            guard UUID(uuidString: canonicalID)?.uuidString.lowercased() == canonicalID else {
                throw ResourcePayloadDownloadError.invalidPathComponent
            }
            let operationComponent = ".partial-\(canonicalID)"
            let verifiedComponent = "verified-\(canonicalID)"
            try ResourcePayloadStagingPOSIX.requireSingleComponent(operationComponent)
            try ResourcePayloadStagingPOSIX.requireSingleComponent(verifiedComponent)
            let finalComponent = plan.installationIdentity.sourceComponent
            let partialComponent = finalComponent + ".part"
            let sidecarComponent = OpenResourceInstallationIdentity.sidecarComponent
            let sidecarData = try OpenResourceInstallationSidecar(identity: plan.installationIdentity).encodedData()
            try ResourcePayloadStagingPOSIX.requireSingleComponent(partialComponent)
            try ResourcePayloadStagingPOSIX.requireSingleComponent(finalComponent)
            try ResourcePayloadStagingPOSIX.requireSingleComponent(sidecarComponent)

            let rootFD = try root.withDescriptor { $0 }
            let mkdirResult = operationComponent.withCString { Darwin.mkdirat(rootFD, $0, 0o700) }
            guard mkdirResult == 0 else {
                throw ResourcePayloadStagingPOSIX.error(
                    missing: .downloadDestinationMissing
                )
            }
            var operationDirectory: OwnedFileDescriptor?
            var payload: OwnedFileDescriptor?
            var sidecar: OwnedFileDescriptor?
            do {
                let operationRaw = operationComponent.withCString {
                    Darwin.openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard operationRaw >= 0 else {
                    throw ResourcePayloadStagingPOSIX.error(
                        missing: .downloadDestinationMissing
                    )
                }
                operationDirectory = OwnedFileDescriptor(operationRaw, closeAction: hooks.close)
                let operationMetadata = try operationDirectory!.withDescriptor {
                    try ResourcePayloadStagingPOSIX.metadata(for: $0)
                }
                try ResourcePayloadStagingPOSIX.validateDirectory(operationMetadata)
                let rootEntry = try ResourcePayloadStagingPOSIX.entryMetadata(
                    parent: rootFD, component: operationComponent
                )
                guard ResourcePayloadStagingPOSIX.identitiesMatch(operationMetadata, rootEntry) else {
                    throw ResourcePayloadDownloadError.identityChanged
                }

                let payloadRaw = try operationDirectory!.withDescriptor { operationFD in
                    partialComponent.withCString {
                        Darwin.openat(operationFD, $0,
                                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                     mode_t(0o600))
                    }
                }
                guard payloadRaw >= 0 else {
                    throw ResourcePayloadStagingPOSIX.error(
                        missing: .downloadDestinationMissing
                    )
                }
                payload = OwnedFileDescriptor(payloadRaw, closeAction: hooks.close)
                guard Darwin.fchmod(payloadRaw, mode_t(0o600)) == 0 else {
                    throw ResourcePayloadStagingPOSIX.error()
                }
                let payloadMetadata = try payload!.withDescriptor {
                    try ResourcePayloadStagingPOSIX.metadata(for: $0)
                }
                try ResourcePayloadStagingPOSIX.validatePayloadFile(payloadMetadata, expectedSize: 0)

                let sidecarRaw = try operationDirectory!.withDescriptor { operationFD in
                    sidecarComponent.withCString {
                        Darwin.openat(operationFD, $0,
                                     O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                     mode_t(0o600))
                    }
                }
                guard sidecarRaw >= 0 else {
                    throw ResourcePayloadStagingPOSIX.error(
                        missing: .downloadDestinationMissing
                    )
                }
                sidecar = OwnedFileDescriptor(sidecarRaw, closeAction: hooks.close)
                guard Darwin.fchmod(sidecarRaw, mode_t(0o600)) == 0 else {
                    throw ResourcePayloadStagingPOSIX.error()
                }
                // Hooks model streamed payload I/O only.  The immutable receipt is written once
                // with the production checked-write primitive before streaming starts, so legacy
                // payload write-failure tests retain their intended boundary.
                try sidecar!.withDescriptor { try ResourcePayloadFileSystemHooks.production.writeAll($0, sidecarData) }
                let sidecarMetadata = try sidecar!.withDescriptor { try ResourcePayloadStagingPOSIX.metadata(for: $0) }
                try ResourcePayloadStagingPOSIX.validatePayloadFile(sidecarMetadata,
                                                                    expectedSize: Int64(sidecarData.count))

                return ResourcePayloadStagingOperation(
                    operationID: operationID,
                    rootURL: rootURL,
                    verifiedFile: rootURL.appendingPathComponent(verifiedComponent, isDirectory: true)
                        .appendingPathComponent(finalComponent, isDirectory: false),
                    operationComponent: operationComponent,
                    verifiedComponent: verifiedComponent,
                    partialComponent: partialComponent,
                    finalComponent: finalComponent,
                    sidecarComponent: sidecarComponent,
                    sidecar: sidecar!,
                    installationIdentity: plan.installationIdentity,
                    rootDirectory: root,
                    operationDirectory: operationDirectory!,
                    payload: payload!,
                    hooks: hooks
                )
            } catch {
                if let sidecar { try? sidecar.close() }
                if let payload { try? payload.close() }
                if let operationDirectory {
                    try? operationDirectory.close()
                    ResourcePayloadStagingPOSIX.unlinkKnown(parent: rootFD,
                                                            component: operationComponent,
                                                            directory: true)
                }
                throw error
            }
        } catch {
            try? root.close()
            throw error
        }
    }

    private func openRoot(_ rootURL: URL) throws -> OwnedFileDescriptor {
        var existing = stat()
        if lstat(rootURL.path, &existing) == 0,
           (existing.st_mode & mode_t(S_IFMT)) != mode_t(S_IFDIR) {
            if (existing.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                throw ResourcePayloadDownloadError.unsafePath
            }
            throw ResourcePayloadDownloadError.unexpectedFileType
        }
        let result = rootURL.path.withCString { Darwin.mkdir($0, 0o700) }
        if result != 0, errno != EEXIST {
            throw ResourcePayloadStagingPOSIX.error(
                missing: .stagingDirectoryMissing
            )
        }
        let descriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ResourcePayloadStagingPOSIX.error(
                missing: .stagingDirectoryMissing
            )
        }
        let root = OwnedFileDescriptor(descriptor, closeAction: hooks.close)
        do {
            try ResourcePayloadStagingPOSIX.validateDirectory(
                root.withDescriptor { try ResourcePayloadStagingPOSIX.metadata(for: $0) }
            )
            return root
        } catch {
            try? root.close()
            throw error
        }
    }
}

/// This object is intentionally confined to the downloader's already-serialized delegate
/// lifecycle. It is not Sendable and never escapes to the UI, Catalog, or another actor.
final class ResourcePayloadStagingOperation {
    private enum State {
        case prepared, streaming, verified, publishedButDurabilityUnconfirmed,
             published, cancelled, failed, closed
    }

    let operationID: UUID
    let verifiedFile: URL
    let stagingRootURL: URL
    let verifiedDirectoryComponent: String
    let publishedPayloadComponent: String
    let publishedSidecarComponent: String
    let publishedInstallationIdentity: OpenResourceInstallationIdentity
    private let operationComponent: String
    private let verifiedComponent: String
    private let partialComponent: String
    private let finalComponent: String
    private let sidecarComponent: String
    private let rootDirectory: OwnedFileDescriptor
    private let operationDirectory: OwnedFileDescriptor
    private let payload: OwnedFileDescriptor
    private let sidecar: OwnedFileDescriptor
    private let installationIdentity: OpenResourceInstallationIdentity
    private let hooks: ResourcePayloadFileSystemHooks
    private var state: State = .prepared
    private var hasher = SHA256()
    private var writtenBytes: UInt64 = 0
    private(set) var publishedFileIdentity: PayloadFileIdentity?
    private(set) var publishedDirectoryIdentity: PayloadFileIdentity?

    fileprivate init(operationID: UUID,
         rootURL: URL,
         verifiedFile: URL,
         operationComponent: String,
         verifiedComponent: String,
         partialComponent: String,
         finalComponent: String,
         sidecarComponent: String,
         sidecar: OwnedFileDescriptor,
         installationIdentity: OpenResourceInstallationIdentity,
         rootDirectory: OwnedFileDescriptor,
         operationDirectory: OwnedFileDescriptor,
         payload: OwnedFileDescriptor,
         hooks: ResourcePayloadFileSystemHooks) {
        self.operationID = operationID
        self.verifiedFile = verifiedFile
        stagingRootURL = rootURL
        verifiedDirectoryComponent = verifiedComponent
        publishedPayloadComponent = finalComponent
        publishedSidecarComponent = sidecarComponent
        publishedInstallationIdentity = installationIdentity
        self.operationComponent = operationComponent
        self.verifiedComponent = verifiedComponent
        self.partialComponent = partialComponent
        self.finalComponent = finalComponent
        self.sidecarComponent = sidecarComponent
        self.rootDirectory = rootDirectory
        self.operationDirectory = operationDirectory
        self.payload = payload
        self.sidecar = sidecar
        self.installationIdentity = installationIdentity
        self.hooks = hooks
        _ = rootURL // Retain the initializer's explicit absolute-boundary acknowledgement only.
    }

    deinit { closeDescriptors() }

    var receivedBytes: UInt64 { writtenBytes }

    func append(_ data: Data, maximumBytes: UInt64, expectedBytes: UInt64) throws -> UInt64 {
        guard state == .prepared || state == .streaming else {
            throw ResourcePayloadDownloadError.writeFailure
        }
        guard !data.isEmpty else { return writtenBytes }
        let next = writtenBytes.addingReportingOverflow(UInt64(data.count))
        guard !next.overflow, next.partialValue <= maximumBytes else {
            state = .failed
            throw ResourcePayloadDownloadError.payloadTooLarge
        }
        guard next.partialValue <= expectedBytes else {
            state = .failed
            throw ResourcePayloadDownloadError.contentLengthMismatch
        }
        do {
            try payload.withDescriptor { try hooks.writeAll($0, data) }
            hasher.update(data: data)
            writtenBytes = next.partialValue
            state = .streaming
            return writtenBytes
        } catch let error as ResourcePayloadDownloadError {
            state = .failed
            throw error
        } catch {
            state = .failed
            throw ResourcePayloadDownloadError.writeFailure
        }
    }

    func finish(expectedBytes: UInt64, expectedSHA256: String) throws -> (bytes: UInt64, digest: String) {
        guard state == .prepared || state == .streaming else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
        do {
            guard writtenBytes == expectedBytes else {
                throw ResourcePayloadDownloadError.contentLengthMismatch
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSHA256 else { throw ResourcePayloadDownloadError.hashMismatch }
            state = .verified

            let payloadMetadata = try payload.withDescriptor { try ResourcePayloadStagingPOSIX.metadata(for: $0) }
            try ResourcePayloadStagingPOSIX.validatePayloadFile(payloadMetadata,
                                                                expectedSize: Int64(expectedBytes))
            try payload.withDescriptor { try hooks.synchronize($0) }
            try sidecar.withDescriptor { try ResourcePayloadFileSystemHooks.production.synchronize($0) }
            let operationFD = try operationDirectory.withDescriptor { $0 }
            let partialEntry = try ResourcePayloadStagingPOSIX.entryMetadata(
                parent: operationFD, component: partialComponent
            )
            guard ResourcePayloadStagingPOSIX.identitiesMatch(payloadMetadata, partialEntry) else {
                throw ResourcePayloadDownloadError.identityChanged
            }
            try ResourcePayloadStagingPOSIX.validatePayloadFile(partialEntry,
                                                                expectedSize: Int64(expectedBytes))
            let sidecarMetadata = try sidecar.withDescriptor { try ResourcePayloadStagingPOSIX.metadata(for: $0) }
            let sidecarEntry = try ResourcePayloadStagingPOSIX.entryMetadata(parent: operationFD,
                                                                              component: sidecarComponent)
            guard ResourcePayloadStagingPOSIX.identitiesMatch(sidecarMetadata, sidecarEntry) else {
                throw ResourcePayloadDownloadError.identityChanged
            }
            try ResourcePayloadStagingPOSIX.validatePayloadFile(sidecarEntry,
                                                                expectedSize: Int64(sidecarMetadata.st_size))
            let sidecarData = try sidecar.withDescriptor {
                try ResourcePayloadStagingPOSIX.readBoundedExactly($0, maximum: 64 * 1024)
            }
            do {
                _ = try OpenResourceInstallationSidecar.decode(sidecarData)
                    .validated(expected: installationIdentity)
            } catch {
                throw ResourcePayloadDownloadError.sidecarIdentityMismatch
            }
            try ResourcePayloadStagingPOSIX.entryIsAbsent(parent: operationFD, component: finalComponent)
            try hooks.renameNoReplaceAt(operationFD, partialComponent, operationFD, finalComponent)
            let finalEntry = try ResourcePayloadStagingPOSIX.entryMetadata(parent: operationFD,
                                                                            component: finalComponent)
            guard ResourcePayloadStagingPOSIX.identitiesMatch(payloadMetadata, finalEntry) else {
                throw ResourcePayloadDownloadError.identityChanged
            }
            try ResourcePayloadStagingPOSIX.validatePayloadFile(finalEntry,
                                                                expectedSize: Int64(expectedBytes))
            try operationDirectory.withDescriptor { try hooks.synchronize($0) }

            let operationMetadata = try operationDirectory.withDescriptor {
                try ResourcePayloadStagingPOSIX.metadata(for: $0)
            }
            try ResourcePayloadStagingPOSIX.validateDirectory(operationMetadata)
            let rootFD = try rootDirectory.withDescriptor { $0 }
            let operationEntry = try ResourcePayloadStagingPOSIX.entryMetadata(
                parent: rootFD, component: operationComponent
            )
            guard ResourcePayloadStagingPOSIX.identitiesMatch(operationMetadata, operationEntry) else {
                throw ResourcePayloadDownloadError.identityChanged
            }
            try ResourcePayloadStagingPOSIX.entryIsAbsent(parent: rootFD, component: verifiedComponent)
            try hooks.renameNoReplaceAt(rootFD, operationComponent, rootFD, verifiedComponent)
            let verifiedEntry = try ResourcePayloadStagingPOSIX.entryMetadata(parent: rootFD,
                                                                               component: verifiedComponent)
            guard ResourcePayloadStagingPOSIX.identitiesMatch(operationMetadata, verifiedEntry) else {
                throw ResourcePayloadDownloadError.identityChanged
            }
            try ResourcePayloadStagingPOSIX.validateDirectory(verifiedEntry)
            publishedFileIdentity = PayloadFileIdentity(payloadMetadata)
            publishedDirectoryIdentity = PayloadFileIdentity(operationMetadata)
            state = .publishedButDurabilityUnconfirmed
            try rootDirectory.withDescriptor { try hooks.synchronize($0) }

            state = .published
            closeDescriptors()
            return (writtenBytes, digest)
        } catch let error as ResourcePayloadDownloadError {
            if state != .publishedButDurabilityUnconfirmed { state = .failed }
            throw error
        } catch {
            if state != .publishedButDurabilityUnconfirmed { state = .failed }
            throw ResourcePayloadDownloadError.ioFailure
        }
    }

    func cleanup() {
        if state == .published || state == .publishedButDurabilityUnconfirmed {
            closeDescriptors()
            return
        }
        let rootFD = try? rootDirectory.withDescriptor { $0 }
        let operationFD = try? operationDirectory.withDescriptor { $0 }
        if let operationFD {
            removeOwnedPayload(parent: operationFD, component: partialComponent)
            removeOwnedPayload(parent: operationFD, component: finalComponent)
            removeOwnedSidecar(parent: operationFD)
        }
        if let rootFD,
           let operationMetadata = try? operationDirectory.withDescriptor({ try ResourcePayloadStagingPOSIX.metadata(for: $0) }),
           let operationEntry = try? ResourcePayloadStagingPOSIX.entryMetadata(parent: rootFD,
                                                                                 component: operationComponent),
           ResourcePayloadStagingPOSIX.identitiesMatch(operationMetadata, operationEntry) {
            ResourcePayloadStagingPOSIX.unlinkKnown(parent: rootFD,
                                                    component: operationComponent,
                                                    directory: true)
        }
        closeDescriptors()
        if state != .failed { state = .cancelled }
    }

    private func closeDescriptors() {
        try? payload.close()
        try? sidecar.close()
        try? operationDirectory.close()
        try? rootDirectory.close()
        if state != .published && state != .publishedButDurabilityUnconfirmed &&
            state != .failed && state != .cancelled {
            state = .closed
        }
    }

    private func removeOwnedPayload(parent: Int32, component: String) {
        guard let payloadMetadata = try? payload.withDescriptor({
            try ResourcePayloadStagingPOSIX.metadata(for: $0)
        }),
        let entry = try? ResourcePayloadStagingPOSIX.entryMetadata(parent: parent, component: component),
        ResourcePayloadStagingPOSIX.identitiesMatch(payloadMetadata, entry) else {
            return
        }
        ResourcePayloadStagingPOSIX.unlinkKnown(parent: parent, component: component)
    }

    private func removeOwnedSidecar(parent: Int32) {
        guard let metadata = try? sidecar.withDescriptor({ try ResourcePayloadStagingPOSIX.metadata(for: $0) }),
              let entry = try? ResourcePayloadStagingPOSIX.entryMetadata(parent: parent, component: sidecarComponent),
              ResourcePayloadStagingPOSIX.identitiesMatch(metadata, entry) else { return }
        ResourcePayloadStagingPOSIX.unlinkKnown(parent: parent, component: sidecarComponent)
    }
}
