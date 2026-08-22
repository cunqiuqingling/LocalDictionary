import Darwin
import Foundation

// Layout-only stand-ins. Production reverse-index behavior is exercised by OfflineLanguageSmoke;
// this target deliberately avoids linking the Objective-C++ dictionary bridge.
enum ReverseIndexBuildStage: String, Equatable, Sendable {
    case notBuilt, queued, readingEntries, writingIndex, optimizing, validating, publishing
    case ready, notApplicable, cancelling, cancelled, failed, stale

    var displayName: String {
        switch self {
        case .notBuilt: return "未建立"
        case .queued: return "等待中"
        case .readingEntries: return "读取词条"
        case .writingIndex: return "写入索引"
        case .optimizing: return "优化"
        case .validating: return "验证"
        case .publishing: return "发布"
        case .ready: return "可用"
        case .notApplicable: return "无需建立"
        case .cancelling: return "正在取消"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        case .stale: return "需重建"
        }
    }
}

enum ReverseIndexCapability: String, Equatable, Sendable {
    case supported, noChineseDefinitions, unsupportedFormatter
    case unsupportedGlossExtraction
    case enumerationUnavailable, unknownNeedsProbe
    case nativeChineseLookup, derivedReady, notApplicable

    var isBuildEligible: Bool { self == .supported }
    var displayName: String {
        switch self {
        case .supported: return "可建立"
        case .nativeChineseLookup: return "中→英查询：内置"
        case .derivedReady: return "中文反向：已随资源建立"
        case .notApplicable: return "中文反向：不适用"
        case .noChineseDefinitions: return "此词典不含可用中文释义"
        case .unsupportedFormatter: return "当前格式尚不支持中文反向索引"
        case .unsupportedGlossExtraction: return "当前词典格式暂不支持中文反向索引"
        case .enumerationUnavailable: return "当前词典无法枚举词条"
        case .unknownNeedsProbe: return "需要检测"
        }
    }

    var diagnosticDetail: String {
        switch self {
        case .unsupportedGlossExtraction:
            return "阶段：glossExtraction\n原因类型：unsupportedGlossStructure"
        case .notApplicable:
            return "此资源用于英语查询，无需额外建立索引。"
        default:
            return "能力判断：\(displayName)。"
        }
    }
}

struct ReverseExtractionStatistics: Equatable, Sendable {
    var totalEntries: UInt64 = 0
    var usableEntries: UInt64 = 0
    var entriesWithChinese: UInt64 = 0
    var skippedMalformed: UInt64 = 0
    var skippedNoChinese: UInt64 = 0
}

enum ReverseIndexError: Error, Equatable { case cancelled }

struct ReverseIndexDescriptor: Equatable, Sendable {}

enum ReverseIndexIdentity {
    static let schemaVersion = 1
    static let openResourceSchemaVersion = 1
}

enum ReverseIndexThermalPacing {
    static func delayMicroseconds(for state: ProcessInfo.ThermalState) -> useconds_t {
        _ = state
        return 0
    }
}

enum ReverseLookupNormalizer {
    static func snippet(_ value: String, maximum: Int) -> String {
        value.count <= maximum ? value : String(value.prefix(maximum - 1)) + "…"
    }

    static func weightedTerms(in value: String) -> [(String, Int)] {
        let terms = value.unicodeScalars.compactMap { scalar -> String? in
            let cjk = (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value)
            return cjk ? String(scalar) : nil
        }
        return Array(Set(terms)).sorted().map { ($0, 1) }
    }
}

struct ReverseDictionarySource: Equatable, Sendable {
    let dictionaryID: String
    let dictionaryName: String
    let reverseCapability: ReverseIndexCapability

    init(dictionaryID: String, dictionaryName: String,
         reverseCapability: ReverseIndexCapability = .supported) {
        self.dictionaryID = dictionaryID
        self.dictionaryName = dictionaryName
        self.reverseCapability = reverseCapability
    }

    init(managed descriptor: DictionaryDescriptor) {
        dictionaryID = descriptor.dictionaryID
        dictionaryName = descriptor.displayName
        switch descriptor.reverseCapabilityProbe {
        case .supported: reverseCapability = .supported
        case .noUsableNativeGloss: reverseCapability = .noChineseDefinitions
        case .unsupportedFormatter: reverseCapability = .unsupportedFormatter
        case .unknown, .none: reverseCapability = .unknownNeedsProbe
        }
    }
}

enum ManagedReverseCapabilityProbeMode: String, Equatable, Sendable {
    case sample, full
}

enum ManagedReverseCapabilityProbeTerminalReason: String, Equatable, Sendable {
    case usableNativeGlossFound, sampleLimitReached, endOfFileNoUsableNativeGloss
    case cancelled, ineligibleDescriptor, unsupportedFormatter
    case formatterDeclaresNoUsableNativeGloss, unsupportedCapabilityState
    case extractorUnavailable, runtimeValidationFailed, reopenFailed
    case enumerationCancelled, enumerationUnsupported, readFailed
}

struct ManagedReverseCapabilityProbeReport: Equatable, Sendable {
    let result: DictionaryReverseCapabilityProbe
    let mode: ManagedReverseCapabilityProbeMode
    let terminalReason: ManagedReverseCapabilityProbeTerminalReason
    let processedEntryCount: UInt64
    let expectedEntryCount: UInt64?
    let usableEntryCount: UInt64
    let usableNativeGlossCount: UInt64
    let skippedMalformedEntryCount: UInt64
    let skippedNoUsableNativeGlossEntryCount: UInt64

    var skippedEntryCount: UInt64 {
        skippedMalformedEntryCount + skippedNoUsableNativeGlossEntryCount
    }
}

enum ManagedReverseCapabilityProbe {
    static let maximumEntries: UInt64 = 512

    static func run(
        descriptor: DictionaryDescriptor
    ) -> DictionaryReverseCapabilityProbe {
        inspect(descriptor: descriptor, mode: .sample).result
    }

    static func inspect(
        descriptor: DictionaryDescriptor,
        mode: ManagedReverseCapabilityProbeMode
    ) -> ManagedReverseCapabilityProbeReport {
        _ = descriptor
        return ManagedReverseCapabilityProbeReport(
            result: .unknown,
            mode: mode,
            terminalReason: mode == .sample ? .sampleLimitReached : .readFailed,
            processedEntryCount: mode == .sample ? maximumEntries : 0,
            expectedEntryCount: nil,
            usableEntryCount: 0,
            usableNativeGlossCount: 0,
            skippedMalformedEntryCount: 0,
            skippedNoUsableNativeGlossEntryCount: mode == .sample ? maximumEntries : 0
        )
    }
}

struct ReverseIndexDictionaryProgress: Equatable, Sendable {
    let dictionaryID: String
    let dictionaryName: String
    let stage: ReverseIndexBuildStage
    let processedEntries: UInt64
    let totalEntries: UInt64?
    let canCancel: Bool
    let failureReason: String?
    let isThermallyThrottled: Bool
    var extractionStatistics: ReverseExtractionStatistics = .init()

    var entryPercentage: Int? {
        guard stage == .readingEntries || stage == .writingIndex else { return nil }
        guard let totalEntries, totalEntries > 0 else { return nil }
        return min(100, Int(Double(processedEntries) / Double(totalEntries) * 100))
    }
}

struct ReverseIndexBuildProgress: Equatable, Sendable {
    let dictionaries: [ReverseIndexDictionaryProgress]
}

struct ReverseIndexStoredState: Equatable, Sendable {
    let dictionaryID: String
    let stage: ReverseIndexBuildStage
    let builtAt: Date?
    let fileSize: UInt64?
    let failureReason: String?
    let descriptor: ReverseIndexDescriptor?
    var entryCount: UInt64? = nil
    var glossCount: UInt64? = nil
    var lastValidatedAt: Date? = nil
}

enum ReverseIndexInventory {
    static func inspect(sources: [ReverseDictionarySource], rootURL: URL? = nil)
        -> [ReverseIndexStoredState] {
        _ = rootURL
        return sources.map {
            ReverseIndexStoredState(
                dictionaryID: $0.dictionaryID, stage: .notBuilt, builtAt: nil,
                fileSize: nil, failureReason: nil, descriptor: nil
            )
        }
    }
}

@MainActor
final class ReverseIndexCoordinator {
    private(set) var currentTask: Task<[ReverseIndexDescriptor], Error>?
    private(set) var latestProgress: ReverseIndexBuildProgress?

    init(rootURL: URL, heavyWorkCoordinator: LocalHeavyWorkCoordinator = LocalHeavyWorkCoordinator()) {
        _ = (rootURL, heavyWorkCoordinator)
    }

    func cancel() { currentTask?.cancel() }

    func build(
        _ sources: [ReverseDictionarySource],
        progress: @escaping @MainActor @Sendable (ReverseIndexBuildProgress) -> Void
    ) async throws -> [ReverseIndexDescriptor] {
        _ = sources
        let snapshot = ReverseIndexBuildProgress(dictionaries: [])
        latestProgress = snapshot
        progress(snapshot)
        return []
    }
}

actor ReverseLookupService {
    func replaceDescriptors(_ descriptors: [ReverseIndexDescriptor]) { _ = descriptors }
    func mergeDescriptors(_ descriptors: [ReverseIndexDescriptor]) { _ = descriptors }
    func replaceBuildStages(_ stages: [String: ReverseIndexBuildStage]) { _ = stages }
}
