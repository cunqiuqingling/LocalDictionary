import Foundation

enum MDictCompressionStatus: String, Sendable {
    case compressed
    case uncompressed
    case unknown

    var displayName: String {
        switch self {
        case .compressed: return "是"
        case .uncompressed: return "否"
        case .unknown: return "未能从必要摘要确认"
        }
    }
}

struct MDictHeaderSummary: Equatable, Sendable {
    var title: String?
    var engineVersion: String
    var encoding: String
    var compression: MDictCompressionStatus
    var isEncrypted: Bool
}

struct DictionaryMDDCandidate: Identifiable, Equatable, Sendable {
    var url: URL
    var fileName: String
    var fileSize: UInt64

    var id: String { url.standardizedFileURL.path }
}

struct DictionaryImportPreview: Equatable, Sendable {
    static let defaultFormatterIdentifier = DictionaryFormatterIdentifier.genericMDictV1

    var sourceMDXURL: URL
    var displayName: String
    var originalFileName: String
    var mdxFileSize: UInt64
    var sourceModifiedAt: Date?
    var header: MDictHeaderSummary
    var mdxSHA256: String
    var mddCandidates: [DictionaryMDDCandidate]
    var automaticallySelectedMDDIDs: Set<String>

    var queryLevel: DictionaryQueryLevel { .normal }
    var enabled: Bool { true }
    var formatterIdentifier: String { Self.defaultFormatterIdentifier }
    var state: DictionaryState { .pendingIndex }

    func estimatedDiskBytes(selectedMDDIDs: Set<String>) -> UInt64 {
        let selectedSize = mddCandidates
            .filter { selectedMDDIDs.contains($0.id) }
            .reduce(UInt64(0)) { $0 &+ $1.fileSize }
        let contentSize = mdxFileSize &+ selectedSize
        let overhead = max(contentSize / 20, 4 * 1024 * 1024)
        return contentSize &+ overhead
    }
}

struct DictionaryImportSelection: Equatable, Sendable {
    var preview: DictionaryImportPreview
    var selectedMDDIDs: Set<String>

    var selectedMDDCandidates: [DictionaryMDDCandidate] {
        preview.mddCandidates.filter { selectedMDDIDs.contains($0.id) }
    }
}

struct DictionaryImportPlanFile: Sendable {
    let sourceURL: URL
    let destinationFileName: String
    let expectedSize: UInt64
    let expectedSHA256: String?
}

struct DictionaryImportPlanItem: Sendable {
    let descriptor: DictionaryDescriptor
    let files: [DictionaryImportPlanFile]
}

struct DictionaryImportPlan: Sendable {
    let operationID: String
    let totalCopyBytes: UInt64
    let requiredDiskBytes: UInt64
    let items: [DictionaryImportPlanItem]
}

struct DictionaryImportPublishedItem: Sendable {
    let dictionaryID: String
    let directoryURL: URL
}

struct DictionaryImportExecutionResult: Sendable {
    let descriptors: [DictionaryDescriptor]
    let publishedItems: [DictionaryImportPublishedItem]
}

enum DictionaryImportWorkerOutcome: Sendable {
    case success(DictionaryImportExecutionResult)
    case failure(DictionaryImportError)
}

enum DictionaryImportInspectionOutcome: Sendable {
    case success([DictionaryImportPreview])
    case failure(DictionaryImportError)
}

enum DictionaryImportError: LocalizedError, Sendable {
    case invalidSelection
    case noMDXFiles
    case unreadableFile(String)
    case invalidMDX(String)
    case headerTooLarge
    case sourceMissing(String)
    case insufficientDiskSpace(required: UInt64, available: UInt64)
    case duplicate(existingDictionaryID: String, displayName: String)
    case cancelled
    case sourceChanged(String)
    case copyVerificationFailed(String)
    case publicationFailed
    case importAlreadyInProgress
    case inspectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "请选择一个 MDX 文件或包含 MDX 文件的文件夹。"
        case .noMDXFiles:
            return "所选文件夹中没有可导入的 MDX 文件。"
        case .unreadableFile(let name):
            return "无法读取文件：\(name)"
        case .invalidMDX(let reason):
            return "MDX 文件头无效：\(reason)"
        case .headerTooLarge:
            return "MDX 文件头异常过大，已停止检查。"
        case .sourceMissing(let name):
            return "源文件已不存在：\(name)"
        case .insufficientDiskSpace(let required, let available):
            return "可用磁盘空间不足（需要 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: required), countStyle: .file))，可用 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: available), countStyle: .file))）。"
        case .duplicate(_, let displayName):
            return "该词典可能已导入：\(displayName)"
        case .cancelled:
            return "导入已取消。"
        case .sourceChanged(let name):
            return "复制期间源文件发生变化：\(name)"
        case .copyVerificationFailed(let name):
            return "复制完成后校验失败：\(name)"
        case .publicationFailed:
            return "无法发布已托管的词典文件。"
        case .importAlreadyInProgress:
            return "已有词典导入正在进行，请稍后再试。"
        case .inspectionFailed(let message):
            return "无法检查词典：\(message)"
        }
    }
}

/// A process-local cancellation flag shared only by the main-actor coordinator
/// and one file worker. Every access to `cancelled` is protected by `lock`.
final class DictionaryImportCancellationToken: @unchecked Sendable {
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
