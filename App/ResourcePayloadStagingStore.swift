import Darwin
import Foundation

struct ResourcePayloadFileSystemHooks: Sendable {
    let availableCapacity: @Sendable (URL) throws -> UInt64
    let writeAll: @Sendable (Int32, Data) throws -> Void
    let synchronize: @Sendable (Int32) throws -> Void
    let close: @Sendable (Int32) throws -> Void
    let rename: @Sendable (String, String) throws -> Void

    static let production = ResourcePayloadFileSystemHooks(
        availableCapacity: { root in
            let values = try root.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            guard let capacity = values.volumeAvailableCapacityForImportantUsage,
                  capacity >= 0 else {
                throw ResourcePayloadDownloadError.stagingFailure
            }
            return UInt64(capacity)
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
                throw ResourcePayloadDownloadError.stagingFailure
            }
        },
        close: { descriptor in
            guard Darwin.close(descriptor) == 0 else {
                throw ResourcePayloadDownloadError.stagingFailure
            }
        },
        rename: { source, destination in
            guard Darwin.rename(source, destination) == 0 else {
                throw ResourcePayloadDownloadError.stagingFailure
            }
        }
    )
}

struct ResourcePayloadStagingStore: Sendable {
    let hooks: ResourcePayloadFileSystemHooks
    let operationIDFactory: @Sendable () -> UUID

    init(hooks: ResourcePayloadFileSystemHooks = .production,
         operationIDFactory: @escaping @Sendable () -> UUID = { UUID() }) {
        self.hooks = hooks
        self.operationIDFactory = operationIDFactory
    }

    func prepare(plan: ResourcePayloadDownloadPlan) throws -> ResourcePayloadStagingOperation {
        let root = plan.stagingRoot.standardizedFileURL
        guard root.isFileURL,
              root.baseURL == nil,
              root.path.hasPrefix("/"),
              ResourcePayloadDownloadPlanBuilder.isSafeMDXFileName(plan.signedFileName) else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
        try Self.createOrValidateRoot(root)

        let required = plan.maximumBytes.addingReportingOverflow(
            plan.policy.diskSafetyMargin
        )
        guard !required.overflow else {
            throw ResourcePayloadDownloadError.insufficientDiskSpace
        }
        guard try hooks.availableCapacity(root) >= required.partialValue else {
            throw ResourcePayloadDownloadError.insufficientDiskSpace
        }

        let operationID = operationIDFactory()
        let partialDirectory = root.appendingPathComponent(
            ".partial-\(operationID.uuidString)",
            isDirectory: true
        )
        let verifiedDirectory = root.appendingPathComponent(
            "verified-\(operationID.uuidString)",
            isDirectory: true
        )
        guard partialDirectory.deletingLastPathComponent() == root,
              verifiedDirectory.deletingLastPathComponent() == root,
              !Self.pathExists(partialDirectory.path),
              !Self.pathExists(verifiedDirectory.path) else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
        guard Darwin.mkdir(partialDirectory.path, 0o700) == 0 else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
        do {
            try Self.validateOperationDirectory(partialDirectory, inside: root)
        } catch {
            _ = Darwin.rmdir(partialDirectory.path)
            throw ResourcePayloadDownloadError.stagingFailure
        }

        let partialFile = partialDirectory.appendingPathComponent(
            plan.signedFileName + ".part",
            isDirectory: false
        )
        let publishedFileInPartial = partialDirectory.appendingPathComponent(
            plan.signedFileName,
            isDirectory: false
        )
        let verifiedFile = verifiedDirectory.appendingPathComponent(
            plan.signedFileName,
            isDirectory: false
        )
        let descriptor = Darwin.open(
            partialFile.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            _ = Darwin.rmdir(partialDirectory.path)
            throw ResourcePayloadDownloadError.stagingFailure
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            _ = Darwin.close(descriptor)
            _ = Darwin.unlink(partialFile.path)
            _ = Darwin.rmdir(partialDirectory.path)
            throw ResourcePayloadDownloadError.stagingFailure
        }

        return ResourcePayloadStagingOperation(
            operationID: operationID,
            root: root,
            partialDirectory: partialDirectory,
            verifiedDirectory: verifiedDirectory,
            partialFile: partialFile,
            publishedFileInPartial: publishedFileInPartial,
            verifiedFile: verifiedFile,
            descriptor: descriptor,
            hooks: hooks
        )
    }

    private static func createOrValidateRoot(_ root: URL) throws {
        if !pathExists(root.path) {
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw ResourcePayloadDownloadError.stagingFailure
            }
        }
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              (metadata.st_mode & S_IFMT) != S_IFLNK,
              Darwin.chmod(root.path, mode_t(0o700)) == 0 else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
    }

    private static func validateOperationDirectory(_ directory: URL,
                                                   inside root: URL) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              (metadata.st_mode & S_IFMT) != S_IFLNK,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() ==
                root.resolvingSymlinksInPath(),
              Darwin.chmod(directory.path, mode_t(0o700)) == 0 else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
    }

    private static func pathExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }
}

/// A single-operation file capability. It never escapes the payload downloader. URLSession
/// delegate callbacks are serialized, and every close/publish/cleanup call is made while the
/// owning delegate's lifecycle lock is held.
final class ResourcePayloadStagingOperation {
    let operationID: UUID
    let verifiedFile: URL
    private let root: URL
    private let partialDirectory: URL
    private let verifiedDirectory: URL
    private let partialFile: URL
    private let publishedFileInPartial: URL
    private var descriptor: Int32
    private var isOpen = true
    private var isPublished = false
    private let hooks: ResourcePayloadFileSystemHooks

    init(operationID: UUID,
         root: URL,
         partialDirectory: URL,
         verifiedDirectory: URL,
         partialFile: URL,
         publishedFileInPartial: URL,
         verifiedFile: URL,
         descriptor: Int32,
         hooks: ResourcePayloadFileSystemHooks) {
        self.operationID = operationID
        self.root = root
        self.partialDirectory = partialDirectory
        self.verifiedDirectory = verifiedDirectory
        self.partialFile = partialFile
        self.publishedFileInPartial = publishedFileInPartial
        self.verifiedFile = verifiedFile
        self.descriptor = descriptor
        self.hooks = hooks
    }

    func write(_ data: Data) throws {
        guard isOpen, !isPublished else {
            throw ResourcePayloadDownloadError.writeFailure
        }
        do {
            try hooks.writeAll(descriptor, data)
        } catch let error as ResourcePayloadDownloadError {
            throw error
        } catch {
            throw ResourcePayloadDownloadError.writeFailure
        }
    }

    func publish() throws {
        guard isOpen, !isPublished else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
        do {
            try hooks.synchronize(descriptor)
            try closeFile()
            try hooks.rename(partialFile.path, publishedFileInPartial.path)
            try synchronizeDirectory(partialDirectory)
            try hooks.rename(partialDirectory.path, verifiedDirectory.path)
            try synchronizeDirectory(root)
            isPublished = true
        } catch let error as ResourcePayloadDownloadError {
            throw error
        } catch {
            throw ResourcePayloadDownloadError.stagingFailure
        }
    }

    func cleanup() {
        if isOpen {
            _ = try? closeFile()
        }
        guard !isPublished else { return }
        _ = Darwin.unlink(partialFile.path)
        _ = Darwin.unlink(publishedFileInPartial.path)
        _ = Darwin.rmdir(partialDirectory.path)
    }

    private func closeFile() throws {
        guard isOpen else { return }
        let current = descriptor
        isOpen = false
        descriptor = -1
        try hooks.close(current)
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw ResourcePayloadDownloadError.stagingFailure
        }
        do {
            try hooks.synchronize(directoryDescriptor)
            try hooks.close(directoryDescriptor)
        } catch {
            _ = Darwin.close(directoryDescriptor)
            throw error
        }
    }
}
