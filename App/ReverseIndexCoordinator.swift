import CryptoKit
import Darwin
import Foundation

extension DictionaryCoreBridge: @unchecked Sendable {}

enum ReverseIndexCapability: String, Equatable, Sendable {
    case supported
    case nativeChineseLookup
    case derivedReady
    case notApplicable
    case noChineseDefinitions
    case unsupportedFormatter
    case unsupportedGlossExtraction
    case enumerationUnavailable
    case unknownNeedsProbe

    var isBuildEligible: Bool { self == .supported }

    var displayName: String {
        switch self {
        case .supported: return "可建立"
        case .nativeChineseLookup: return "中→英查询：内置"
        case .derivedReady: return "中文反向：已随资源建立"
        case .notApplicable: return "仅支持英语查询"
        case .noChineseDefinitions: return "此词典不含可用中文释义"
        case .unsupportedFormatter: return "当前格式尚不支持中文反向索引"
        case .unsupportedGlossExtraction:
            return "当前词典格式暂不支持中文反向索引"
        case .enumerationUnavailable: return "当前词典无法枚举词条"
        case .unknownNeedsProbe: return "需要检测"
        }
    }

    var diagnosticDetail: String {
        switch self {
        case .unsupportedGlossExtraction:
            return "阶段：glossExtraction\n原因类型：unsupportedGlossStructure\n" +
                "已处理词条：0（构建未启动）\n可用中文词义：0\n跳过词条：0\n" +
                "该 formatter 没有稳定的翻译词义边界；为避免把词源说明和交叉引用误作精确翻译，已禁用重复重试。"
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
    var usableChineseGlosses: UInt64 = 0
    var skippedMalformed: UInt64 = 0
    var skippedNoChinese: UInt64 = 0
    var skippedUnreliableGloss: UInt64 = 0
}

protocol ReverseDefinitionExtractor {
    func extractReverseGlosses(headword: String, html: String) -> [ReverseGlossUnit]?
}

private enum ReverseDefinitionExtractorFactory {
    static func capability(for formatterIdentifier: String) -> ReverseIndexCapability {
        switch formatterIdentifier {
        case DictionaryFormatterIdentifier.genericMDictV1,
             DictionaryFormatterIdentifier.legacyGenericMDictV1,
             DictionaryFormatterIdentifier.oxfordOALD8V1,
             DictionaryFormatterIdentifier.century21V1,
             DictionaryFormatterIdentifier.medicalEnglishChineseV1:
            return .supported
        case DictionaryFormatterIdentifier.affixRootAV1:
            // The formatter presents etymological prose and cross-references but exposes no
            // stable translation-gloss boundary. Treating its whole text as a gloss caused both
            // false exact matches and repeatable zero-gloss build failures.
            return .unsupportedGlossExtraction
        case DictionaryFormatterIdentifier.newOxfordV1:
            return .noChineseDefinitions
        default:
            return .unsupportedFormatter
        }
    }

    static func extractor(for formatterIdentifier: String) -> ReverseDefinitionExtractor? {
        switch formatterIdentifier {
        case DictionaryFormatterIdentifier.genericMDictV1,
             DictionaryFormatterIdentifier.legacyGenericMDictV1:
            return GenericReverseDefinitionExtractor()
        case DictionaryFormatterIdentifier.oxfordOALD8V1:
            return OxfordReverseDefinitionExtractor()
        case DictionaryFormatterIdentifier.century21V1:
            return SupplementalReverseDefinitionExtractor(kind: .century21)
        case DictionaryFormatterIdentifier.medicalEnglishChineseV1:
            return SupplementalReverseDefinitionExtractor(kind: .medical)
        default:
            return nil
        }
    }
}

private struct GenericReverseDefinitionExtractor: ReverseDefinitionExtractor {
    func extractReverseGlosses(headword: String, html: String) -> [ReverseGlossUnit]? {
        let plainText = GenericMDictEntryFormatter().sanitizeHTML(html).plainText
        return ReverseGlossExtractor.genericUnits(from: plainText)
    }
}

private struct OxfordReverseDefinitionExtractor: ReverseDefinitionExtractor {
    func extractReverseGlosses(headword: String, html: String) -> [ReverseGlossUnit]? {
        let entry = OxfordEntryFormatter().formatHTML(html).structuredEntry
        var values = entry.definitions
        values.append(contentsOf: ReverseDefinitionText.semanticDefinitions(entry.semanticEntry))
        return ReverseGlossExtractor.units(from: values)
    }
}

private struct SupplementalReverseDefinitionExtractor: ReverseDefinitionExtractor {
    enum Kind { case century21, medical }
    let kind: Kind

    func extractReverseGlosses(headword: String, html: String) -> [ReverseGlossUnit]? {
        let result: SupplementalFormatResult
        switch kind {
        case .century21:
            result = Century21EntryFormatter().formatHTML(html, matchedHeadword: headword)
        case .medical:
            result = MedicalEntryFormatter().formatHTML(html, matchedHeadword: headword)
        }
        var values = result.structuredEntry.definitions
        values.append(contentsOf: result.structuredEntry.partOfSpeechSections.flatMap { section in
            section.senses.map(\.definition)
        })
        values.append(contentsOf: ReverseDefinitionText.semanticDefinitions(
            result.structuredEntry.semanticEntry
        ))
        return ReverseGlossExtractor.units(from: values)
    }
}

private enum ReverseDefinitionText {
    static let maximumCharacters = ReverseIndexStreamingWriter.maximumDefinitionCharacters

    static func join(_ values: [String]) -> String? {
        var seen: Set<String> = []
        var output: [String] = []
        var remaining = maximumCharacters
        for raw in values where remaining > 0 {
            let normalized = ReverseLookupNormalizer.normalizeDefinition(raw)
            guard !normalized.isEmpty else { continue }
            let key = normalized.precomposedStringWithCanonicalMapping
            guard seen.insert(key).inserted else { continue }
            let value = String(normalized.prefix(remaining))
            output.append(value)
            remaining -= value.count
        }
        return bounded(output.joined(separator: "；"))
    }

    static func bounded(_ value: String) -> String? {
        let normalized = ReverseLookupNormalizer.normalizeDefinition(value)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumCharacters))
    }

    static func semanticDefinitions(_ entry: DictionarySemanticEntry) -> [String] {
        entry.partOfSpeechSections.flatMap { section in
            section.senses.flatMap(definitions)
        }
    }

    private static func definitions(_ sense: DictionarySemanticSense) -> [String] {
        sense.definitionChinese + sense.subsenses.flatMap(definitions)
    }
}

struct LegacyReverseDictionaryIdentity: Equatable, Sendable {
    let dictionaryID: String
    let formatterIdentifier: String
    let dictionaryURL: URL
    let indexURL: URL
}

enum ReverseDictionarySourceBacking: Sendable {
    case legacy(identity: LegacyReverseDictionaryIdentity)
    case managed(descriptor: DictionaryDescriptor)
    case internalOpenResource(descriptor: DictionaryDescriptor)
}

struct ReverseDictionarySource: Sendable {
    let dictionaryID: String
    let dictionaryName: String
    let queryPriority: Int
    let sortPosition: Int64
    let expectedEntryCount: UInt64?
    let backing: ReverseDictionarySourceBacking

    var formatterIdentifier: String? {
        switch backing {
        case .legacy(let identity): return identity.formatterIdentifier
        case .managed(let descriptor), .internalOpenResource(let descriptor):
            return descriptor.formatterIdentifier
        }
    }

    var reverseCapability: ReverseIndexCapability {
        if case .internalOpenResource(let descriptor) = backing {
            guard let resourceID = descriptor.openResourceMetadata?.resourceID,
                  let capabilities = BundledOpenResourceCatalog.capabilities(
                    resourceID: resourceID
                  ) else {
                return .unsupportedFormatter
            }
            if capabilities.supportsChineseReverse { return .derivedReady }
            if capabilities.supportsChineseLookup { return .nativeChineseLookup }
            return .notApplicable
        }
        if case .managed(let descriptor) = backing {
            if let probe = descriptor.reverseCapabilityProbe {
                switch probe {
                case .supported: return .supported
                case .noUsableNativeGloss: return .noChineseDefinitions
                case .unsupportedFormatter: return .unsupportedFormatter
                case .unknown: return .unknownNeedsProbe
                }
            }
            let declared = ReverseDefinitionExtractorFactory.capability(
                for: descriptor.formatterIdentifier
            )
            // A generic imported formatter describes structure, not actual language content.
            return declared == .supported ? .unknownNeedsProbe : declared
        }
        guard let formatterIdentifier else { return .unknownNeedsProbe }
        return ReverseDefinitionExtractorFactory.capability(for: formatterIdentifier)
    }

    init(dictionaryID: String, dictionaryName: String,
         dictionaryURL: URL, indexURL: URL,
         queryPriority: Int, sortPosition: Int64,
         expectedEntryCount: UInt64?,
         formatterIdentifier: String = DictionaryFormatterIdentifier.legacyGenericMDictV1) {
        self.dictionaryID = dictionaryID
        self.dictionaryName = dictionaryName
        self.queryPriority = queryPriority
        self.sortPosition = sortPosition
        self.expectedEntryCount = expectedEntryCount
        backing = .legacy(identity: LegacyReverseDictionaryIdentity(
            dictionaryID: dictionaryID,
            formatterIdentifier: formatterIdentifier,
            dictionaryURL: dictionaryURL,
            indexURL: indexURL
        ))
    }

    init(managed descriptor: DictionaryDescriptor) {
        dictionaryID = descriptor.dictionaryID
        dictionaryName = descriptor.displayName
        queryPriority = descriptor.queryLevel.rank
        sortPosition = descriptor.sortPosition
        expectedEntryCount = descriptor.indexMetadata.entryCount
        backing = DictionaryFormatterIdentifier.supportsOpenResourceSQLite(
            descriptor.formatterIdentifier
        ) ? .internalOpenResource(descriptor: descriptor) : .managed(descriptor: descriptor)
    }
}

enum ManagedReverseCapabilityProbeMode: String, Equatable, Sendable {
    /// Fast post-import hint. Reaching the bound is intentionally inconclusive.
    case sample
    /// User-requested conclusive scan. Stops on the first reliable gloss or at EOF.
    case full
}

enum ManagedReverseCapabilityProbeTerminalReason: String, Equatable, Sendable {
    case usableNativeGlossFound
    case sampleLimitReached
    case endOfFileNoUsableNativeGloss
    case cancelled
    case ineligibleDescriptor
    case unsupportedFormatter
    case formatterDeclaresNoUsableNativeGloss
    case unsupportedCapabilityState
    case extractorUnavailable
    case runtimeValidationFailed
    case reopenFailed
    case enumerationCancelled
    case enumerationUnsupported
    case readFailed
}

/// Non-sensitive result of inspecting an app-managed imported dictionary. The report contains
/// counts and typed terminal state only: no headwords, definitions, paths, or source contents.
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

    fileprivate var diagnosticLine: String {
        "mode=\(mode.rawValue) result=\(result.rawValue) " +
            "reason=\(terminalReason.rawValue) " +
            "processed=\(processedEntryCount) " +
            "expected=\(expectedEntryCount.map(String.init) ?? "unknown") " +
            "usable=\(usableEntryCount) glosses=\(usableNativeGlossCount) " +
            "skipped=\(skippedEntryCount)"
    }
}

/// Read-only capability inspection run after a managed forward index becomes ready. It never
/// creates a reverse sidecar. `run` remains the bounded automatic probe; an explicit user action
/// can request `.full` through `inspect` to reach a stable yes/no result.
enum ManagedReverseCapabilityProbe {
    static let maximumEntries: UInt64 = 512
    private static let maximumEntryBytes: UInt = 512 * 1024

    static func run(
        descriptor: DictionaryDescriptor,
        applicationSupportRootURL: URL =
            DictionaryImportService.defaultApplicationSupportRootURL(),
        diagnostic: ((String) -> Void)? = nil
    ) -> DictionaryReverseCapabilityProbe {
        inspect(
            descriptor: descriptor,
            mode: .sample,
            applicationSupportRootURL: applicationSupportRootURL,
            diagnostic: diagnostic
        ).result
    }

    static func inspect(
        descriptor: DictionaryDescriptor,
        mode: ManagedReverseCapabilityProbeMode,
        applicationSupportRootURL: URL =
            DictionaryImportService.defaultApplicationSupportRootURL(),
        diagnostic: ((String) -> Void)? = nil
    ) -> ManagedReverseCapabilityProbeReport {
        func report(
            _ result: DictionaryReverseCapabilityProbe,
            _ reason: ManagedReverseCapabilityProbeTerminalReason,
            processed: UInt64 = 0,
            expected: UInt64? = nil,
            usable: UInt64 = 0,
            glosses: UInt64 = 0,
            malformed: UInt64 = 0,
            noGloss: UInt64 = 0
        ) -> ManagedReverseCapabilityProbeReport {
            let value = ManagedReverseCapabilityProbeReport(
                result: result,
                mode: mode,
                terminalReason: reason,
                processedEntryCount: processed,
                expectedEntryCount: expected,
                usableEntryCount: usable,
                usableNativeGlossCount: glosses,
                skippedMalformedEntryCount: malformed,
                skippedNoUsableNativeGlossEntryCount: noGloss
            )
            diagnostic?(value.diagnosticLine)
            return value
        }

        guard !Task.isCancelled else {
            return report(.unknown, .cancelled)
        }
        guard descriptor.sourceKind == .managedLocal,
              descriptor.storageOwnership == .appManagedImported,
              descriptor.state == .ready else {
            return report(
                .unknown, .ineligibleDescriptor,
                expected: descriptor.indexMetadata.entryCount
            )
        }
        switch ReverseDefinitionExtractorFactory.capability(
            for: descriptor.formatterIdentifier
        ) {
        case .unsupportedFormatter, .unsupportedGlossExtraction,
             .enumerationUnavailable:
            return report(
                .unsupportedFormatter, .unsupportedFormatter,
                expected: descriptor.indexMetadata.entryCount
            )
        case .noChineseDefinitions, .notApplicable:
            return report(
                .noUsableNativeGloss, .formatterDeclaresNoUsableNativeGloss,
                expected: descriptor.indexMetadata.entryCount
            )
        case .supported:
            break
        case .nativeChineseLookup, .derivedReady, .unknownNeedsProbe:
            return report(
                .unknown, .unsupportedCapabilityState,
                expected: descriptor.indexMetadata.entryCount
            )
        }
        guard let extractor = ReverseDefinitionExtractorFactory.extractor(
            for: descriptor.formatterIdentifier
        ) else {
            return report(
                .unsupportedFormatter, .extractorUnavailable,
                expected: descriptor.indexMetadata.entryCount
            )
        }
        do {
            let plan = try ManagedDictionaryRuntimeValidator(
                applicationSupportRootURL: applicationSupportRootURL,
                expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion)
            ).validate(descriptor)
            let expected = descriptor.indexMetadata.entryCount ?? plan.entryCount
            let core = DictionaryCoreBridge(
                managedReadOnlyWithRootPath: plan.managedRootURL.path,
                sourceRelativePath: plan.sourceRelativePath,
                indexRelativePath: plan.indexRelativePath,
                dictionaryID: plan.dictionaryID,
                publicationID: plan.indexPublicationID,
                indexSHA256: plan.indexSHA256,
                indexFileSize: plan.indexFileSize,
                sourceSHA256: plan.sourceSHA256,
                sourceFileSize: plan.sourceFileSize,
                schemaVersion: plan.schemaVersion,
                entryCount: plan.entryCount,
                cacheMaximumBytes: 512 * 1024,
                cacheMaximumEntries: 8
            )
            guard core.isReady else {
                return report(.unknown, .reopenFailed, expected: expected)
            }
            var processed: UInt64 = 0
            var usable: UInt64 = 0
            var glosses: UInt64 = 0
            var malformed: UInt64 = 0
            var noGloss: UInt64 = 0
            var foundGloss = false
            var reachedSampleLimit = false
            let result = core.enumerateEntries(
                forReverse: maximumEntryBytes,
                cancellationCheck: { Task.isCancelled },
                handler: { headword, html, _ in
                    if Task.isCancelled { return false }
                    processed += 1
                    guard !headword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let extracted = extractor.extractReverseGlosses(
                              headword: headword, html: html
                          ) else {
                        malformed += 1
                        if mode == .sample, processed >= maximumEntries {
                            reachedSampleLimit = true
                            return false
                        }
                        return true
                    }
                    usable += 1
                    guard !extracted.isEmpty else {
                        noGloss += 1
                        if mode == .sample, processed >= maximumEntries {
                            reachedSampleLimit = true
                            return false
                        }
                        return true
                    }
                    glosses = UInt64(extracted.count)
                    foundGloss = true
                    return false
                }
            )
            guard !Task.isCancelled else {
                return report(
                    .unknown, .cancelled, processed: processed, expected: expected,
                    usable: usable, glosses: glosses, malformed: malformed,
                    noGloss: noGloss
                )
            }
            // The bridge reports an intentional handler stop like cancellation. Consume our
            // typed terminal evidence before inspecting the bridge status.
            if foundGloss {
                return report(
                    .supported, .usableNativeGlossFound, processed: processed,
                    expected: expected, usable: usable, glosses: glosses,
                    malformed: malformed, noGloss: noGloss
                )
            }
            if reachedSampleLimit {
                return report(
                    .unknown, .sampleLimitReached, processed: processed,
                    expected: expected, usable: usable, malformed: malformed,
                    noGloss: noGloss
                )
            }
            if result["cancelled"] as? Bool == true {
                return report(
                    .unknown, .enumerationCancelled, processed: processed,
                    expected: expected, usable: usable, malformed: malformed,
                    noGloss: noGloss
                )
            }
            guard result["success"] as? Bool == true else {
                let reason: ManagedReverseCapabilityProbeTerminalReason =
                    result["failureKind"] as? String == "enumerationUnsupported"
                    ? .enumerationUnsupported : .readFailed
                return report(
                    .unknown, reason, processed: processed, expected: expected,
                    usable: usable, malformed: malformed, noGloss: noGloss
                )
            }
            return report(
                .noUsableNativeGloss, .endOfFileNoUsableNativeGloss,
                processed: processed, expected: expected, usable: usable,
                malformed: malformed, noGloss: noGloss
            )
        } catch {
            return report(
                .unknown, .runtimeValidationFailed,
                expected: descriptor.indexMetadata.entryCount
            )
        }
    }
}

struct ReverseIndexDictionaryProgress: Equatable, Sendable, Identifiable {
    let dictionaryID: String
    let dictionaryName: String
    let stage: ReverseIndexBuildStage
    let processedEntries: UInt64
    let totalEntries: UInt64?
    let canCancel: Bool
    let failureReason: String?
    let isThermallyThrottled: Bool
    let extractionStatistics: ReverseExtractionStatistics

    init(dictionaryID: String, dictionaryName: String, stage: ReverseIndexBuildStage,
         processedEntries: UInt64, totalEntries: UInt64?, canCancel: Bool,
         failureReason: String?, isThermallyThrottled: Bool,
         extractionStatistics: ReverseExtractionStatistics = .init()) {
        self.dictionaryID = dictionaryID
        self.dictionaryName = dictionaryName
        self.stage = stage
        self.processedEntries = processedEntries
        self.totalEntries = totalEntries
        self.canCancel = canCancel
        self.failureReason = failureReason
        self.isThermallyThrottled = isThermallyThrottled
        self.extractionStatistics = extractionStatistics
    }

    var id: String { dictionaryID }

    var entryPercentage: Int? {
        guard stage == .readingEntries || stage == .writingIndex else { return nil }
        guard let totalEntries, totalEntries > 0 else { return nil }
        let ratio = Double(processedEntries) / Double(totalEntries)
        return min(100, max(0, Int(ratio * 100)))
    }
}

struct ReverseIndexBuildProgress: Equatable, Sendable {
    let dictionaries: [ReverseIndexDictionaryProgress]
    let completedDictionaries: Int
    let totalDictionaries: Int
    let currentDictionaryID: String?

    var currentDictionary: ReverseIndexDictionaryProgress? {
        guard let currentDictionaryID else { return nil }
        return dictionaries.first { $0.dictionaryID == currentDictionaryID }
    }
}

private struct ReverseIndexBuildEvent: Sendable {
    let dictionaryID: String
    let stage: ReverseIndexBuildStage
    let processedEntries: UInt64
    let failureReason: String?
    let isThermallyThrottled: Bool
    var extractionStatistics: ReverseExtractionStatistics? = nil
}

enum ReverseIndexThermalPacing {
    static func delayMicroseconds(for state: ProcessInfo.ThermalState) -> useconds_t {
        switch state {
        case .serious: return 20_000
        case .critical: return 100_000
        case .nominal, .fair: return 0
        @unknown default: return 20_000
        }
    }
}

@MainActor
final class ReverseIndexCoordinator {
    private(set) var currentTask: Task<[ReverseIndexDescriptor], Error>?
    private(set) var latestProgress: ReverseIndexBuildProgress?
    private let rootURL: URL
    private let heavyWorkCoordinator: LocalHeavyWorkCoordinator
    private var buildGeneration: UInt64 = 0
    private var progressObserver: (@MainActor @Sendable (ReverseIndexBuildProgress) -> Void)?

    init(
        rootURL: URL = DictionaryImportService.defaultApplicationSupportRootURL()
            .appendingPathComponent("ReverseIndexes", isDirectory: true),
        heavyWorkCoordinator: LocalHeavyWorkCoordinator = LocalHeavyWorkCoordinator()
    ) {
        self.rootURL = rootURL
        self.heavyWorkCoordinator = heavyWorkCoordinator
    }

    func cancel() {
        buildGeneration &+= 1
        currentTask?.cancel()
        guard let latestProgress else { return }
        let updated = latestProgress.dictionaries.map { item in
            guard item.canCancel || item.stage == .queued else { return item }
            return ReverseIndexDictionaryProgress(
                dictionaryID: item.dictionaryID,
                dictionaryName: item.dictionaryName,
                stage: .cancelling,
                processedEntries: item.processedEntries,
                totalEntries: item.totalEntries,
                canCancel: false,
                failureReason: nil,
                isThermallyThrottled: item.isThermallyThrottled,
                extractionStatistics: item.extractionStatistics
            )
        }
        publish(updated, currentDictionaryID: latestProgress.currentDictionaryID)
    }

    func build(
        _ sources: [ReverseDictionarySource],
        progress: @escaping @MainActor @Sendable (ReverseIndexBuildProgress) -> Void
    ) async throws -> [ReverseIndexDescriptor] {
        guard currentTask == nil else { throw ReverseIndexError.writeFailed }
        let ordered = sources.filter(\.reverseCapability.isBuildEligible)
            .sorted(by: Self.sortSources)
        guard !ordered.isEmpty else { return [] }
        buildGeneration &+= 1
        let generation = buildGeneration
        progressObserver = progress
        let initial = ordered.map {
            ReverseIndexDictionaryProgress(
                dictionaryID: $0.dictionaryID,
                dictionaryName: $0.dictionaryName,
                stage: .queued,
                processedEntries: 0,
                totalEntries: $0.expectedEntryCount,
                canCancel: true,
                failureReason: nil,
                isThermallyThrottled: false
            )
        }
        publish(initial, currentDictionaryID: nil)

        let permit: LocalHeavyWorkCoordinator.Permit
        do {
            permit = try await heavyWorkCoordinator.acquire(.reverseIndex)
        } catch {
            markRemainingCancelled()
            throw ReverseIndexError.cancelled
        }
        guard generation == buildGeneration, !Task.isCancelled else {
            await permit.release()
            markRemainingCancelled()
            throw ReverseIndexError.cancelled
        }

        let rootURL = self.rootURL
        let task = Task.detached(priority: .utility) {
            try Self.runBuild(ordered, rootURL: rootURL) { event in
                Task { @MainActor [weak self] in
                    guard let self, self.buildGeneration == generation else { return }
                    self.apply(event)
                }
            }
        }
        currentTask = task
        do {
            let descriptors = try await task.value
            // Final worker events are delivered as MainActor tasks. Give them a turn, then
            // reconcile successful publications before removing the observer so a last `ready`
            // event cannot be lost in the detached-task completion race.
            await Task.yield()
            reconcileCompletedBuild(sources: ordered, descriptors: descriptors)
            currentTask = nil
            await permit.release()
            progressObserver = nil
            return descriptors
        } catch {
            currentTask = nil
            await permit.release()
            if error is CancellationError || error as? ReverseIndexError == .cancelled {
                markRemainingCancelled()
                progressObserver = nil
                throw ReverseIndexError.cancelled
            }
            progressObserver = nil
            throw error
        }
    }

    private func apply(_ event: ReverseIndexBuildEvent) {
        guard let latestProgress,
              let index = latestProgress.dictionaries.firstIndex(where: {
                  $0.dictionaryID == event.dictionaryID
              }) else { return }
        var values = latestProgress.dictionaries
        let old = values[index]
        values[index] = ReverseIndexDictionaryProgress(
            dictionaryID: old.dictionaryID,
            dictionaryName: old.dictionaryName,
            stage: event.stage,
            processedEntries: max(old.processedEntries, event.processedEntries),
            totalEntries: old.totalEntries,
            canCancel: [.readingEntries, .writingIndex, .optimizing, .validating]
                .contains(event.stage),
            failureReason: event.failureReason,
            isThermallyThrottled: event.isThermallyThrottled,
            extractionStatistics: event.extractionStatistics ?? old.extractionStatistics
        )
        let currentID: String? = [.ready, .notApplicable, .cancelled, .failed, .stale]
            .contains(event.stage) ? nil : event.dictionaryID
        publish(values, currentDictionaryID: currentID)
    }

    private func markRemainingCancelled() {
        guard let latestProgress else { return }
        let values = latestProgress.dictionaries.map { item in
            guard [.queued, .readingEntries, .writingIndex, .optimizing, .validating,
                   .publishing, .cancelling].contains(item.stage) else { return item }
            return ReverseIndexDictionaryProgress(
                dictionaryID: item.dictionaryID,
                dictionaryName: item.dictionaryName,
                stage: .cancelled,
                processedEntries: item.processedEntries,
                totalEntries: item.totalEntries,
                canCancel: false,
                failureReason: nil,
                isThermallyThrottled: false,
                extractionStatistics: item.extractionStatistics
            )
        }
        publish(values, currentDictionaryID: nil)
    }

    private func reconcileCompletedBuild(
        sources: [ReverseDictionarySource],
        descriptors: [ReverseIndexDescriptor]
    ) {
        guard let latestProgress else { return }
        let readyIDs = Set(descriptors.map { $0.identity.dictionaryID })
        let sourceIDs = Set(sources.map(\.dictionaryID))
        let values = latestProgress.dictionaries.map { item in
            guard sourceIDs.contains(item.dictionaryID) else { return item }
            if readyIDs.contains(item.dictionaryID) {
                return ReverseIndexDictionaryProgress(
                    dictionaryID: item.dictionaryID,
                    dictionaryName: item.dictionaryName,
                    stage: .ready,
                    processedEntries: item.processedEntries,
                    totalEntries: item.totalEntries,
                    canCancel: false,
                    failureReason: nil,
                    isThermallyThrottled: false,
                    extractionStatistics: item.extractionStatistics
                )
            }
            guard [.queued, .readingEntries, .writingIndex, .optimizing, .validating,
                   .publishing, .cancelling].contains(item.stage) else { return item }
            return ReverseIndexDictionaryProgress(
                dictionaryID: item.dictionaryID,
                dictionaryName: item.dictionaryName,
                stage: .failed,
                processedEntries: item.processedEntries,
                totalEntries: item.totalEntries,
                canCancel: false,
                failureReason: "反向索引未能完成，可重试这本词典。",
                isThermallyThrottled: false,
                extractionStatistics: item.extractionStatistics
            )
        }
        publish(values, currentDictionaryID: nil)
    }

    private func publish(_ dictionaries: [ReverseIndexDictionaryProgress],
                         currentDictionaryID: String?) {
        let snapshot = ReverseIndexBuildProgress(
            dictionaries: dictionaries,
            completedDictionaries: dictionaries.filter { $0.stage == .ready }.count,
            totalDictionaries: dictionaries.count,
            currentDictionaryID: currentDictionaryID
        )
        latestProgress = snapshot
        progressObserver?(snapshot)
    }

    private nonisolated static func runBuild(
        _ sources: [ReverseDictionarySource],
        rootURL: URL,
        event: @escaping @Sendable (ReverseIndexBuildEvent) -> Void
    ) throws -> [ReverseIndexDescriptor] {
        pruneAbandonedTemporaryIndexes(rootURL: rootURL)
        let managedValidator = ManagedDictionaryRuntimeValidator(
            applicationSupportRootURL: DictionaryImportService.defaultApplicationSupportRootURL(),
            expectedSchemaVersion: Int(liveDictionaryIndexSchemaVersion)
        )
        var descriptors: [ReverseIndexDescriptor] = []
        for source in sources {
            try Task.checkCancellation()
            event(ReverseIndexBuildEvent(
                dictionaryID: source.dictionaryID,
                stage: .readingEntries,
                processedEntries: 0,
                failureReason: nil,
                isThermallyThrottled: false
            ))
            let core: DictionaryCoreBridge
            let sourceIdentity: String
            let publication: String
            let formatterIdentifier: String
            do {
                switch source.backing {
                case .legacy(let identity):
                    guard DictionaryFormatterIdentifier.supportsLegacyMDictEnumeration(
                        identity.formatterIdentifier
                    ) else { throw ReverseIndexError.unsupportedFormatter }
                    core = DictionaryCoreBridge(
                        legacyReadOnlyWithDictionaryPath: identity.dictionaryURL.path,
                        indexPath: identity.indexURL.path,
                        dictionaryID: identity.dictionaryID,
                        formatterIdentifier: identity.formatterIdentifier,
                        cacheMaximumBytes: 1024 * 1024,
                        cacheMaximumEntries: 16
                    )
                    guard core.isReady,
                          OpenResourceInstallationMetadata.isSHA256(core.sourceSHA256),
                          OpenResourceInstallationMetadata.isSHA256(core.indexSHA256) else {
                        throw ReverseIndexError.stale
                    }
                    sourceIdentity = core.sourceSHA256
                    publication = "legacy-forward-v1-\(core.indexSHA256)"
                    formatterIdentifier = identity.formatterIdentifier
                case .managed(let descriptor):
                    guard DictionaryFormatterIdentifier.supportsGenericMDictV1(
                        descriptor.formatterIdentifier
                    ) else { throw ReverseIndexError.unsupportedFormatter }
                    let plan = try managedValidator.validate(descriptor)
                    core = DictionaryCoreBridge(
                        managedReadOnlyWithRootPath: plan.managedRootURL.path,
                        sourceRelativePath: plan.sourceRelativePath,
                        indexRelativePath: plan.indexRelativePath,
                        dictionaryID: plan.dictionaryID,
                        publicationID: plan.indexPublicationID,
                        indexSHA256: plan.indexSHA256,
                        indexFileSize: plan.indexFileSize,
                        sourceSHA256: plan.sourceSHA256,
                        sourceFileSize: plan.sourceFileSize,
                        schemaVersion: plan.schemaVersion,
                        entryCount: plan.entryCount,
                        cacheMaximumBytes: 1024 * 1024,
                        cacheMaximumEntries: 16
                    )
                    sourceIdentity = plan.sourceSHA256
                    publication = plan.indexPublicationID
                    formatterIdentifier = descriptor.formatterIdentifier
                case .internalOpenResource(let descriptor):
                    let openDescriptor = try OpenResourceSQLiteRuntime.reverseDescriptor(
                        descriptor: descriptor,
                        applicationSupportRootURL:
                            DictionaryImportService.defaultApplicationSupportRootURL()
                    )
                    descriptors.append(openDescriptor)
                    event(ReverseIndexBuildEvent(
                        dictionaryID: source.dictionaryID,
                        stage: .ready,
                        processedEntries: source.expectedEntryCount ?? 0,
                        failureReason: nil,
                        isThermallyThrottled: false
                    ))
                    continue
                }
            } catch {
                event(failureEvent(for: source, error: error))
                continue
            }
            guard core.isReady else {
                event(failureEvent(for: source, error: ReverseIndexError.unavailable))
                continue
            }
            guard let extractor = ReverseDefinitionExtractorFactory.extractor(
                for: formatterIdentifier
            ) else {
                event(failureEvent(for: source, error: ReverseIndexError.unsupportedFormatter))
                continue
            }
            let identity = ReverseIndexIdentity(
                dictionaryID: source.dictionaryID,
                dictionaryName: source.dictionaryName,
                sourceSHA256: sourceIdentity,
                indexPublicationID: publication,
                queryPriority: source.queryPriority,
                sortPosition: source.sortPosition
            )
            let destination = rootURL.appendingPathComponent(
                "\(safeFileComponent(source.dictionaryID)).reverse.sqlite"
            )
            let writer: ReverseIndexStreamingWriter
            do {
                writer = try ReverseIndexStreamingWriter(
                    destinationURL: destination,
                    identity: identity,
                    cancellationCheck: { Task.isCancelled }
                )
            } catch {
                event(failureEvent(for: source, error: error))
                continue
            }
            var processed: UInt64 = 0
            var recordFailure: ReverseIndexError?
            var statistics = ReverseExtractionStatistics()
            event(ReverseIndexBuildEvent(
                dictionaryID: source.dictionaryID,
                stage: .writingIndex,
                processedEntries: 0,
                failureReason: nil,
                isThermallyThrottled: false
            ))
            let result = core.enumerateEntries(
                forReverse: 512 * 1024,
                cancellationCheck: { Task.isCancelled },
                handler: { headword, html, _ in
                    if Task.isCancelled { return false }
                    processed += 1
                    statistics.totalEntries += 1
                    guard !headword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        statistics.skippedMalformed += 1
                        return true
                    }
                    guard let glosses = extractor.extractReverseGlosses(
                        headword: headword, html: html
                    ) else {
                        statistics.skippedMalformed += 1
                        return true
                    }
                    statistics.usableEntries += 1
                    guard !glosses.isEmpty else {
                        statistics.skippedNoChinese += 1
                        statistics.skippedUnreliableGloss += 1
                        return true
                    }
                    do {
                        try writer.append(ReverseIndexEntry(
                            headword: headword,
                            glossUnits: glosses
                        ))
                        statistics.entriesWithChinese += 1
                        statistics.usableChineseGlosses += UInt64(glosses.count)
                        if processed % 256 == 0 {
                            let thermalState = ProcessInfo.processInfo.thermalState
                            let delay = ReverseIndexThermalPacing.delayMicroseconds(
                                for: thermalState
                            )
                            event(ReverseIndexBuildEvent(
                                dictionaryID: source.dictionaryID,
                                stage: .writingIndex,
                                processedEntries: processed,
                                failureReason: nil,
                                isThermallyThrottled: delay > 0,
                                extractionStatistics: statistics
                            ))
                            if delay > 0 { usleep(delay) }
                            else if processed % 2_048 == 0 { sched_yield() }
                        }
                        return true
                    } catch {
                        recordFailure = .writeFailed
                        return false
                    }
                }
            )
            if Task.isCancelled {
                writer.abort()
                event(ReverseIndexBuildEvent(
                    dictionaryID: source.dictionaryID,
                    stage: .cancelled,
                    processedEntries: processed,
                    failureReason: nil,
                    isThermallyThrottled: false
                ))
                throw ReverseIndexError.cancelled
            }
            if let recordFailure {
                writer.abort()
                event(failureEvent(for: source, error: recordFailure,
                                   processedEntries: processed,
                                   statistics: statistics))
                continue
            }
            if result["cancelled"] as? Bool == true {
                writer.abort()
                event(failureEvent(for: source, error: ReverseIndexError.enumerationUnsupported,
                                   processedEntries: processed,
                                   statistics: statistics))
                continue
            }
            guard result["success"] as? Bool == true else {
                writer.abort()
                let failure: ReverseIndexError = (result["failureKind"] as? String) ==
                    "enumerationUnsupported" ? .enumerationUnsupported : .writeFailed
                event(failureEvent(for: source, error: failure,
                                   processedEntries: processed,
                                   statistics: statistics))
                continue
            }
            do {
                let summary = try writer.finish { stage in
                    event(ReverseIndexBuildEvent(
                        dictionaryID: source.dictionaryID,
                        stage: stage,
                        processedEntries: processed,
                        failureReason: nil,
                        isThermallyThrottled: false,
                        extractionStatistics: statistics
                    ))
                }
                #if DEBUG
                NSLog("LocalDictionary ReverseIndex finalization dictionary=%@ " +
                      "commit_ms=%.3f metadata_ms=%.3f optimize_ms=%.3f " +
                      "quick_validation_ms=%.3f fsync_ms=%.3f publication_ms=%.3f " +
                      "reopen_ms=%.3f total_ms=%.3f",
                      source.dictionaryID,
                      summary.metrics.commitMilliseconds,
                      summary.metrics.metadataMilliseconds,
                      summary.metrics.optimizeMilliseconds,
                      summary.metrics.quickValidationMilliseconds,
                      summary.metrics.fsyncMilliseconds,
                      summary.metrics.publicationMilliseconds,
                      summary.metrics.reopenMilliseconds,
                      summary.metrics.totalMilliseconds)
                #endif
                descriptors.append(ReverseIndexDescriptor(
                    fileURL: destination, identity: identity
                ))
                event(ReverseIndexBuildEvent(
                    dictionaryID: source.dictionaryID,
                    stage: .ready,
                    processedEntries: processed,
                    failureReason: nil,
                    isThermallyThrottled: false,
                    extractionStatistics: statistics
                ))
                sched_yield()
            } catch {
                writer.abort()
                if error as? ReverseIndexError == .cancelled || Task.isCancelled {
                    event(ReverseIndexBuildEvent(
                        dictionaryID: source.dictionaryID,
                        stage: .cancelled,
                        processedEntries: processed,
                        failureReason: nil,
                        isThermallyThrottled: false
                    ))
                    throw ReverseIndexError.cancelled
                }
                event(failureEvent(for: source, error: error,
                                   processedEntries: processed,
                                   statistics: statistics))
            }
        }
        return descriptors
    }

    private nonisolated static func failureEvent(
        for source: ReverseDictionarySource,
        error: Error,
        processedEntries: UInt64 = 0,
        statistics: ReverseExtractionStatistics? = nil
    ) -> ReverseIndexBuildEvent {
        ReverseIndexBuildEvent(
            dictionaryID: source.dictionaryID,
            // A stale or unavailable forward index discovered while a build is running is a
            // build failure, not a passive inventory state.  Keep it terminal and visible with
            // its concrete reason so the manager never falls back to `notBuilt` and invites an
            // unexplained retry loop.
            stage: error as? ReverseIndexError == .insufficientChineseDefinitions ||
                error as? ReverseIndexError == .noChineseDefinitions ? .notApplicable : .failed,
            processedEntries: processedEntries,
            failureReason: (error as? LocalizedError)?.errorDescription ??
                "反向索引建立失败，可重试。",
            isThermallyThrottled: false,
            extractionStatistics: statistics
        )
    }

    private nonisolated static func pruneAbandonedTemporaryIndexes(rootURL: URL) {
        guard let values = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }
        for url in values where url.lastPathComponent.contains(".reverse.sqlite.building-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func safeFileComponent(_ source: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(source.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }.prefix(128))
    }

    private nonisolated static func sortSources(
        _ lhs: ReverseDictionarySource,
        _ rhs: ReverseDictionarySource
    ) -> Bool {
        if lhs.queryPriority != rhs.queryPriority {
            return lhs.queryPriority < rhs.queryPriority
        }
        if lhs.sortPosition != rhs.sortPosition {
            return lhs.sortPosition < rhs.sortPosition
        }
        return lhs.dictionaryID < rhs.dictionaryID
    }
}
