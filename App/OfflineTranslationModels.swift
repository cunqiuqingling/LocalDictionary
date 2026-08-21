import Foundation
import NaturalLanguage

enum OfflineTranslationLanguage: String, Codable, Equatable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

extension OfflineTranslationLanguage {
    var languageIdentifier: LanguageIdentifier {
        switch self {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        }
    }
}

struct OfflineTranslationPair: Hashable, Codable, Sendable {
    let source: OfflineTranslationLanguage
    let target: OfflineTranslationLanguage

    init(source: OfflineTranslationLanguage, target: OfflineTranslationLanguage) {
        precondition(source != target)
        self.source = source
        self.target = target
    }
}

enum OfflineTranslationOutputRole: String, Codable, Equatable, Hashable, Sendable {
    case learningVersion
    case nativeVersion
}

enum OfflineTranslationPlanKind: String, Codable, Equatable, Sendable {
    case nativeToLearning
    case learningToNative
    case mixedBidirectional
    case unknownBidirectional
}

struct PlannedOfflineTranslation: Equatable, Sendable {
    let outputRole: OfflineTranslationOutputRole
    let pair: OfflineTranslationPair
}

struct OfflineTranslationPlan: Equatable, Sendable {
    let kind: OfflineTranslationPlanKind
    let operations: [PlannedOfflineTranslation]
    let primaryOutputRole: OfflineTranslationOutputRole

    static func make(context: LanguageContext) -> OfflineTranslationPlan? {
        guard let native = OfflineTranslationLanguage(context.nativeLanguage),
              let learning = OfflineTranslationLanguage(context.learningLanguage),
              native != learning else { return nil }
        let toLearning = PlannedOfflineTranslation(
            outputRole: .learningVersion,
            pair: OfflineTranslationPair(source: native, target: learning)
        )
        let toNative = PlannedOfflineTranslation(
            outputRole: .nativeVersion,
            pair: OfflineTranslationPair(source: learning, target: native)
        )
        switch context.queryRelation {
        case .native:
            return OfflineTranslationPlan(
                kind: .nativeToLearning, operations: [toLearning],
                primaryOutputRole: .learningVersion
            )
        case .learning:
            return OfflineTranslationPlan(
                kind: .learningToNative, operations: [toNative],
                primaryOutputRole: .nativeVersion
            )
        case .mixedNativeDominant:
            return OfflineTranslationPlan(
                kind: .mixedBidirectional, operations: [toLearning, toNative],
                primaryOutputRole: .learningVersion
            )
        case .mixedLearningDominant:
            return OfflineTranslationPlan(
                kind: .mixedBidirectional, operations: [toLearning, toNative],
                primaryOutputRole: .nativeVersion
            )
        case .unsupported:
            return OfflineTranslationPlan(
                kind: .unknownBidirectional, operations: [toLearning, toNative],
                primaryOutputRole: .learningVersion
            )
        }
    }
}

extension OfflineTranslationLanguage {
    init?(_ language: LanguageIdentifier) {
        switch language {
        case .english: self = .english
        case .simplifiedChinese: self = .simplifiedChinese
        case .german, .japanese: return nil
        }
    }
}

enum OfflineTranslationAvailability: Equatable, Sendable {
    case installed
    case supportedNeedsDownload
    case unsupported
    case checking
    case temporarilyUnavailable
}

struct AppleTranslationActionPresentation: Equatable, Sendable {
    let title: String
    let isEnabled: Bool

    static func make(availability: OfflineTranslationAvailability,
                     isLongText: Bool,
                     pair: OfflineTranslationPair = OfflineTranslationPair(
                        source: .simplifiedChinese, target: .english
                     )) -> AppleTranslationActionPresentation {
        let direction = "\(pair.source.languageIdentifier.chineseName) → " +
            pair.target.languageIdentifier.chineseName
        let languagePair = "\(pair.source.languageIdentifier.chineseName) ⇄ " +
            pair.target.languageIdentifier.chineseName
        switch availability {
        case .installed:
            return AppleTranslationActionPresentation(
                title: isLongText
                    ? "进行基础离线翻译（\(direction)）"
                    : "Apple 系统离线翻译（\(direction)）",
                isEnabled: true
            )
        case .supportedNeedsDownload:
            return AppleTranslationActionPresentation(
                title: "准备 Apple 离线翻译语言包（\(languagePair)）",
                isEnabled: true
            )
        case .unsupported, .temporarilyUnavailable:
            return AppleTranslationActionPresentation(
                title: "Apple 系统翻译暂不可用", isEnabled: false
            )
        case .checking:
            return AppleTranslationActionPresentation(
                title: "正在检查系统语言包…", isEnabled: false
            )
        }
    }
}

struct OfflineTranslationRequest: Equatable, Sendable {
    let id: String
    let sourceText: String
    let pair: OfflineTranslationPair
    let outputRole: OfflineTranslationOutputRole?

    init(id: String = UUID().uuidString, sourceText: String,
         pair: OfflineTranslationPair,
         outputRole: OfflineTranslationOutputRole? = nil) {
        self.id = id
        self.sourceText = sourceText
        self.pair = pair
        self.outputRole = outputRole
    }
}

struct OfflineTranslationResponse: Equatable, Sendable {
    let id: String
    let sourceText: String
    let translatedText: String
    let pair: OfflineTranslationPair
    let source: OfflineTranslationSource
    let outputRole: OfflineTranslationOutputRole?

    init(id: String, sourceText: String, translatedText: String,
         pair: OfflineTranslationPair,
         source: OfflineTranslationSource = .appleSystem,
         outputRole: OfflineTranslationOutputRole? = nil) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.pair = pair
        self.source = source
        self.outputRole = outputRole
    }
}

enum OfflineTranslationSource: String, Codable, Equatable, Sendable {
    case appleSystem
    case localBasic
    case localDictionaryCandidate
    case sourceBilingualGlossary

    var displayName: String {
        switch self {
        case .appleSystem: return "Apple 系统翻译"
        case .localBasic: return "本地基础翻译"
        case .localDictionaryCandidate: return "本地词典候选"
        case .sourceBilingualGlossary: return "原文已有双语词义"
        }
    }
}

enum OfflineTranslationStage: String, Equatable, Sendable {
    case availabilityCheck
    case sessionCreation
    case preparation
    case translation
    case fallback
    case completion
}

struct OfflineTranslationDeadlinePolicy: Equatable, Sendable {
    let availability: Duration
    let preparation: Duration
    let translation: Duration
    let fallback: Duration
    let maximumTranslation: Duration
    let coldInstalledGrace: Duration

    init(availability: Duration, preparation: Duration,
         translation: Duration, fallback: Duration,
         maximumTranslation: Duration? = nil,
         coldInstalledGrace: Duration = .seconds(6)) {
        self.availability = availability
        self.preparation = preparation
        self.translation = translation
        self.fallback = fallback
        self.maximumTranslation = max(translation, maximumTranslation ?? translation)
        self.coldInstalledGrace = max(.zero, coldInstalledGrace)
    }

    static let production = OfflineTranslationDeadlinePolicy(
        availability: .seconds(2), preparation: .seconds(8),
        translation: .seconds(4), fallback: .seconds(4),
        maximumTranslation: .seconds(18)
    )

    func translationBudget(characterCount: Int, sentenceCount: Int,
                           installed: Bool, coldSession: Bool) -> Duration {
        guard maximumTranslation > translation else { return translation }
        var value = translation
        // Installed first-use sessions pay a measurable framework/model warm-up cost. Six
        // seconds lets a 5–8 second cold call finish while retaining a small warm short-query
        // budget. Unknown state is treated conservatively as cold, never as an infinite wait.
        if coldSession && installed { value += coldInstalledGrace }
        else if coldSession { value += .seconds(3) }
        let boundedCharacters = min(max(0, characterCount), 2_000)
        let boundedSentences = min(max(1, sentenceCount), 16)
        let lengthGrace = min(6, boundedCharacters / 80)
        let sentenceGrace = min(3, max(0, boundedSentences - 1))
        value += .seconds(lengthGrace + sentenceGrace)
        return min(value, maximumTranslation)
    }

    func coldRetryBudget(after initialBudget: Duration,
                         installed: Bool, coldSession: Bool) -> Duration? {
        guard installed, coldSession, initialBudget < maximumTranslation else { return nil }
        let remaining = maximumTranslation - initialBudget
        return remaining > .zero ? remaining : nil
    }
}

struct OfflineTranslationDecision: Equatable, Sendable {
    let stage: OfflineTranslationStage
    let source: OfflineTranslationSource?
    let usedFallback: Bool
    let failure: OfflineTranslationError?
}

enum OfflineTranslationError: LocalizedError, Equatable, Sendable {
    case cancelled
    case emptyInput
    case unsupportedLanguagePair
    case languagePackRequired
    case hostUnavailable
    case hostEnded
    case preparationIncomplete
    case deadlineExceeded(OfflineTranslationStage)
    case invalidResponse
    case noOpTranslation
    case wrongTargetLanguage
    case systemFailure

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "本 App 已停止当前系统翻译操作；若正在准备语言资源，macOS 可能仍在后台继续。"
        case .emptyInput: return "没有可翻译的文本。"
        case .unsupportedLanguagePair: return "系统不支持该语言方向。"
        case .languagePackRequired: return "需要先准备 Apple 系统离线语言包。"
        case .hostUnavailable: return "系统翻译承载视图当前不可用。"
        case .hostEnded: return "系统翻译承载视图已结束，请重试。"
        case .preparationIncomplete:
            return "macOS 已返回语言包准备流程，但语言资源仍未安装；请查看系统提示后重试。"
        case .deadlineExceeded(let stage):
            if stage == .translation {
                return "Apple 系统离线翻译本次未在等待时间内完成。"
            }
            return "系统离线翻译在“\(stage.rawValue)”阶段超过本次等待时限。"
        case .invalidResponse: return "系统翻译返回的数据无法对应原句。"
        case .noOpTranslation:
            return "Apple 系统离线翻译本次未得到有效译文，可重新尝试。"
        case .wrongTargetLanguage:
            return "Apple 系统离线翻译本次未返回目标语言译文，可重新尝试。"
        case .systemFailure: return "系统翻译暂时失败。"
        }
    }
}

enum TranslationSimilarityBucket: String, Equatable, Sendable {
    case low
    case medium
    case high
}

struct TranslationResultValidation: Equatable, Sendable {
    let resultLanguage: LanguageIdentifier?
    let noOpTranslation: Bool
    let targetLanguagePassthrough: Bool
    let wrongTargetLanguage: Bool
    let similarityBucket: TranslationSimilarityBucket
}

/// Rejects framework responses that merely echo a meaningful source sentence. Proper names and
/// product identifiers may remain unchanged inside an otherwise valid target-language result.
enum TranslationResultValidator {
    static func validate(source: String, result: String,
                         pair: OfflineTranslationPair) -> TranslationResultValidation {
        let sourceValue = canonical(source)
        let resultValue = canonical(result)
        let sourceProfile = LanguageTextProfile.make(source)
        let targetValidation = TargetLanguageValidator.validate(
            result, targetLanguage: pair.target.languageIdentifier
        )
        let similarity = similarityBucket(sourceValue, resultValue)
        let meaningfulSource = sourceProfile.hanCharacterCount > 0 ||
            sourceProfile.latinTokenCount > 0
        let exactEcho = !resultValue.isEmpty && sourceValue == resultValue
        // A mixed bidirectional plan deliberately sends every segment to both target versions.
        // Apple may echo a segment that is already effectively in that target language. Keep this
        // exception deliberately narrow: the reported failure was the Chinese version of a
        // Chinese-dominant segment containing only a few product/technical tokens. An ordinary
        // untranslated English clause must not be accepted merely because surrounding Chinese is
        // longer. The English-side exception is stricter and accepts only a purely English row.
        let targetPassthrough: Bool
        switch pair.target {
        case .simplifiedChinese:
            let bilingualGlossary = BilingualGlossaryDetector.isStructuredGlossary(source)
            targetPassthrough = exactEcho && (
                bilingualGlossary || isStandaloneTechnicalIdentifier(source) || (
                    targetValidation.isTargetLanguage &&
                    sourceProfile.nativeCoverageBucket == .high &&
                    sourceProfile.learningCoverageBucket == .low
                )
            )
        case .english:
            targetPassthrough = exactEcho && targetValidation.isTargetLanguage &&
                sourceProfile.learningCoverageBucket == .high &&
                sourceProfile.nativeCoverageBucket == .none
        }
        let noOp = meaningfulSource && exactEcho && !targetPassthrough
        let wrongTarget = meaningfulSource && !targetValidation.isTargetLanguage &&
            !targetPassthrough
        return TranslationResultValidation(
            resultLanguage: targetValidation.resultLanguage,
            noOpTranslation: noOp,
            targetLanguagePassthrough: targetPassthrough,
            wrongTargetLanguage: wrongTarget,
            similarityBucket: similarity
        )
    }

    private static func isStandaloneTechnicalIdentifier(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = QueryIntentClassifier.englishWords(in: trimmed)
        guard words.count == 1, let word = words.first,
              trimmed.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
              }) else { return false }
        let letters = word.filter(\.isLetter)
        let allUppercase = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
        let internalUppercase = word.dropFirst().contains(where: \.isUppercase)
        let containsDigit = word.contains(where: \.isNumber)
        return allUppercase || internalUppercase || containsDigit
    }

    private static func canonical(_ value: String) -> String {
        String(value.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || QueryIntentClassifier.isCJK($0)
        })
    }

    private static func similarityBucket(_ source: String,
                                         _ result: String) -> TranslationSimilarityBucket {
        guard !source.isEmpty, !result.isEmpty else { return .low }
        if source == result { return .high }
        let sourceSet = Set(source.prefix(2_000))
        let resultSet = Set(result.prefix(2_000))
        let union = sourceSet.union(resultSet).count
        guard union > 0 else { return .low }
        let overlap = Double(sourceSet.intersection(resultSet).count) / Double(union)
        if overlap >= 0.85 { return .high }
        if overlap >= 0.45 { return .medium }
        return .low
    }
}

enum LocalHeavyWorkKind: String, Equatable, Sendable {
    case reverseIndex
    case appleLanguagePreparation
    case resourceInstallationFinalization
}

enum LocalHeavyWorkError: LocalizedError, Equatable, Sendable {
    case cancelled

    var errorDescription: String? {
        "本机后台任务已取消。"
    }
}

struct LocalHeavyWorkQueueSnapshot: Equatable, Sendable {
    let active: LocalHeavyWorkKind?
    let waiting: [LocalHeavyWorkKind]
}

/// Serializes only CPU/disk-heavy local work. Ordinary dictionary queries and AI requests do not
/// acquire this permit. Waiting uses continuations, never polling or a main-thread semaphore.
actor LocalHeavyWorkCoordinator {
    struct Permit: Sendable {
        fileprivate let id: UUID
        let kind: LocalHeavyWorkKind
        fileprivate let coordinator: LocalHeavyWorkCoordinator

        func release() async {
            await coordinator.release(id: id)
        }
    }

    private struct Waiter {
        let id: UUID
        let kind: LocalHeavyWorkKind
        let continuation: CheckedContinuation<Permit, Error>
    }

    private var active: (id: UUID, kind: LocalHeavyWorkKind)?
    private var waiters: [Waiter] = []

    func acquire(_ kind: LocalHeavyWorkKind) async throws -> Permit {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, kind: kind, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiting(id: id) }
        }
    }

    func snapshot() -> LocalHeavyWorkQueueSnapshot {
        LocalHeavyWorkQueueSnapshot(
            active: active?.kind,
            waiting: waiters.map(\.kind)
        )
    }

    func cancelAllWaiting() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: LocalHeavyWorkError.cancelled)
        }
    }

    private func enqueue(
        id: UUID,
        kind: LocalHeavyWorkKind,
        continuation: CheckedContinuation<Permit, Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: LocalHeavyWorkError.cancelled)
            return
        }
        guard active != nil else {
            active = (id, kind)
            continuation.resume(returning: Permit(id: id, kind: kind, coordinator: self))
            return
        }
        waiters.append(Waiter(id: id, kind: kind, continuation: continuation))
    }

    private func cancelWaiting(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: LocalHeavyWorkError.cancelled)
    }

    private func release(id: UUID) {
        guard active?.id == id else { return }
        active = nil
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        active = (next.id, next.kind)
        next.continuation.resume(returning: Permit(
            id: next.id, kind: next.kind, coordinator: self
        ))
    }
}

protocol OfflineTranslationEngine: Sendable {
    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability
    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse]
    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws
}

/// Engines backed by a session-oriented framework use this hook after a bounded operation
/// fails. Recovery is operation-scoped: it may invalidate the failed session/generation, but it
/// must not mark the language pair or future operations permanently unavailable.
protocol OfflineTranslationOperationRecovering: Sendable {
    func recoverAfterOperationFailure(_ error: OfflineTranslationError) async
}

/// Future model packs must pass license, redistribution, signature, size and performance review.
/// No implementation is bundled by this release.
protocol ModelPackTranslationEngine: OfflineTranslationEngine {
    var modelPackIdentifier: String { get }
    var modelPackVersion: String { get }
}

/// Keeps engine construction off the ordinary English word path. The factory is first evaluated
/// only after a sentence/paragraph or an explicit Chinese fallback requests system translation.
actor OfflineTranslationCoordinator {
    typealias EngineFactory = @Sendable () async throws -> any OfflineTranslationEngine

    private let factory: EngineFactory
    private let fallbackFactory: EngineFactory?
    private let heavyWorkCoordinator: LocalHeavyWorkCoordinator?
    private let deadlinePolicy: OfflineTranslationDeadlinePolicy
    private var engine: (any OfflineTranslationEngine)?
    private var fallbackEngine: (any OfflineTranslationEngine)?
    private var maximumConcurrentTasks: Int
    private var availabilityByPair: [OfflineTranslationPair: OfflineTranslationAvailability] = [:]
    private var completedTranslationPairs: Set<OfflineTranslationPair> = []
    private(set) var lastDecision: OfflineTranslationDecision?

    init(maximumConcurrentTasks: Int = 2,
         heavyWorkCoordinator: LocalHeavyWorkCoordinator? = nil,
         deadlinePolicy: OfflineTranslationDeadlinePolicy = .production,
         fallbackFactory: EngineFactory? = nil,
         factory: @escaping EngineFactory) {
        self.maximumConcurrentTasks = max(1, min(maximumConcurrentTasks, 4))
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.deadlinePolicy = deadlinePolicy
        self.fallbackFactory = fallbackFactory
        self.factory = factory
    }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability {
        if availabilityByPair[pair] == .installed {
            ManualEvidenceRecorder.shared.record("availabilityResult", strings: [
                "systemAvailability": "installed",
                "serviceHealth": "ready",
                "typedReason": "processConfirmedInstalled"
            ])
            return .installed
        }
        ManualEvidenceRecorder.shared.record("availabilityCheckStarted", strings: [
            "queryLanguage": pair.source.rawValue,
            "targetLanguage": pair.target.rawValue,
            "operationState": "checking"
        ])
        do {
            let primary = try await loadEngine()
            let value = try await Self.withDeadline(
                deadlinePolicy.availability, stage: .availabilityCheck
            ) {
                await primary.availability(for: pair)
            }
            lastDecision = OfflineTranslationDecision(
                stage: .availabilityCheck, source: .appleSystem,
                usedFallback: false, failure: nil
            )
            availabilityByPair[pair] = value
            ManualEvidenceRecorder.shared.record("availabilityResult", strings: [
                "systemAvailability": Self.evidenceAvailability(value),
                "serviceHealth": "ready"
            ])
            return value
        } catch let error as OfflineTranslationError {
            lastDecision = OfflineTranslationDecision(
                stage: .availabilityCheck, source: nil,
                usedFallback: false, failure: error
            )
            let cached = availabilityByPair[pair]
            ManualEvidenceRecorder.shared.record("availabilityResult", strings: [
                "systemAvailability": cached == .installed ? "installed" : "unknown",
                "serviceHealth": "temporarilyRecovering",
                "typedReason": String(describing: error)
            ])
            return cached == .installed ? .installed : .temporarilyUnavailable
        } catch {
            let cached = availabilityByPair[pair]
            return cached == .installed ? .installed : .temporarilyUnavailable
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        try Task.checkCancellation()
        guard let heavyWorkCoordinator else {
            let primary = try await loadEngine()
            try await Self.withDeadline(deadlinePolicy.preparation, stage: .preparation) {
                try await primary.prepareLanguagePack(for: pair)
            }
            return
        }
        let permit: LocalHeavyWorkCoordinator.Permit
        do {
            permit = try await heavyWorkCoordinator.acquire(.appleLanguagePreparation)
        } catch {
            throw OfflineTranslationError.cancelled
        }
        do {
            try Task.checkCancellation()
            let primary = try await loadEngine()
            try await Self.withDeadline(deadlinePolicy.preparation, stage: .preparation) {
                try await primary.prepareLanguagePack(for: pair)
            }
            await permit.release()
        } catch {
            await permit.release()
            if error is CancellationError || error as? LocalHeavyWorkError == .cancelled {
                throw OfflineTranslationError.cancelled
            }
            throw error
        }
    }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        guard !requests.isEmpty else { return [] }
        try Task.checkCancellation()
        var resultByID: [String: OfflineTranslationResponse] = [:]
        var nextIndex = 0
        try await withThrowingTaskGroup(of: [OfflineTranslationResponse].self) { group in
            var activeTasks = 0
            func enqueue(_ index: Int) {
                let pair = requests[index].pair
                var end = index + 1
                while end < requests.count, requests[end].pair == pair,
                      end - index < 16 {
                    end += 1
                }
                let batch = Array(requests[index..<end])
                nextIndex = end
                group.addTask { try await self.translateBatch(batch) }
                activeTasks += 1
            }
            while nextIndex < requests.count, activeTasks < maximumConcurrentTasks {
                enqueue(nextIndex)
            }
            while let batch = try await group.next() {
                activeTasks -= 1
                for response in batch {
                    guard resultByID[response.id] == nil else {
                        throw OfflineTranslationError.invalidResponse
                    }
                    resultByID[response.id] = response
                }
                if nextIndex < requests.count { enqueue(nextIndex) }
            }
        }
        try Task.checkCancellation()
        guard resultByID.count == requests.count else {
            throw OfflineTranslationError.invalidResponse
        }
        return try requests.map {
            guard let response = resultByID[$0.id],
                  response.sourceText == $0.sourceText,
                  response.pair == $0.pair else {
                throw OfflineTranslationError.invalidResponse
            }
            return response
        }
    }

    private func translateBatch(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        let primary = try await loadEngine()
        let pair = requests[0].pair
        let installed = availabilityByPair[pair] == .installed
        let coldSession = !completedTranslationPairs.contains(pair)
        let characterCount = requests.reduce(0) { $0 + $1.sourceText.count }
        let sentenceCount = requests.reduce(0) {
            $0 + max(1, Self.sentenceCount(in: $1.sourceText))
        }
        let translationBudget = deadlinePolicy.translationBudget(
            characterCount: characterCount,
            sentenceCount: sentenceCount,
            installed: installed,
            coldSession: coldSession
        )
        do {
            let responses = try await Self.withDeadline(
                translationBudget, stage: .translation
            ) {
                try await primary.translate(requests)
            }
            let completed = try completedAppleResponses(responses, pair: pair)
            // The host owns no TranslationSession beyond the translationTask callback. Dropping
            // this lightweight wrapper ensures the next operation crosses a fresh service
            // boundary while retaining the independent installed-availability fact.
            engine = nil
            return completed
        } catch let error as OfflineTranslationError {
            if error == .noOpTranslation || error == .wrongTargetLanguage {
                return try await handlePrimaryFailure(error, requests: requests)
            }
            await recoverPrimaryEngine(primary, after: error)
            if error == .deadlineExceeded(.translation),
               let retryBudget = deadlinePolicy.coldRetryBudget(
                after: translationBudget, installed: installed, coldSession: coldSession
               ) {
                do {
                    // The first deadline invalidates the TranslationSession. A single bounded
                    // retry therefore creates a fresh session and can use model warm-up work that
                    // macOS completed in the background, while the original overall cap remains.
                    let retryEngine = try await loadEngine()
                    let responses = try await Self.withDeadline(
                        retryBudget, stage: .translation
                    ) {
                        try await retryEngine.translate(requests)
                    }
                    return try completedAppleResponses(responses, pair: pair)
                } catch let retryError as OfflineTranslationError {
                    if let retryEngine = engine {
                        await recoverPrimaryEngine(retryEngine, after: retryError)
                    }
                    return try await handlePrimaryFailure(
                        retryError, requests: requests
                    )
                } catch is CancellationError {
                    if let retryEngine = engine {
                        await recoverPrimaryEngine(retryEngine, after: .cancelled)
                    }
                    throw OfflineTranslationError.cancelled
                } catch {
                    if let retryEngine = engine {
                        await recoverPrimaryEngine(retryEngine, after: .systemFailure)
                    }
                    return try await handlePrimaryFailure(
                        .systemFailure, requests: requests
                    )
                }
            }
            return try await handlePrimaryFailure(error, requests: requests)
        } catch is CancellationError {
            await recoverPrimaryEngine(primary, after: .cancelled)
            throw OfflineTranslationError.cancelled
        } catch {
            await recoverPrimaryEngine(primary, after: .systemFailure)
            return try await handlePrimaryFailure(.systemFailure, requests: requests)
        }
    }

    private func recoverPrimaryEngine(
        _ primary: any OfflineTranslationEngine,
        after error: OfflineTranslationError
    ) async {
        if let recoverable = primary as? any OfflineTranslationOperationRecovering {
            await recoverable.recoverAfterOperationFailure(error)
        }
        // The factory is intentionally lazy. Dropping only this wrapper forces the next attempt
        // through a fresh operation boundary without changing installed availability state.
        engine = nil
    }

    private func completedAppleResponses(
        _ responses: [OfflineTranslationResponse], pair: OfflineTranslationPair
    ) throws -> [OfflineTranslationResponse] {
        for response in responses {
            let validation = TranslationResultValidator.validate(
                source: response.sourceText, result: response.translatedText, pair: pair
            )
            ManualEvidenceRecorder.shared.record(
                "translationResultValidated",
                strings: [
                    "translationSourceLanguage": pair.source.rawValue,
                    "translationTargetLanguage": pair.target.rawValue,
                    "resultLanguage": validation.resultLanguage?.rawValue ?? "undetermined",
                    "offlineOutputRole": response.outputRole?.rawValue ?? "unspecified",
                    "sourceResultSimilarityBucket": validation.similarityBucket.rawValue,
                    "resultKind": validation.noOpTranslation ||
                        validation.wrongTargetLanguage ? "failure" : "success"
                ],
                booleans: [
                    "noOpTranslation": validation.noOpTranslation,
                    "targetLanguagePassthrough": validation.targetLanguagePassthrough,
                    "wrongTargetLanguage": validation.wrongTargetLanguage
                ]
            )
            if validation.noOpTranslation { throw OfflineTranslationError.noOpTranslation }
            if validation.wrongTargetLanguage {
                throw OfflineTranslationError.wrongTargetLanguage
            }
        }
        completedTranslationPairs.insert(pair)
        availabilityByPair[pair] = .installed
        lastDecision = OfflineTranslationDecision(
            stage: .completion, source: .appleSystem,
            usedFallback: false, failure: nil
        )
        return responses.map {
            OfflineTranslationResponse(
                id: $0.id, sourceText: $0.sourceText,
                translatedText: $0.translatedText, pair: $0.pair,
                source: .appleSystem, outputRole: $0.outputRole
            )
        }
    }

    private static func evidenceAvailability(
        _ value: OfflineTranslationAvailability
    ) -> String {
        switch value {
        case .installed: return "installed"
        case .supportedNeedsDownload: return "downloadable"
        case .unsupported: return "unsupported"
        case .checking: return "checking"
        case .temporarilyUnavailable: return "unknown"
        }
    }

    private func handlePrimaryFailure(
        _ error: OfflineTranslationError,
        requests: [OfflineTranslationRequest]
    ) async throws -> [OfflineTranslationResponse] {
            lastDecision = OfflineTranslationDecision(
                stage: .translation, source: nil,
                usedFallback: false, failure: error
            )
            guard error != .cancelled, Self.shouldUseFallback(after: error),
                  fallbackFactory != nil else { throw error }
            return try await translateWithFallback(requests, primaryFailure: error)
    }

    private func translateWithFallback(
        _ requests: [OfflineTranslationRequest],
        primaryFailure: OfflineTranslationError
    ) async throws -> [OfflineTranslationResponse] {
        let fallback = try await loadFallbackEngine()
        do {
            let responses = try await Self.withDeadline(
                deadlinePolicy.fallback, stage: .fallback
            ) {
                try await fallback.translate(requests)
            }
            lastDecision = OfflineTranslationDecision(
                stage: .completion, source: .localBasic,
                usedFallback: true, failure: primaryFailure
            )
            return responses.map {
                OfflineTranslationResponse(
                    id: $0.id, sourceText: $0.sourceText,
                    translatedText: $0.translatedText, pair: $0.pair,
                    source: $0.source == .localDictionaryCandidate
                        ? .localDictionaryCandidate : .localBasic,
                    outputRole: $0.outputRole
                )
            }
        } catch is CancellationError {
            throw OfflineTranslationError.cancelled
        } catch let error as OfflineTranslationError {
            lastDecision = OfflineTranslationDecision(
                stage: .fallback, source: nil, usedFallback: true, failure: error
            )
            throw error
        } catch {
            lastDecision = OfflineTranslationDecision(
                stage: .fallback, source: nil, usedFallback: true,
                failure: .systemFailure
            )
            throw OfflineTranslationError.systemFailure
        }
    }

    private func loadEngine() async throws -> any OfflineTranslationEngine {
        if let engine { return engine }
        let created = try await factory()
        engine = created
        return created
    }

    private func loadFallbackEngine() async throws -> any OfflineTranslationEngine {
        if let fallbackEngine { return fallbackEngine }
        guard let fallbackFactory else { throw OfflineTranslationError.systemFailure }
        let created = try await fallbackFactory()
        fallbackEngine = created
        return created
    }

    private static func shouldUseFallback(after error: OfflineTranslationError) -> Bool {
        switch error {
        case .emptyInput, .cancelled, .noOpTranslation, .wrongTargetLanguage: return false
        case .unsupportedLanguagePair, .languagePackRequired, .hostUnavailable, .hostEnded,
             .preparationIncomplete, .invalidResponse, .systemFailure, .deadlineExceeded:
            return true
        }
    }

    private static func sentenceCount(in value: String) -> Int {
        let separators = CharacterSet(charactersIn: ".!?。！？\n")
        return value.unicodeScalars.reduce(into: 0) { count, scalar in
            if separators.contains(scalar) { count += 1 }
        }
    }

    private static func withDeadline<Value: Sendable>(
        _ duration: Duration,
        stage: OfflineTranslationStage,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw OfflineTranslationError.deadlineExceeded(stage)
            }
            guard let first = try await group.next() else {
                throw OfflineTranslationError.systemFailure
            }
            group.cancelAll()
            return first
        }
    }
}

struct LocalBasicTranslationLookup: Sendable {
    let englishToChinese: @Sendable (String) async -> String?
    let chineseToEnglish: @Sendable (String) async -> String?
}

/// A deliberately modest, network-free fallback. It prefers local phrases and lemmas, preserves
/// unknown text, and never claims NMT quality. The engine is bounded per sentence and cancellable.
actor LocalBasicTranslationEngine: OfflineTranslationEngine {
    static let maximumUnitsPerRequest = 192
    static let maximumLookupsPerRequest = 96
    static let maximumPhraseUnits = 6

    private let lookup: LocalBasicTranslationLookup

    init(lookup: LocalBasicTranslationLookup) {
        self.lookup = lookup
    }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        var output: [OfflineTranslationResponse] = []
        output.reserveCapacity(requests.count)
        for request in requests {
            try Task.checkCancellation()
            let translated: (text: String, dictionaryCandidate: Bool)
            switch request.pair.source {
            case .english:
                translated = try await translateEnglish(request.sourceText)
            case .simplifiedChinese:
                translated = try await translateChinese(request.sourceText)
            }
            let normalized = translated.text.trimmingCharacters(in: .whitespacesAndNewlines)
            output.append(OfflineTranslationResponse(
                id: request.id,
                sourceText: request.sourceText,
                translatedText: normalized.isEmpty ? request.sourceText : normalized,
                pair: request.pair,
                source: translated.dictionaryCandidate
                    ? .localDictionaryCandidate : .localBasic,
                outputRole: request.outputRole
            ))
        }
        return output
    }

    private func translateEnglish(_ source: String) async throws
        -> (text: String, dictionaryCandidate: Bool) {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = source
        var words: [String] = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            if words.count < Self.maximumUnitsPerRequest {
                words.append(String(source[range]))
            }
            return words.count < Self.maximumUnitsPerRequest
        }
        guard !words.isEmpty else { return (source, false) }
        var result: [String] = []
        var index = 0
        var lookups = 0
        var dictionaryHits = 0
        while index < words.count {
            try Task.checkCancellation()
            var chosen: (text: String, length: Int, dictionary: Bool)?
            for length in stride(from: min(Self.maximumPhraseUnits, words.count - index),
                                 through: 1, by: -1) {
                let raw = words[index..<(index + length)].joined(separator: " ")
                let key = raw.lowercased(with: Locale(identifier: "en_US_POSIX"))
                if let rule = Self.englishRules[key] {
                    chosen = (rule, length, false)
                    break
                }
                guard lookups < Self.maximumLookupsPerRequest else { continue }
                lookups += 1
                if let value = await lookup.englishToChinese(key), !value.isEmpty {
                    chosen = (value, length, true)
                    break
                }
                if length == 1, let lemma = Self.simpleEnglishLemma(key), lemma != key,
                   lookups < Self.maximumLookupsPerRequest {
                    lookups += 1
                    if let value = await lookup.englishToChinese(lemma), !value.isEmpty {
                        chosen = (value, 1, true)
                        break
                    }
                }
            }
            if let chosen {
                result.append(chosen.text)
                index += chosen.length
                if chosen.dictionary { dictionaryHits += 1 }
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return (Self.basicJoin(result, terminalFrom: source), dictionaryHits > 0)
    }

    private func translateChinese(_ source: String) async throws
        -> (text: String, dictionaryCandidate: Bool) {
        let units = Array(source.prefix(Self.maximumUnitsPerRequest))
        guard !units.isEmpty else { return (source, false) }
        var result: [String] = []
        var index = 0
        var lookups = 0
        var dictionaryHits = 0
        while index < units.count {
            try Task.checkCancellation()
            let character = units[index]
            if character.isWhitespace || Self.isPunctuation(character) {
                result.append(String(character))
                index += 1
                continue
            }
            var chosen: (text: String, length: Int, dictionary: Bool)?
            let maximum = min(Self.maximumPhraseUnits, units.count - index)
            for length in stride(from: maximum, through: 1, by: -1) {
                let raw = String(units[index..<(index + length)])
                guard raw.unicodeScalars.allSatisfy(Self.isCJK) else { continue }
                if let rule = Self.chineseRules[raw] {
                    chosen = (rule, length, false)
                    break
                }
                guard lookups < Self.maximumLookupsPerRequest else { continue }
                lookups += 1
                if let value = await lookup.chineseToEnglish(raw), !value.isEmpty {
                    chosen = (value, length, true)
                    break
                }
            }
            if let chosen {
                result.append(chosen.text)
                index += chosen.length
                if chosen.dictionary { dictionaryHits += 1 }
            } else {
                result.append(String(character))
                index += 1
            }
        }
        return (Self.basicJoin(result, terminalFrom: source), dictionaryHits > 0)
    }

    private static func basicJoin(_ values: [String], terminalFrom source: String) -> String {
        var output = values.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
        for punctuation in [" .", " ,", " !", " ?", " ;", " :", " 。", " ，", " ！", " ？"] {
            output = output.replacingOccurrences(of: punctuation,
                                                  with: String(punctuation.dropFirst()))
        }
        if let terminal = source.last, isPunctuation(terminal), output.last != terminal {
            output.append(terminal)
        }
        return output
    }

    private static func simpleEnglishLemma(_ value: String) -> String? {
        if value.count > 5, value.hasSuffix("ies") { return String(value.dropLast(3)) + "y" }
        if value.count > 5, value.hasSuffix("ing") { return String(value.dropLast(3)) }
        if value.count > 4, value.hasSuffix("ed") { return String(value.dropLast(2)) }
        if value.count > 4, value.hasSuffix("s") { return String(value.dropLast()) }
        return value
    }

    private static func isPunctuation(_ value: Character) -> Bool {
        value.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
    }

    private static let englishRules: [String: String] = [
        "the": "该", "a": "一个", "an": "一个", "is": "是", "are": "是",
        "was": "曾是", "were": "曾是", "and": "并且", "or": "或者", "but": "但是",
        "because": "因为", "therefore": "因此", "with": "与", "without": "没有",
        "in": "在", "on": "在", "to": "到", "from": "从", "of": "的",
        "can": "可以", "may": "可能", "must": "必须", "should": "应该",
        "as a result": "因此", "in order to": "为了", "rather than": "而不是",
        "not only": "不仅", "but also": "而且"
    ]

    private static let chineseRules: [String: String] = [
        "的": "of", "是": "is", "在": "in", "和": "and", "与": "and",
        "或": "or", "但是": "but", "因为": "because", "因此": "therefore",
        "可以": "can", "可能": "may", "必须": "must", "应该": "should",
        "为了": "in order to", "而不是": "rather than", "不仅": "not only",
        "而且": "but also", "没有": "without", "一个": "a"
    ]
}
