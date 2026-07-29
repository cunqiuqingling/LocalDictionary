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
    let managedRootURL: URL
    let sourceRelativePath: String
    let expectedSourceSize: UInt64
    let expectedSourceSHA256: String
    let indexDirectoryURL: URL
    let candidateIndexURL: URL
    let finalIndexURL: URL
    let relativeIndexPath: String
    let expectedSchemaVersion: Int
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
    URL,
    DictionaryIndexCancellationToken
) -> DictionaryIndexBuildOutcome

enum DictionaryIndexBuildOutcome: Sendable {
    case success(DictionaryIndexBuildProduct)
    case cancelled
    case failure(String)
}

struct DictionaryIndexPreparedResult: Sendable {
    let dictionaryID: String
    let candidateIndexURL: URL
    let finalIndexURL: URL
    let relativeIndexPath: String
    let schemaVersion: Int
    let entryCount: UInt64
    let indexFileSize: UInt64
    let sourceFileSize: UInt64
    let sourceSHA256: String
    let indexedAt: Date
    let sourceCapability: DictionaryIndexSourceCapability
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
