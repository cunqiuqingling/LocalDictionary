import Darwin
import Foundation

enum VerifiedManifestStateStoreError: LocalizedError, Equatable, Sendable {
    case corruptState
    case inconsistentState
    case unsafeDirectory
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .corruptState: return "已验证资源清单状态损坏，已安全停止以防止版本回滚。"
        case .inconsistentState: return "已验证资源清单状态不一致，已安全停止。"
        case .unsafeDirectory: return "资源清单状态目录未通过安全检查。"
        case .writeFailed: return "无法安全保存资源清单验证状态。"
        }
    }
}

enum VerifiedManifestStateDestination: Sendable {
    case backup
    case primary
}

struct VerifiedManifestStateStoreHooks: Sendable {
    let beforeReplace: @Sendable (VerifiedManifestStateDestination) throws -> Void

    static let live = VerifiedManifestStateStoreHooks(beforeReplace: { _ in })
}

actor VerifiedManifestStateStore {
    static let stateFileName = "verified-manifest-state-v1.json"
    static let backupFileName = "verified-manifest-state-v1.backup.json"

    let directoryURL: URL
    let stateURL: URL
    let backupURL: URL

    private let hooks: VerifiedManifestStateStoreHooks
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL = VerifiedManifestStateStore.defaultDirectoryURL(),
         hooks: VerifiedManifestStateStoreHooks = .live) {
        self.directoryURL = directoryURL
        stateURL = directoryURL.appendingPathComponent(Self.stateFileName)
        backupURL = directoryURL.appendingPathComponent(Self.backupFileName)
        self.hooks = hooks

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    nonisolated static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(
            "LocalDictionary/ResourceCenter/ManifestState", isDirectory: true
        )
    }

    func load() throws -> VerifiedManifestState? {
        let primary = decode(at: stateURL)
        let backup = decode(at: backupURL)
        switch (primary, backup) {
        case (.missing, .missing):
            return nil
        case (.corrupt, .corrupt), (.corrupt, .missing), (.missing, .corrupt):
            throw VerifiedManifestStateStoreError.corruptState
        case (.valid(let state), .missing), (.valid(let state), .corrupt),
             (.missing, .valid(let state)), (.corrupt, .valid(let state)):
            return state
        case (.valid(let first), .valid(let second)):
            if first.highestManifestVersion == second.highestManifestVersion {
                guard first.manifestSHA256 == second.manifestSHA256,
                      first.verifiedKeyID == second.verifiedKeyID else {
                    throw VerifiedManifestStateStoreError.inconsistentState
                }
                return first.verifiedAt >= second.verifiedAt ? first : second
            }
            return first.highestManifestVersion > second.highestManifestVersion ? first : second
        }
    }

    @discardableResult
    func commitVerifiedState(_ prepared: PreparedManifestVerification) throws
        -> VerifiedManifestState {
        let candidate = try prepared.stateCandidate.validated()
        let prior = try load()
        try ResourceManifestVerifier.validateRollback(candidate: candidate, priorState: prior)
        try save(candidate)
        guard let reloaded = try load(),
              reloaded.highestManifestVersion == candidate.highestManifestVersion,
              reloaded.manifestSHA256 == candidate.manifestSHA256,
              reloaded.verifiedKeyID == candidate.verifiedKeyID else {
            throw VerifiedManifestStateStoreError.writeFailed
        }
        return reloaded
    }

    private enum DecodedState {
        case missing
        case valid(VerifiedManifestState)
        case corrupt
    }

    private func decode(at url: URL) -> DecodedState {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(VerifiedManifestState.self, from: data),
              let validated = try? state.validated() else { return .corrupt }
        return .valid(validated)
    }

    private func save(_ state: VerifiedManifestState) throws {
        let fileManager = FileManager()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let values = try directoryURL.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw VerifiedManifestStateStoreError.unsafeDirectory
            }
            guard Darwin.chmod(directoryURL.path, S_IRWXU) == 0 else {
                throw VerifiedManifestStateStoreError.unsafeDirectory
            }
            let data = try encoder.encode(state)
            let operationID = UUID().uuidString.lowercased()
            let backupTemporaryURL = directoryURL.appendingPathComponent(
                ".\(Self.backupFileName).\(operationID).tmp"
            )
            let stateTemporaryURL = directoryURL.appendingPathComponent(
                ".\(Self.stateFileName).\(operationID).tmp"
            )
            defer {
                try? fileManager.removeItem(at: backupTemporaryURL)
                try? fileManager.removeItem(at: stateTemporaryURL)
            }
            try writeAndSynchronize(data, to: backupTemporaryURL)
            try writeAndSynchronize(data, to: stateTemporaryURL)
            try hooks.beforeReplace(.backup)
            try replaceAtomically(source: backupTemporaryURL, destination: backupURL)
            try synchronizeDirectory()
            try hooks.beforeReplace(.primary)
            try replaceAtomically(source: stateTemporaryURL, destination: stateURL)
            try synchronizeDirectory()
        } catch let error as VerifiedManifestStateStoreError {
            throw error
        } catch {
            throw VerifiedManifestStateStoreError.writeFailed
        }
    }

    private func writeAndSynchronize(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL,
                                     S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VerifiedManifestStateStoreError.writeFailed }
        defer { Darwin.close(descriptor) }
        var written = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while written < data.count {
                let count = Darwin.write(descriptor,
                                         baseAddress.advanced(by: written),
                                         data.count - written)
                guard count > 0 else { throw VerifiedManifestStateStoreError.writeFailed }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw VerifiedManifestStateStoreError.writeFailed
        }
    }

    private func replaceAtomically(source: URL, destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw VerifiedManifestStateStoreError.writeFailed }
    }

    private func synchronizeDirectory() throws {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw VerifiedManifestStateStoreError.writeFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw VerifiedManifestStateStoreError.writeFailed
        }
    }
}
