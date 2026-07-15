import Foundation
import SQLite3

struct AICachedExplanation: Sendable {
    let explanation: AIExplanation
    let providerDisplayName: String
    let model: String
    let createdAt: Date
}

struct AICachedSentenceAnalysis: Sendable {
    let analysis: AISentenceAnalysis
    let providerDisplayName: String
    let model: String
    let createdAt: Date
}

struct AICachedInlineWordQuick: Sendable {
    let result: InlineWordQuickAIResult
    let providerDisplayName: String
    let model: String
}

struct AICachedInlineSentenceQuick: Sendable {
    let result: InlineSentenceQuickAIResult
    let providerDisplayName: String
    let model: String
}

enum AICacheError: LocalizedError {
    case unavailable

    var errorDescription: String? { "AI 缓存暂不可用。" }
}

final class AIExplanationCache {
    static let maximumEntries = 256
    static let wordResponseSchemaVersion = 2
    static let sentenceResponseSchemaVersion = 1
    static let inlineResponseSchemaVersion = 1

    let databaseURL: URL
    private let queue = DispatchQueue(label: "LocalDictionary.AICache", qos: .utility)

    init(databaseURL: URL = AIExplanationCache.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("LocalDictionary/AI", isDirectory: true)
            .appendingPathComponent("ai-cache.sqlite", isDirectory: false)
    }

    func value(for query: String,
               configuration: AIProviderConfiguration) async throws -> AICachedExplanation? {
        try await perform { database in
            let key = Self.cacheKey(query: query, configuration: configuration)
            let sql = """
            SELECT response_json, provider_name, model, created_at
            FROM ai_explanation_cache WHERE cache_key = ? LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AICacheError.unavailable
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(key, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: length)
            guard let explanation = try? JSONDecoder().decode(AIExplanation.self, from: data),
                  let validated = try? explanation.validated(fallbackHeadword: query) else {
                try Self.delete(key: key, database: database)
                return nil
            }
            let provider = Self.text(statement, column: 1)
            let model = Self.text(statement, column: 2)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            return AICachedExplanation(explanation: validated,
                                       providerDisplayName: provider,
                                       model: model,
                                       createdAt: createdAt)
        }
    }

    func store(_ explanation: AIExplanation,
               query: String,
               configuration: AIProviderConfiguration) async throws {
        let validated = try explanation.validated(fallbackHeadword: query)
        let data = try JSONEncoder().encode(validated)
        try await perform { database in
            let sql = """
            INSERT OR REPLACE INTO ai_explanation_cache
            (cache_key, response_json, created_at, provider_name, model, prompt_version)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AICacheError.unavailable
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(Self.cacheKey(query: query, configuration: configuration),
                      to: statement, at: 1)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            Self.bind(configuration.providerDisplayName, to: statement, at: 4)
            Self.bind(configuration.model, to: statement, at: 5)
            sqlite3_bind_int(statement, 6, Int32(aiDictionaryPromptVersion))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AICacheError.unavailable
            }
            try Self.trim(database)
        }
    }

    func sentenceValue(for sentence: String,
                       configuration: AIProviderConfiguration) async throws
        -> AICachedSentenceAnalysis? {
        try await perform { database in
            let key = Self.sentenceCacheKey(sentence: sentence, configuration: configuration)
            let sql = """
            SELECT response_json, provider_name, model, created_at
            FROM ai_explanation_cache WHERE cache_key = ? LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AICacheError.unavailable
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(key, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: length)
            guard let decoded = try? JSONDecoder().decode(AISentenceAnalysis.self, from: data),
                  let validated = try? decoded.validated(expectedSourceText: sentence) else {
                try Self.delete(key: key, database: database)
                return nil
            }
            return AICachedSentenceAnalysis(
                analysis: validated,
                providerDisplayName: Self.text(statement, column: 1),
                model: Self.text(statement, column: 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        }
    }

    func storeSentence(_ analysis: AISentenceAnalysis,
                       sentence: String,
                       configuration: AIProviderConfiguration) async throws {
        let validated = try analysis.validated(expectedSourceText: sentence)
        let data = try JSONEncoder().encode(validated)
        try await perform { database in
            let sql = """
            INSERT OR REPLACE INTO ai_explanation_cache
            (cache_key, response_json, created_at, provider_name, model, prompt_version)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AICacheError.unavailable
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(Self.sentenceCacheKey(sentence: sentence, configuration: configuration),
                      to: statement, at: 1)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            Self.bind(configuration.providerDisplayName, to: statement, at: 4)
            Self.bind(configuration.model, to: statement, at: 5)
            sqlite3_bind_int(statement, 6, Int32(aiSentencePromptVersion))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AICacheError.unavailable
            }
            try Self.trim(database)
        }
    }

    func inlineWordQuickValue(for query: String,
                              configuration: AIProviderConfiguration) async throws
        -> AICachedInlineWordQuick? {
        try await decodedInlineValue(for: query, intent: .inlineWordQuick,
                                     configuration: configuration) { data in
            guard let decoded = try? JSONDecoder().decode(InlineWordQuickAIResult.self,
                                                          from: data),
                  let validated = try? decoded.validated() else { return nil }
            return validated
        }.map {
            AICachedInlineWordQuick(result: $0.value,
                                    providerDisplayName: $0.provider,
                                    model: $0.model)
        }
    }

    func storeInlineWordQuick(_ result: InlineWordQuickAIResult, query: String,
                              configuration: AIProviderConfiguration) async throws {
        try await storeInline(try result.validated(), query: query,
                              intent: .inlineWordQuick, configuration: configuration)
    }

    func inlineSentenceQuickValue(for sentence: String,
                                  configuration: AIProviderConfiguration) async throws
        -> AICachedInlineSentenceQuick? {
        try await decodedInlineValue(for: sentence, intent: .inlineSentenceQuick,
                                     configuration: configuration) { data in
            guard let decoded = try? JSONDecoder().decode(InlineSentenceQuickAIResult.self,
                                                          from: data),
                  let validated = try? decoded.validated() else { return nil }
            return validated
        }.map {
            AICachedInlineSentenceQuick(result: $0.value,
                                        providerDisplayName: $0.provider,
                                        model: $0.model)
        }
    }

    func storeInlineSentenceQuick(_ result: InlineSentenceQuickAIResult, sentence: String,
                                  configuration: AIProviderConfiguration) async throws {
        try await storeInline(try result.validated(), query: sentence,
                              intent: .inlineSentenceQuick, configuration: configuration)
    }

    func inlineWordExpansionValue(for query: String,
                                  configuration: AIProviderConfiguration) async throws
        -> AICachedExplanation? {
        try await decodedInlineValue(for: query, intent: .inlineWordExpansion,
                                     configuration: configuration) { data in
            guard let decoded = try? JSONDecoder().decode(AIExplanation.self, from: data),
                  let validated = try? decoded.validated(fallbackHeadword: query) else { return nil }
            return validated
        }.map {
            AICachedExplanation(explanation: $0.value,
                                providerDisplayName: $0.provider,
                                model: $0.model,
                                createdAt: $0.createdAt)
        }
    }

    func storeInlineWordExpansion(_ result: AIExplanation, query: String,
                                  configuration: AIProviderConfiguration) async throws {
        try await storeInline(try result.validated(fallbackHeadword: query), query: query,
                              intent: .inlineWordExpansion, configuration: configuration)
    }

    func inlineSentenceExpansionValue(for sentence: String,
                                      configuration: AIProviderConfiguration) async throws
        -> AICachedSentenceAnalysis? {
        try await decodedInlineValue(for: sentence, intent: .inlineSentenceExpansion,
                                     configuration: configuration) { data in
            guard let decoded = try? JSONDecoder().decode(AISentenceAnalysis.self, from: data),
                  let validated = try? decoded.validated(expectedSourceText: sentence) else {
                return nil
            }
            return validated
        }.map {
            AICachedSentenceAnalysis(analysis: $0.value,
                                     providerDisplayName: $0.provider,
                                     model: $0.model,
                                     createdAt: $0.createdAt)
        }
    }

    func storeInlineSentenceExpansion(_ result: AISentenceAnalysis, sentence: String,
                                      configuration: AIProviderConfiguration) async throws {
        try await storeInline(try result.validated(expectedSourceText: sentence), query: sentence,
                              intent: .inlineSentenceExpansion, configuration: configuration)
    }

    func clear() async throws {
        try await perform { database in
            guard sqlite3_exec(database, "DELETE FROM ai_explanation_cache;",
                               nil, nil, nil) == SQLITE_OK else {
                throw AICacheError.unavailable
            }
        }
    }

    func removeExplanation(for query: String,
                           configuration: AIProviderConfiguration) async throws {
        try await remove(key: Self.cacheKey(query: query, configuration: configuration))
    }

    func removeSentenceAnalysis(for sentence: String,
                                configuration: AIProviderConfiguration) async throws {
        try await remove(key: Self.sentenceCacheKey(sentence: sentence,
                                                     configuration: configuration))
    }

    private func remove(key: String) async throws {
        try await perform { database in try Self.delete(key: key, database: database) }
    }

    private func perform<T>(_ operation: @escaping (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [databaseURL] in
                do {
                    try FileManager.default.createDirectory(
                        at: databaseURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    var database: OpaquePointer?
                    guard sqlite3_open_v2(databaseURL.path, &database,
                                          SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                          nil) == SQLITE_OK,
                          let database else {
                        if let database { sqlite3_close(database) }
                        throw AICacheError.unavailable
                    }
                    defer { sqlite3_close(database) }
                    try Self.prepare(database)
                    continuation.resume(returning: try operation(database))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func prepare(_ database: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS ai_explanation_cache (
          cache_key TEXT PRIMARY KEY NOT NULL,
          response_json BLOB NOT NULL,
          created_at REAL NOT NULL,
          provider_name TEXT NOT NULL,
          model TEXT NOT NULL,
          prompt_version INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ai_explanation_cache_created_at
          ON ai_explanation_cache(created_at);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AICacheError.unavailable
        }
    }

    private static func trim(_ database: OpaquePointer) throws {
        let sql = """
        DELETE FROM ai_explanation_cache WHERE cache_key IN (
          SELECT cache_key FROM ai_explanation_cache ORDER BY created_at DESC
          LIMIT -1 OFFSET \(maximumEntries)
        );
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AICacheError.unavailable
        }
    }

    static func cacheKey(query: String,
                         configuration: AIProviderConfiguration) -> String {
        let normalizedQuery = query.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["cache-v2", AIExplanationMode.word.rawValue,
                queryIntentIdentity(QueryIntentClassifier.classify(query).intent),
                "dictionary-full",
                configuration.providerID.uuidString.lowercased(),
                configuration.providerType.rawValue,
                stableDigest(configuration.normalizedBaseURL.lowercased()),
                configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                normalizedQuery,
                String(aiDictionaryPromptVersion),
                responsePolicyIdentity(configuration),
                String(wordResponseSchemaVersion)]
            .joined(separator: "\u{1F}")
    }

    static func sentenceCacheKey(sentence: String,
                                 configuration: AIProviderConfiguration) -> String {
        let normalized = SentenceTextNormalizer.normalize(sentence)
            .precomposedStringWithCanonicalMapping
        return ["cache-v2", AIExplanationMode.sentence.rawValue, "sentence-full",
                configuration.providerID.uuidString.lowercased(),
                configuration.providerType.rawValue,
                stableDigest(configuration.normalizedBaseURL.lowercased()),
                configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                normalized,
                String(aiSentencePromptVersion),
                responsePolicyIdentity(configuration),
                String(sentenceResponseSchemaVersion)]
            .joined(separator: "\u{1F}")
    }

    static func inlineCacheKey(query: String, intent: AIRequestIntent,
                               configuration: AIProviderConfiguration) -> String {
        let normalizedBase = SentenceTextNormalizer.normalize(query)
            .precomposedStringWithCanonicalMapping
        let normalized: String
        switch intent {
        case .inlineWordQuick, .inlineWordExpansion:
            normalized = normalizedBase.lowercased(with: Locale(identifier: "en_US_POSIX"))
        case .inlineSentenceQuick, .inlineSentenceExpansion:
            normalized = normalizedBase
        }
        return ["cache-v2", intent.rawValue,
                configuration.providerID.uuidString.lowercased(),
                configuration.providerType.rawValue,
                stableDigest(configuration.normalizedBaseURL.lowercased()),
                configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                normalized,
                String(intent.promptVersion),
                responsePolicyIdentity(configuration),
                String(inlineResponseSchemaVersion)]
            .joined(separator: "\u{1F}")
    }

    private struct DecodedInline<Value> {
        let value: Value
        let provider: String
        let model: String
        let createdAt: Date
    }

    private func decodedInlineValue<Value>(
        for query: String, intent: AIRequestIntent,
        configuration: AIProviderConfiguration,
        decode: @escaping (Data) -> Value?
    ) async throws -> DecodedInline<Value>? {
        try await perform { database in
            let key = Self.inlineCacheKey(query: query, intent: intent,
                                          configuration: configuration)
            let sql = """
            SELECT response_json, provider_name, model, created_at
            FROM ai_explanation_cache WHERE cache_key = ? LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AICacheError.unavailable
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(key, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            guard let value = decode(data) else {
                try Self.delete(key: key, database: database)
                return nil
            }
            return DecodedInline(value: value,
                                 provider: Self.text(statement, column: 1),
                                 model: Self.text(statement, column: 2),
                                 createdAt: Date(timeIntervalSince1970:
                                    sqlite3_column_double(statement, 3)))
        }
    }

    private func storeInline<Value: Encodable>(
        _ value: Value, query: String, intent: AIRequestIntent,
        configuration: AIProviderConfiguration
    ) async throws {
        let data = try JSONEncoder().encode(value)
        try await perform { database in
            let sql = """
            INSERT OR REPLACE INTO ai_explanation_cache
            (cache_key, response_json, created_at, provider_name, model, prompt_version)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AICacheError.unavailable
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(Self.inlineCacheKey(query: query, intent: intent,
                                          configuration: configuration),
                      to: statement, at: 1)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            Self.bind(configuration.providerDisplayName, to: statement, at: 4)
            Self.bind(configuration.model, to: statement, at: 5)
            sqlite3_bind_int(statement, 6, Int32(intent.promptVersion))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw AICacheError.unavailable }
            try Self.trim(database)
        }
    }

    private static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private static func text(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func delete(key: String, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
                                 "DELETE FROM ai_explanation_cache WHERE cache_key = ?;",
                                 -1, &statement, nil) == SQLITE_OK else {
            throw AICacheError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AICacheError.unavailable }
    }

    private static func responsePolicyIdentity(_ configuration: AIProviderConfiguration) -> String {
        "json=\(configuration.options.usesJSONResponseFormat ? 1 : 0);thinking=disabled"
    }

    private static func queryIntentIdentity(_ intent: QueryIntent) -> String {
        switch intent {
        case .word: return "word"
        case .phrase: return "phrase"
        case .sentence: return "sentence"
        case .textTooLong: return "text-too-long"
        }
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
