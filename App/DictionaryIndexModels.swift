import Foundation

enum DictionaryIndexWorkStage: String, Sendable {
    case preparing
    case hashingSource
    case buildingSQLite
    case validatingSQLite
    case publishing
}

struct DictionaryIndexActivity: Equatable, Sendable {
    let dictionaryID: String
    let stage: DictionaryIndexWorkStage
}

struct DictionaryIndexPlan: Sendable {
    let dictionaryID: String
    let publicationID: String
    let managedRootURL: URL
    let sourceRelativePath: String
    let expectedSourceSize: UInt64
    let expectedSourceSHA256: String
    let indexDirectoryURL: URL
    let candidateName: String
    let finalName: String
    let relativeIndexPath: String
    let expectedSchemaVersion: Int
}

struct DictionaryIndexBuildRequest: @unchecked Sendable {
    let candidateIndexURL: URL
    let dictionaryID: String
    let publicationID: String
    let sourceSHA256: String
    let sourceFileSize: UInt64
    let candidateStorage: AnyObject?
}

struct DictionaryIndexBuildProduct: Sendable {
    let reportedEntryCount: UInt64
}

/// A process-local lease over one already-verified managed source object.
/// `storage` keeps the production C++ capability alive; test implementations
/// may leave it nil. The worker never reconstructs a pathname from this lease.
final class DictionaryIndexSourceCapability: @unchecked Sendable {
    let sourceFileSize: UInt64
    let sourceSHA256: String
    let storage: AnyObject?
    private let validation: @Sendable () -> Bool

    init(sourceFileSize: UInt64, sourceSHA256: String,
         storage: AnyObject? = nil,
         validation: @escaping @Sendable () -> Bool) {
        self.sourceFileSize = sourceFileSize
        self.sourceSHA256 = sourceSHA256
        self.storage = storage
        self.validation = validation
    }

    var isValidForPublication: Bool { validation() }
}

typealias DictionaryIndexSourceOpenFunction = @Sendable (
    URL,
    String,
    UInt64,
    String,
    DictionaryIndexCancellationToken
) throws -> DictionaryIndexSourceCapability

typealias DictionaryIndexBuildFunction = @Sendable (
    DictionaryIndexSourceCapability,
    DictionaryIndexBuildRequest,
    DictionaryIndexCancellationToken
) -> DictionaryIndexBuildOutcome

struct DictionaryIndexSealResult: Sendable {
    let entryCount: UInt64
    let indexFileSize: UInt64
    let indexSHA256: String
}

/// Narrow process-local handle. Production closures delegate every identity
/// operation to the Objective-C++ fd capability; synthetic tests may inject a
/// temporary-directory implementation without exposing VFS details to Swift.
final class DictionaryIndexCandidateCapability: @unchecked Sendable {
    let publicationID: String
    let candidateIndexURL: URL
    let finalName: String
    let storage: AnyObject?
    private let sealOperation: @Sendable (UInt64) throws -> DictionaryIndexSealResult
    private let publishOperation: @Sendable () throws -> Void
    private let discardOperation: @Sendable () -> Void
    private let commitOperation: @Sendable () throws -> Void

    init(
        publicationID: String,
        candidateIndexURL: URL,
        finalName: String,
        storage: AnyObject? = nil,
        seal: @escaping @Sendable (UInt64) throws -> DictionaryIndexSealResult,
        publish: @escaping @Sendable () throws -> Void,
        discard: @escaping @Sendable () -> Void,
        commit: @escaping @Sendable () throws -> Void
    ) {
        self.publicationID = publicationID
        self.candidateIndexURL = candidateIndexURL
        self.finalName = finalName
        self.storage = storage
        sealOperation = seal
        publishOperation = publish
        discardOperation = discard
        commitOperation = commit
    }

    func seal(entryCount: UInt64) throws -> DictionaryIndexSealResult {
        try sealOperation(entryCount)
    }
    func publish() throws { try publishOperation() }
    func discard() { discardOperation() }
    func commit() throws { try commitOperation() }
}

typealias DictionaryIndexCandidateFactory = @Sendable (
    DictionaryIndexPlan
) throws -> DictionaryIndexCandidateCapability

enum DictionaryIndexBuildOutcome: Sendable {
    case success(DictionaryIndexBuildProduct)
    case cancelled
    case failure(String)
}

struct DictionaryIndexPreparedResult: Sendable {
    let dictionaryID: String
    let publicationID: String
    let relativeIndexPath: String
    let schemaVersion: Int
    let entryCount: UInt64
    let indexFileSize: UInt64
    let indexSHA256: String
    let sourceFileSize: UInt64
    let sourceSHA256: String
    let sourceRelativePath: String
    let indexedAt: Date
    let sourceCapability: DictionaryIndexSourceCapability
    let candidateCapability: DictionaryIndexCandidateCapability
}

enum DictionaryIndexWorkerOutcome: Sendable {
    case prepared(DictionaryIndexPreparedResult)
    case cancelled
    case failed(DictionaryIndexError)
}

enum DictionaryIndexSourceOpenOutcome: Sendable {
    case ready(DictionaryIndexSourceCapability)
    case cancelled
    case failed(DictionaryIndexError)
}

enum DictionaryIndexStartResult: Equatable, Sendable {
    case started
    case busy
    case unavailable(String)
}

enum DictionaryIndexError: LocalizedError, Equatable, Sendable {
    case sourceMissing
    case sourceUnreadable
    case sourceChanged
    case sourceFingerprintMissing
    case unsafeCatalogPath
    case insufficientDiskSpace(required: UInt64, available: UInt64)
    case builderFailed(String)
    case invalidSQLite
    case integrityCheckFailed
    case schemaMismatch
    case missingEntryCount
    case emptyIndex
    case candidateCreationFailed
    case indexIdentityMismatch
    case publicationFailed
    case catalogWriteFailed

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "托管的 MDX 文件已不存在。"
        case .sourceUnreadable: return "托管的 MDX 文件不可读。"
        case .sourceChanged: return "托管的 MDX 文件与导入时的内容摘要不一致。"
        case .sourceFingerprintMissing: return "Catalog 缺少源 MDX 的内容摘要。"
        case .unsafeCatalogPath: return "Catalog 中的托管路径无效。"
        case .insufficientDiskSpace(let required, let available):
            return "可用磁盘空间不足（需要 \(Self.bytes(required))，可用 \(Self.bytes(available))）。"
        case .builderFailed(let reason): return reason
        case .invalidSQLite: return "生成的索引不是有效的 SQLite 数据库。"
        case .integrityCheckFailed: return "SQLite 完整性检查未通过。"
        case .schemaMismatch: return "SQLite 索引版本与当前应用不兼容。"
        case .missingEntryCount: return "SQLite 索引无法读取词条数量。"
        case .emptyIndex: return "生成的 SQLite 索引为空。"
        case .candidateCreationFailed: return "无法安全创建 SQLite 索引候选文件。"
        case .indexIdentityMismatch: return "SQLite 索引身份验证失败。"
        case .publicationFailed: return "无法安全发布已验证的 SQLite 索引。"
        case .catalogWriteFailed: return "索引已停止，但无法保存 Catalog 状态。"
        }
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

/// A process-local cooperative cancellation flag shared by one main-actor
/// coordinator and one index worker. `cancelled` is protected by `lock` for
/// every read and write; this type owns no other state or responsibility.
final class DictionaryIndexCancellationToken: @unchecked Sendable {
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

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
