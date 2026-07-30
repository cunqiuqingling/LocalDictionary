import Foundation

enum OfflineTranslationLanguage: String, Codable, Equatable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
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

enum OfflineTranslationAvailability: Equatable, Sendable {
    case installed
    case supportedNeedsDownload
    case unsupported
    case checking
    case temporarilyUnavailable
}

struct OfflineTranslationRequest: Equatable, Sendable {
    let id: String
    let sourceText: String
    let pair: OfflineTranslationPair

    init(id: String = UUID().uuidString, sourceText: String,
         pair: OfflineTranslationPair) {
        self.id = id
        self.sourceText = sourceText
        self.pair = pair
    }
}

struct OfflineTranslationResponse: Equatable, Sendable {
    let id: String
    let sourceText: String
    let translatedText: String
    let pair: OfflineTranslationPair
}

enum OfflineTranslationError: LocalizedError, Equatable, Sendable {
    case cancelled
    case emptyInput
    case unsupportedLanguagePair
    case languagePackRequired
    case hostUnavailable
    case hostEnded
    case invalidResponse
    case systemFailure

    var errorDescription: String? {
        switch self {
        case .cancelled: return "系统离线翻译已取消。"
        case .emptyInput: return "没有可翻译的文本。"
        case .unsupportedLanguagePair: return "系统不支持该语言方向。"
        case .languagePackRequired: return "需要先准备 Apple 系统离线语言包。"
        case .hostUnavailable: return "系统翻译承载视图当前不可用。"
        case .hostEnded: return "系统翻译承载视图已结束，请重试。"
        case .invalidResponse: return "系统翻译返回的数据无法对应原句。"
        case .systemFailure: return "系统翻译暂时失败。"
        }
    }
}

protocol OfflineTranslationEngine: Sendable {
    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability
    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse]
    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws
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
    private var engine: (any OfflineTranslationEngine)?
    private var maximumConcurrentTasks: Int

    init(maximumConcurrentTasks: Int = 2, factory: @escaping EngineFactory) {
        self.maximumConcurrentTasks = max(1, min(maximumConcurrentTasks, 4))
        self.factory = factory
    }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability {
        do {
            return try await loadEngine().availability(for: pair)
        } catch {
            return .temporarilyUnavailable
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        try Task.checkCancellation()
        try await loadEngine().prepareLanguagePack(for: pair)
    }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        guard !requests.isEmpty else { return [] }
        try Task.checkCancellation()
        let engine = try await loadEngine()
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
                group.addTask { try await engine.translate(batch) }
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

    private func loadEngine() async throws -> any OfflineTranslationEngine {
        if let engine { return engine }
        let created = try await factory()
        engine = created
        return created
    }
}
