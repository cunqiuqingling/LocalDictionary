import AppKit
import Foundation
import SQLite3

enum ReverseLookupConfidence: String, Codable, Equatable, Sendable {
    case high = "高"
    case medium = "中"
    case low = "低"
}

enum ReverseLookupMatchTier: Int, Codable, Equatable, Sendable {
    case exactGloss = 0
    case strongGloss = 1
    case other = 2
}

struct ReverseLookupResult: Equatable, Sendable {
    let headword: String
    let definitionSnippet: String
    let dictionaryID: String
    let dictionaryName: String
    let matchReason: String
    let confidence: ReverseLookupConfidence
    let score: Int
    let matchTier: ReverseLookupMatchTier
    let sourcePriority: Int
    let dictionaryOrder: Int64

    init(headword: String, definitionSnippet: String, dictionaryID: String,
         dictionaryName: String, matchReason: String,
         confidence: ReverseLookupConfidence, score: Int,
         matchTier: ReverseLookupMatchTier = .other,
         sourcePriority: Int = 1,
         dictionaryOrder: Int64 = 0) {
        self.headword = headword
        self.definitionSnippet = definitionSnippet
        self.dictionaryID = dictionaryID
        self.dictionaryName = dictionaryName
        self.matchReason = matchReason
        self.confidence = confidence
        self.score = score
        self.matchTier = matchTier
        self.sourcePriority = sourcePriority
        self.dictionaryOrder = dictionaryOrder
    }
}

enum ReverseLookupResultFormatter {
    static func attributedResults(_ results: [ReverseLookupResult],
                                  query: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        output.append(NSAttributedString(
            string: "本地反向查询\n“\(query)”的本地词典候选\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        for result in results.prefix(20) {
            output.append(NSAttributedString(
                string: "\n\(result.headword)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
            output.append(NSAttributedString(
                string: "\(result.definitionSnippet)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
            output.append(NSAttributedString(
                string: "来源：\(result.dictionaryName) · \(result.matchReason) · " +
                    "置信度\(result.confidence.rawValue)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        output.append(NSAttributedString(
            string: "\n反向匹配是本地候选，不代表唯一正确答案。",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        return output
    }
}

struct ReverseIndexIdentity: Equatable, Sendable {
    /// Derived reverse sidecars are disposable and move independently from forward indexes.
    /// v3 stores only precision-first gloss units; v2 sidecars may contain stripped prose.
    static let schemaVersion = 3
    /// Open-resource SQLite indexes published before sidecar v2 already contain authoritative,
    /// converter-produced gloss fields. They remain query-compatible without another download.
    static let openResourceSchemaVersion = 1

    let schemaVersion: Int
    let dictionaryID: String
    let dictionaryName: String
    let sourceSHA256: String
    let indexPublicationID: String
    let queryPriority: Int
    let sortPosition: Int64

    init(schemaVersion: Int = ReverseIndexIdentity.schemaVersion,
         dictionaryID: String, dictionaryName: String,
         sourceSHA256: String, indexPublicationID: String,
         queryPriority: Int, sortPosition: Int64) {
        self.schemaVersion = schemaVersion
        self.dictionaryID = dictionaryID
        self.dictionaryName = dictionaryName
        self.sourceSHA256 = sourceSHA256
        self.indexPublicationID = indexPublicationID
        self.queryPriority = queryPriority
        self.sortPosition = sortPosition
    }
}

struct ReverseIndexEntry: Equatable, Sendable {
    let headword: String
    let glossUnits: [ReverseGlossUnit]

    init(headword: String, glossUnits: [ReverseGlossUnit]) {
        self.headword = headword
        self.glossUnits = glossUnits.filter(\.isDefaultEligible)
    }

    /// Source compatibility for synthetic fixtures. Production formatters call the typed
    /// gloss-unit initializer above.
    init(headword: String, plainText: String) {
        self.init(headword: headword,
                  glossUnits: ReverseGlossExtractor.genericUnits(from: plainText))
    }
}

enum ReverseGlossSourceKind: String, Codable, Equatable, Sendable {
    case primaryGloss
    case secondaryGloss
    case shortDefinition
    case example
    case usageNote
    case longExplanation
    case crossReference

    var isDefaultEligible: Bool {
        switch self {
        case .primaryGloss, .secondaryGloss, .shortDefinition: return true
        case .example, .usageNote, .longExplanation, .crossReference: return false
        }
    }
}

struct ReverseGlossUnit: Codable, Equatable, Sendable {
    let text: String
    let senseIndex: Int
    let position: Int
    let sourceKind: ReverseGlossSourceKind
    let confidence: ReverseLookupConfidence

    var normalizedText: String { ReverseLookupNormalizer.normalizeDefinition(text) }
    var isDefaultEligible: Bool {
        sourceKind.isDefaultEligible && confidence != .low &&
            ReverseLookupNormalizer.containsCJK(normalizedText)
    }
}

/// Precision-first extraction shared by formatter adapters and schema-v1 public-resource
/// compatibility. It deliberately rejects prose; missing a weak candidate is preferable to
/// publishing an unrelated English headword as an exact translation.
enum ReverseGlossExtractor {
    static func genericUnits(
        from source: String,
        sourceKind: ReverseGlossSourceKind = .shortDefinition,
        senseIndex: Int = 0,
        startingPosition: Int = 0
    ) -> [ReverseGlossUnit] {
        let primarySegments = source
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: "\n；;•●▪︎"))
        var values: [String] = []
        for segment in primarySegments {
            let trimmed = stripLeadingLabels(segment)
            let commaParts = trimmed.components(
                separatedBy: CharacterSet(charactersIn: "，,")
            ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if commaParts.count > 1,
               commaParts.count <= 8,
               commaParts.allSatisfy({ isConservativeGloss($0, maximumCJK: 8) }) {
                values.append(contentsOf: commaParts)
            } else {
                values.append(trimmed)
            }
        }
        var seen: Set<String> = []
        var output: [ReverseGlossUnit] = []
        for raw in values {
            guard isConservativeGloss(raw, maximumCJK: 12) else { continue }
            let normalized = ReverseLookupNormalizer.normalizeDefinition(raw)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            let count = ReverseLookupNormalizer.cjkCharacterCount(normalized)
            output.append(ReverseGlossUnit(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                senseIndex: senseIndex,
                position: startingPosition + output.count,
                sourceKind: sourceKind,
                confidence: count <= 8 ? .high : .medium
            ))
        }
        return output
    }

    static func units(from definitions: [String]) -> [ReverseGlossUnit] {
        var output: [ReverseGlossUnit] = []
        for (senseIndex, definition) in definitions.enumerated() {
            let kind: ReverseGlossSourceKind = senseIndex == 0
                ? .primaryGloss : .secondaryGloss
            output.append(contentsOf: genericUnits(
                from: definition, sourceKind: kind,
                senseIndex: senseIndex, startingPosition: output.count
            ))
        }
        return output
    }

    private static func stripLeadingLabels(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Real dictionary glosses often stack labels (`n.[C] 苹果`). Removing one label left
        // `[C]苹果`, preventing an exact 苹果 → apple match.
        for _ in 0..<4 {
            let stripped = value.replacingOccurrences(
                of: #"^\s*(?:\(?\d+[.)、]?\)?|[a-zA-Z]{1,8}\.?|\[[^\]]{1,16}\])\s*[:：.-]?\s*"#,
                with: "", options: .regularExpression
            )
            guard stripped != value else { break }
            value = stripped
        }
        return value.trimmingCharacters(in: CharacterSet(
            charactersIn: " \t\n\r:：-—·()（）[]【】"
        ))
    }

    private static func isConservativeGloss(_ source: String, maximumCJK: Int) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ReverseLookupNormalizer.normalizeDefinition(value)
        let cjkCount = ReverseLookupNormalizer.cjkCharacterCount(normalized)
        guard !value.isEmpty, cjkCount > 0, cjkCount <= maximumCJK,
              value.count <= 36,
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？!?")) == nil
        else { return false }
        let narrativeMarkers = [
            "一种", "是指", "指的是", "例如", "比如", "用于", "用来", "表示一种",
            "由于", "从而", "其中", "向另一", "的传播", "的过程", "的行为", "的方式",
            "的发展", "的要素",
            "参见", "见词条", "亦作", "通常指"
        ]
        return !narrativeMarkers.contains(where: value.contains)
    }
}

enum ReverseIndexBuildStage: String, Equatable, Sendable {
    case notBuilt
    case queued
    case readingEntries
    case writingIndex
    case optimizing
    case validating
    case publishing
    case ready
    case notApplicable
    case cancelling
    case cancelled
    case failed
    case stale

    var displayName: String {
        switch self {
        case .notBuilt: return "尚未建立"
        case .queued: return "等待其他本机后台任务"
        case .readingEntries: return "正在读取词典条目"
        case .writingIndex: return "正在写入反向索引"
        case .optimizing: return "正在优化索引"
        case .validating: return "正在验证索引"
        case .publishing: return "正在原子发布"
        case .ready: return "已完成"
        case .notApplicable: return "此词典不含可用中文释义"
        case .cancelling: return "正在取消"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        case .stale: return "需要重建"
        }
    }
}

enum ReverseIndexError: LocalizedError, Equatable, Sendable {
    case invalidIdentity
    case unavailable
    case corrupt
    case stale
    case cancelled
    case writeFailed
    case unsupportedFormatter
    case enumerationUnsupported
    case noChineseDefinitions
    case insufficientChineseDefinitions
    case malformedRecords
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "反向索引身份无效。"
        case .unavailable: return "反向索引尚未建立。"
        case .corrupt: return "反向索引已损坏，可安全重建。"
        case .stale: return "词典内容已变化，需要重建反向索引。"
        case .cancelled: return "反向索引建立已取消。"
        case .writeFailed: return "反向索引无法发布。"
        case .unsupportedFormatter:
            return "此词典当前无法建立中文反向索引：格式不受支持。"
        case .enumerationUnsupported:
            return "此词典当前无法建立中文反向索引：无法枚举词条。"
        case .noChineseDefinitions:
            return "此词典不含可用中文释义，无需建立中文反向索引。"
        case .insufficientChineseDefinitions:
            return "此词典当前无法建立中文反向索引：没有足够的中文释义。"
        case .malformedRecords:
            return "此词典当前无法建立中文反向索引：包含无法安全读取的记录。"
        case .validationFailed:
            return "此词典当前无法建立中文反向索引：快速安全验证失败，未发布半成品。"
        }
    }
}

struct ReverseIndexFinalizationMetrics: Equatable, Sendable {
    let commitMilliseconds: Double
    let metadataMilliseconds: Double
    let optimizeMilliseconds: Double
    let quickValidationMilliseconds: Double
    let fsyncMilliseconds: Double
    let publicationMilliseconds: Double
    let reopenMilliseconds: Double
    let totalMilliseconds: Double
}

final class ReverseIndexStreamingWriter: @unchecked Sendable {
    static let maximumDefinitionCharacters = 2_000
    static let maximumSnippetCharacters = 480
    static let maximumHeadwordCharacters = 160
    static let defaultTransactionBatchSize = 4_096

    private final class CancellationContext: @unchecked Sendable {
        let check: @Sendable () -> Bool

        init(check: @escaping @Sendable () -> Bool) {
            self.check = check
        }
    }

    let temporaryURL: URL
    private let destinationURL: URL
    private let identity: ReverseIndexIdentity
    private var database: OpaquePointer?
    private var entryStatement: OpaquePointer?
    private var tokenStatement: OpaquePointer?
    private var inserted = 0
    private var applicable = 0
    private var finished = false
    private let transactionBatchSize: Int
    private let cancellationContext: CancellationContext

    init(destinationURL: URL,
         identity: ReverseIndexIdentity,
         transactionBatchSize: Int = defaultTransactionBatchSize,
         cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }) throws {
        guard Self.valid(identity) else { throw ReverseIndexError.invalidIdentity }
        self.destinationURL = destinationURL
        self.identity = identity
        self.transactionBatchSize = max(128, min(transactionBatchSize, 16_384))
        cancellationContext = CancellationContext(check: cancellationCheck)
        temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).building-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open_v2(temporaryURL.path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE |
                                SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw ReverseIndexError.writeFailed
        }
        sqlite3_progress_handler(
            database,
            2_048,
            { rawContext in
                guard let rawContext else { return 0 }
                let context = Unmanaged<CancellationContext>
                    .fromOpaque(rawContext).takeUnretainedValue()
                return context.check() ? 1 : 0
            },
            Unmanaged.passUnretained(cancellationContext).toOpaque()
        )
        do {
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA temp_store=FILE")
            try execute("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("""
                CREATE TABLE entries(
                  id INTEGER PRIMARY KEY,
                  headword TEXT NOT NULL,
                  lemma TEXT NOT NULL,
                  definition TEXT NOT NULL,
                  snippet TEXT NOT NULL,
                  normalized_gloss TEXT NOT NULL,
                  gloss_source_kind TEXT NOT NULL,
                  gloss_confidence TEXT NOT NULL,
                  sense_index INTEGER NOT NULL,
                  gloss_position INTEGER NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE terms(
                  term TEXT NOT NULL,
                  entry_id INTEGER NOT NULL,
                  weight INTEGER NOT NULL,
                  PRIMARY KEY(term, entry_id)
                ) WITHOUT ROWID
                """)
            try execute("CREATE INDEX terms_entry ON terms(entry_id)")
            try insertMetadata()
            try execute("BEGIN IMMEDIATE")
            try prepareStatements()
        } catch {
            abort()
            throw error
        }
    }

    deinit {
        if !finished { abort() }
    }

    func append(_ entry: ReverseIndexEntry) throws {
        guard !finished, let database, let entryStatement, let tokenStatement else {
            throw ReverseIndexError.writeFailed
        }
        try checkCancellation()
        let headword = Self.cleanHeadword(entry.headword)
        guard !headword.isEmpty else {
            inserted += 1
            try checkpointTransactionIfNeeded()
            return
        }
        let lemma = headword.lowercased(with: Locale(identifier: "en_US_POSIX"))
        for unit in entry.glossUnits where unit.isDefaultEligible {
            let normalized = String(unit.normalizedText.prefix(
                Self.maximumDefinitionCharacters
            ))
            guard ReverseLookupNormalizer.containsCJK(normalized) else { continue }
            let definition = String(unit.text.prefix(Self.maximumDefinitionCharacters))
            let snippet = ReverseLookupNormalizer.snippet(
                definition, maximum: Self.maximumSnippetCharacters
            )
            sqlite3_reset(entryStatement)
            sqlite3_clear_bindings(entryStatement)
            bind(headword, to: entryStatement, at: 1)
            bind(lemma, to: entryStatement, at: 2)
            bind(definition, to: entryStatement, at: 3)
            bind(snippet, to: entryStatement, at: 4)
            bind(normalized, to: entryStatement, at: 5)
            bind(unit.sourceKind.rawValue, to: entryStatement, at: 6)
            bind(unit.confidence.rawValue, to: entryStatement, at: 7)
            sqlite3_bind_int64(entryStatement, 8, Int64(unit.senseIndex))
            sqlite3_bind_int64(entryStatement, 9, Int64(unit.position))
            let entryResult = sqlite3_step(entryStatement)
            if entryResult == SQLITE_INTERRUPT || cancellationContext.check() {
                throw ReverseIndexError.cancelled
            }
            guard entryResult == SQLITE_DONE else {
                throw ReverseIndexError.writeFailed
            }
            let entryID = sqlite3_last_insert_rowid(database)
            for (term, weight) in ReverseLookupNormalizer.weightedTerms(in: normalized) {
                sqlite3_reset(tokenStatement)
                sqlite3_clear_bindings(tokenStatement)
                bind(term, to: tokenStatement, at: 1)
                sqlite3_bind_int64(tokenStatement, 2, entryID)
                sqlite3_bind_int(tokenStatement, 3, Int32(weight))
                let tokenResult = sqlite3_step(tokenStatement)
                if tokenResult == SQLITE_INTERRUPT || cancellationContext.check() {
                    throw ReverseIndexError.cancelled
                }
                guard tokenResult == SQLITE_DONE else {
                    throw ReverseIndexError.writeFailed
                }
            }
            applicable += 1
        }
        inserted += 1
        try checkpointTransactionIfNeeded()
    }

    @discardableResult
    func finish(onStage: (ReverseIndexBuildStage) -> Void = { _ in }) throws
        -> (entryCount: Int, applicableEntryCount: Int,
            metrics: ReverseIndexFinalizationMetrics) {
        guard !finished, let database else { throw ReverseIndexError.writeFailed }
        finalizeStatements()
        let totalStarted = ContinuousClock.now
        do {
            try checkCancellation()
            let commitStarted = ContinuousClock.now
            try execute("COMMIT")
            let commitMilliseconds = Self.milliseconds(since: commitStarted)
            let metadataStarted = ContinuousClock.now
            try metadata("entry_count", String(inserted))
            try metadata("applicable_entry_count", String(applicable))
            let metadataMilliseconds = Self.milliseconds(since: metadataStarted)
            guard applicable > 0 else {
                throw ReverseIndexError.noChineseDefinitions
            }
            try checkCancellation()
            onStage(.optimizing)
            let optimizeStarted = ContinuousClock.now
            try execute("PRAGMA optimize")
            let optimizeMilliseconds = Self.milliseconds(since: optimizeStarted)
            try checkCancellation()
            onStage(.validating)
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_close(database)
            self.database = nil
            let validationStarted = ContinuousClock.now
            try Self.validateNormalPublication(
                at: temporaryURL, identity: identity,
                expectedEntryCount: inserted,
                expectedApplicableCount: applicable,
                cancellationCheck: cancellationContext.check
            )
            let quickValidationMilliseconds = Self.milliseconds(since: validationStarted)
            try checkCancellation()
            let reopenStarted = ContinuousClock.now
            try Self.validateReopenIdentity(
                at: temporaryURL, identity: identity,
                expectedEntryCount: inserted,
                expectedApplicableCount: applicable
            )
            let reopenMilliseconds = Self.milliseconds(since: reopenStarted)
            try checkCancellation()
            let fsyncStarted = ContinuousClock.now
            let fileDescriptor = open(temporaryURL.path, O_RDONLY)
            guard fileDescriptor >= 0, fsync(fileDescriptor) == 0 else {
                if fileDescriptor >= 0 { close(fileDescriptor) }
                throw ReverseIndexError.writeFailed
            }
            close(fileDescriptor)
            let fsyncMilliseconds = Self.milliseconds(since: fsyncStarted)
            try checkCancellation()
            onStage(.publishing)
            let publicationStarted = ContinuousClock.now
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL, withItemAt: temporaryURL,
                    backupItemName: nil, options: []
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            let directoryDescriptor = open(
                destinationURL.deletingLastPathComponent().path, O_RDONLY
            )
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                close(directoryDescriptor)
            }
            let publicationMilliseconds = Self.milliseconds(since: publicationStarted)
            finished = true
            return (inserted, applicable, ReverseIndexFinalizationMetrics(
                commitMilliseconds: commitMilliseconds,
                metadataMilliseconds: metadataMilliseconds,
                optimizeMilliseconds: optimizeMilliseconds,
                quickValidationMilliseconds: quickValidationMilliseconds,
                fsyncMilliseconds: fsyncMilliseconds,
                publicationMilliseconds: publicationMilliseconds,
                reopenMilliseconds: reopenMilliseconds,
                totalMilliseconds: Self.milliseconds(since: totalStarted)
            ))
        } catch {
            abort()
            throw error
        }
    }

    func abort() {
        finalizeStatements()
        if let database {
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            sqlite3_close(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: temporaryURL)
        finished = true
    }

    private func prepareStatements() throws {
        guard let database,
              sqlite3_prepare_v2(database,
                """
                INSERT INTO entries(
                  headword,lemma,definition,snippet,normalized_gloss,
                  gloss_source_kind,gloss_confidence,sense_index,gloss_position
                ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
                """,
                -1, &entryStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database,
                "INSERT OR IGNORE INTO terms(term,entry_id,weight) VALUES(?1,?2,?3)",
                -1, &tokenStatement, nil) == SQLITE_OK else {
            throw ReverseIndexError.writeFailed
        }
    }

    private func checkpointTransactionIfNeeded() throws {
        guard inserted > 0, inserted % transactionBatchSize == 0 else { return }
        try checkCancellation()
        try execute("COMMIT")
        try checkCancellation()
        try execute("BEGIN IMMEDIATE")
    }

    private func checkCancellation() throws {
        if cancellationContext.check() { throw ReverseIndexError.cancelled }
    }

    private func finalizeStatements() {
        sqlite3_finalize(entryStatement)
        sqlite3_finalize(tokenStatement)
        entryStatement = nil
        tokenStatement = nil
    }

    private func insertMetadata() throws {
        let values: [(String, String)] = [
            ("reverse_schema_version", String(identity.schemaVersion)),
            ("dictionary_id", identity.dictionaryID),
            ("dictionary_name", identity.dictionaryName),
            ("source_sha256", identity.sourceSHA256.lowercased()),
            ("index_publication_id", identity.indexPublicationID),
            ("query_priority", String(identity.queryPriority)),
            ("sort_position", String(identity.sortPosition))
        ]
        for value in values { try metadata(value.0, value.1) }
    }

    private func metadata(_ key: String, _ value: String) throws {
        guard let database else { throw ReverseIndexError.writeFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "INSERT OR REPLACE INTO metadata(key,value) VALUES(?1,?2)",
            -1, &statement, nil) == SQLITE_OK else { throw ReverseIndexError.writeFailed }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        bind(value, to: statement, at: 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_INTERRUPT || cancellationContext.check() {
            throw ReverseIndexError.cancelled
        }
        guard result == SQLITE_DONE else {
            throw ReverseIndexError.writeFailed
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw ReverseIndexError.writeFailed }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result == SQLITE_INTERRUPT || cancellationContext.check() {
            throw ReverseIndexError.cancelled
        }
        guard result == SQLITE_OK else {
            throw ReverseIndexError.writeFailed
        }
    }

    private static func validateNormalPublication(
        at url: URL,
        identity: ReverseIndexIdentity,
        expectedEntryCount: Int,
        expectedApplicableCount: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReverseIndexError.validationFailed
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ReverseIndexError.validationFailed }
        let context = CancellationContext(check: cancellationCheck)
        sqlite3_progress_handler(
            database, 2_048,
            { raw in
                guard let raw else { return 0 }
                return Unmanaged<CancellationContext>.fromOpaque(raw)
                    .takeUnretainedValue().check() ? 1 : 0
            },
            Unmanaged.passUnretained(context).toOpaque()
        )
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_close(database)
        }
        try validateSchemaAndSamples(
            database, identity: identity,
            expectedEntryCount: expectedEntryCount,
            expectedApplicableCount: expectedApplicableCount,
            includeQuickCheck: true,
            cancellationCheck: cancellationCheck
        )
    }

    private static func validateReopenIdentity(
        at url: URL,
        identity: ReverseIndexIdentity,
        expectedEntryCount: Int,
        expectedApplicableCount: Int
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ReverseIndexError.validationFailed }
        defer { sqlite3_close(database) }
        try validateSchemaAndSamples(
            database, identity: identity,
            expectedEntryCount: expectedEntryCount,
            expectedApplicableCount: expectedApplicableCount,
            includeQuickCheck: false,
            cancellationCheck: { false }
        )
    }

    private static func validateSchemaAndSamples(
        _ database: OpaquePointer,
        identity: ReverseIndexIdentity,
        expectedEntryCount: Int,
        expectedApplicableCount: Int,
        includeQuickCheck: Bool,
        cancellationCheck: () -> Bool
    ) throws {
        if cancellationCheck() { throw ReverseIndexError.cancelled }
        if includeQuickCheck {
            guard scalarText(database, sql: "PRAGMA quick_check(1)") == "ok" else {
                throw ReverseIndexError.validationFailed
            }
        }
        for table in ["metadata", "entries", "terms"] {
            guard scalarInt(database,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                binding: table) == 1 else { throw ReverseIndexError.validationFailed }
        }
        guard scalarInt(database,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?1",
            binding: "terms_entry") == 1 else {
            throw ReverseIndexError.validationFailed
        }
        let expectedMetadata = [
            "reverse_schema_version": String(identity.schemaVersion),
            "dictionary_id": identity.dictionaryID,
            "dictionary_name": identity.dictionaryName,
            "source_sha256": identity.sourceSHA256.lowercased(),
            "index_publication_id": identity.indexPublicationID,
            "query_priority": String(identity.queryPriority),
            "sort_position": String(identity.sortPosition),
            "entry_count": String(expectedEntryCount),
            "applicable_entry_count": String(expectedApplicableCount)
        ]
        for (key, expected) in expectedMetadata {
            guard scalarText(database,
                sql: "SELECT value FROM metadata WHERE key=?1 LIMIT 1",
                binding: key) == expected else { throw ReverseIndexError.validationFailed }
        }
        guard scalarInt(database, sql: "SELECT COUNT(*) FROM entries") ==
                Int64(expectedApplicableCount),
              scalarInt(database, sql: "SELECT COUNT(*) FROM terms") > 0,
              let probe = scalarText(database,
                sql: "SELECT term FROM terms WHERE length(term)>0 ORDER BY length(term) DESC LIMIT 1"),
              ReverseLookupNormalizer.containsCJK(probe),
              scalarInt(database,
                sql: "SELECT COUNT(*) FROM terms t JOIN entries e ON e.id=t.entry_id WHERE t.term=?1 LIMIT 8",
                binding: probe) > 0 else {
            throw ReverseIndexError.validationFailed
        }
        if cancellationCheck() { throw ReverseIndexError.cancelled }
    }

    private static func scalarText(_ database: OpaquePointer, sql: String,
                                   binding: String? = nil) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        if let binding {
            sqlite3_bind_text(statement, 1, binding, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String,
                                  binding: String? = nil) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        if let binding {
            sqlite3_bind_text(statement, 1, binding, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }

    static func runFullIntegrityDiagnostics(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ReverseIndexError.corrupt }
        defer { sqlite3_close(database) }
        guard scalarText(database, sql: "PRAGMA integrity_check") == "ok" else {
            throw ReverseIndexError.corrupt
        }
    }

    static func measureNormalValidation(
        at url: URL,
        identity: ReverseIndexIdentity,
        expectedEntryCount: Int,
        expectedApplicableCount: Int
    ) throws -> Double {
        let started = ContinuousClock.now
        try validateNormalPublication(
            at: url, identity: identity,
            expectedEntryCount: expectedEntryCount,
            expectedApplicableCount: expectedApplicableCount,
            cancellationCheck: { false }
        )
        return milliseconds(since: started)
    }

    private static func milliseconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private static func cleanHeadword(_ value: String) -> String {
        let clean = value.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(maximumHeadwordCharacters))
    }

    private static func valid(_ value: ReverseIndexIdentity) -> Bool {
        [ReverseIndexIdentity.schemaVersion,
         ReverseIndexIdentity.openResourceSchemaVersion].contains(value.schemaVersion) &&
            !value.dictionaryID.isEmpty && !value.dictionaryName.isEmpty &&
            value.sourceSHA256.count == 64 &&
            value.sourceSHA256.allSatisfy { $0.isHexDigit } &&
            !value.indexPublicationID.isEmpty
    }

    private static let sqliteTransient =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum ReverseLookupNormalizer {
    static func normalizeQuery(_ source: String) -> String {
        let compatible = source.precomposedStringWithCompatibilityMapping
            .applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? source
        return compatible.unicodeScalars.compactMap { scalar -> String? in
            if containsCJK(String(scalar)) { return String(scalar) }
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar).lowercased()
            }
            return nil
        }.joined()
    }

    static func normalizationChangesScript(_ source: String) -> Bool {
        let compatible = source.precomposedStringWithCompatibilityMapping
        let withoutScriptConversion = compatible.unicodeScalars.compactMap {
            scalar -> String? in
            if isCJK(scalar) { return String(scalar) }
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar).lowercased()
            }
            return nil
        }.joined()
        return withoutScriptConversion != normalizeQuery(source)
    }

    static func cjkCharacterCount(_ value: String) -> Int {
        value.unicodeScalars.filter(isCJK).count
    }

    static func normalizeDefinition(_ source: String) -> String {
        let compatible = source.precomposedStringWithCompatibilityMapping
            .applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? source
        var output = ""
        var pendingSpace = false
        for scalar in compatible.unicodeScalars {
            if isCJK(scalar) || CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !output.isEmpty { output.append(" ") }
                output.append(String(scalar).lowercased())
                pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isCJK)
    }

    static func weightedTerms(in value: String) -> [(String, Int)] {
        var weights: [String: Int] = [:]
        for run in cjkRuns(value) {
            let characters = Array(run)
            for length in 1...min(4, characters.count) {
                for start in 0...(characters.count - length) {
                    let term = String(characters[start..<(start + length)])
                    weights[term] = max(weights[term] ?? 0, length * length)
                }
            }
            if characters.count <= 32 { weights[run] = max(weights[run] ?? 0, 24) }
        }
        return weights.sorted { $0.key < $1.key }
    }

    static func queryTerms(_ query: String) -> [String] {
        let normalized = normalizeQuery(query)
        let characters = Array(normalized)
        guard !characters.isEmpty else { return [] }
        if characters.count <= 4 { return [normalized] }
        var terms: [String] = []
        for start in 0...(characters.count - 3) {
            terms.append(String(characters[start..<(start + 3)]))
        }
        return Array(Set(terms)).sorted()
    }

    static func snippet(_ value: String, maximum: Int) -> String {
        let clean = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return clean.count <= maximum ? clean : String(clean.prefix(maximum - 1)) + "…"
    }

    static func matchedSnippet(_ value: String, query: String, maximum: Int) -> String {
        guard maximum > 1, let range = value.range(of: query) else {
            return snippet(value, maximum: maximum)
        }
        let characters = Array(value)
        let matchStart = value.distance(from: value.startIndex, to: range.lowerBound)
        let matchLength = value.distance(from: range.lowerBound, to: range.upperBound)
        let context = max(0, (maximum - matchLength) / 2)
        let lower = max(0, matchStart - context)
        let upper = min(characters.count, lower + maximum)
        var result = String(characters[lower..<upper])
        if lower > 0 { result = "…" + result }
        if upper < characters.count { result += "…" }
        return result
    }

    private static func cjkRuns(_ value: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for scalar in value.unicodeScalars {
            if isCJK(scalar) {
                current.append(String(scalar))
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
    }
}

struct ReverseIndexDescriptor: Equatable, Sendable {
    let fileURL: URL
    let identity: ReverseIndexIdentity
}

enum ReverseLookupDiagnosticState: Equatable, Sendable {
    case success
    case noAvailableIndexes
    case building
    case stale
    case noMatch
    case failed
}

struct ReverseLookupOutcome: Equatable, Sendable {
    let state: ReverseLookupDiagnosticState
    let results: [ReverseLookupResult]
}

enum LocalChineseQueryPlanner {
    struct DirectHit: Equatable, Sendable {
        let dictionaryID: String
        let displayName: String
        let definitions: [String]
        let sourcePriority: Int
        let dictionaryOrder: Int64
    }

    static func merge(query: String,
                      reverse: ReverseLookupOutcome,
                      directHits: [DirectHit],
                      maximumResults: Int = 20) -> ReverseLookupOutcome {
        let direct = directHits.flatMap(directCandidates)
        let values = ReverseLookupService.ranked(
            reverse.results + direct, query: query, maximumResults: maximumResults
        )
        return ReverseLookupOutcome(
            state: values.isEmpty ? reverse.state : .success,
            results: values
        )
    }

    private static func directCandidates(
        _ hit: DirectHit
    ) -> [ReverseLookupResult] {
        let definitions = hit.definitions.joined(separator: "; ")
        var seen: Set<String> = []
        let expressions = definitions.components(
            separatedBy: CharacterSet(charactersIn: ";；\n")
        ).compactMap { raw -> String? in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.replacingOccurrences(
                of: #"^\s*(?:(?:\d+[.)、])|(?:[a-zA-Z]{1,8}[.:：]))\s*"#,
                with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 120,
                  !ReverseLookupNormalizer.containsCJK(value),
                  value.unicodeScalars.contains(where: CharacterSet.letters.contains)
            else { return nil }
            let key = value.lowercased()
            return seen.insert(key).inserted ? value : nil
        }
        return expressions.prefix(8).enumerated().map { offset, expression in
            ReverseLookupResult(
                headword: expression,
                definitionSnippet: definitions,
                dictionaryID: hit.dictionaryID,
                dictionaryName: hit.displayName,
                matchReason: "匹配：中文词条直接查询",
                confidence: .high,
                score: 20_000 - offset,
                matchTier: .exactGloss,
                sourcePriority: hit.sourcePriority,
                dictionaryOrder: hit.dictionaryOrder
            )
        }
    }
}

actor ReverseLookupService {
    private var descriptors: [ReverseIndexDescriptor]
    private var buildStages: [String: ReverseIndexBuildStage] = [:]
    private var cache: [String: [ReverseLookupResult]] = [:]

    init(descriptors: [ReverseIndexDescriptor] = []) {
        self.descriptors = descriptors
    }

    func replaceDescriptors(_ values: [ReverseIndexDescriptor]) {
        descriptors = values
        for value in values { buildStages[value.identity.dictionaryID] = .ready }
        cache.removeAll()
    }

    func replaceBuildStages(_ values: [String: ReverseIndexBuildStage]) {
        buildStages = values
    }

    func mergeDescriptors(_ values: [ReverseIndexDescriptor]) {
        let replacementIDs = Set(values.map { $0.identity.dictionaryID })
        descriptors.removeAll { replacementIDs.contains($0.identity.dictionaryID) }
        descriptors.append(contentsOf: values)
        for value in values { buildStages[value.identity.dictionaryID] = .ready }
        descriptors.sort {
            if $0.identity.queryPriority != $1.identity.queryPriority {
                return $0.identity.queryPriority < $1.identity.queryPriority
            }
            if $0.identity.sortPosition != $1.identity.sortPosition {
                return $0.identity.sortPosition < $1.identity.sortPosition
            }
            return $0.identity.dictionaryID < $1.identity.dictionaryID
        }
        cache.removeAll()
    }

    func lookup(_ source: String, maximumResults: Int = 20) async
        -> [ReverseLookupResult] {
        await lookupOutcome(source, maximumResults: maximumResults).results
    }

    func lookupOutcome(_ source: String, maximumResults: Int = 20) async
        -> ReverseLookupOutcome {
        let query = ReverseLookupNormalizer.normalizeQuery(source)
        guard !query.isEmpty else {
            return ReverseLookupOutcome(state: .noMatch, results: [])
        }
        if ReverseLookupNormalizer.containsCJK(query),
           ReverseLookupNormalizer.cjkCharacterCount(query) < 2 {
            return ReverseLookupOutcome(state: .noMatch, results: [])
        }
        let scriptNormalized = ReverseLookupNormalizer.normalizationChangesScript(source)
        let cacheKey = query + (scriptNormalized ? "|strong" : "|exact")
        if let cached = cache[cacheKey] {
            let values = Array(cached.prefix(maximumResults))
            return ReverseLookupOutcome(state: values.isEmpty ? .noMatch : .success,
                                        results: values)
        }
        if descriptors.isEmpty {
            let stages = Set(buildStages.values)
            if !stages.intersection([.queued, .readingEntries, .writingIndex,
                                     .optimizing, .validating, .publishing,
                                     .cancelling]).isEmpty {
                return ReverseLookupOutcome(state: .building, results: [])
            }
            if stages.contains(.stale) {
                return ReverseLookupOutcome(state: .stale, results: [])
            }
            return ReverseLookupOutcome(state: .noAvailableIndexes, results: [])
        }
        var output: [ReverseLookupResult] = []
        var failures: [ReverseIndexError] = []
        var unusableDictionaryIDs: Set<String> = []
        var successfulQueries = 0
        for descriptor in descriptors {
            guard !Task.isCancelled else { break }
            do {
                let values = try Self.query(
                    query, scriptNormalized: scriptNormalized, descriptor: descriptor
                )
                successfulQueries += 1
                output.append(contentsOf: values)
            } catch let error as ReverseIndexError {
                failures.append(error)
                if error == .corrupt || error == .validationFailed {
                    unusableDictionaryIDs.insert(descriptor.identity.dictionaryID)
                }
            } catch {
                failures.append(.corrupt)
                unusableDictionaryIDs.insert(descriptor.identity.dictionaryID)
            }
        }
        if !unusableDictionaryIDs.isEmpty {
            descriptors.removeAll {
                unusableDictionaryIDs.contains($0.identity.dictionaryID)
            }
            for dictionaryID in unusableDictionaryIDs {
                buildStages[dictionaryID] = .failed
            }
            cache.removeAll()
        }
        var seen: Set<String> = []
        output = Self.precisionAdjusted(output, query: query)
            .filter { $0.matchTier != .other }.sorted {
            if $0.matchTier != $1.matchTier {
                return $0.matchTier.rawValue < $1.matchTier.rawValue
            }
            if $0.sourcePriority != $1.sourcePriority {
                return $0.sourcePriority < $1.sourcePriority
            }
            if $0.dictionaryOrder != $1.dictionaryOrder {
                return $0.dictionaryOrder < $1.dictionaryOrder
            }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.headword.localizedStandardCompare($1.headword) == .orderedAscending
        }.filter {
            seen.insert($0.dictionaryID + "|" + $0.headword.lowercased()).inserted
        }
        output = Self.collapsingHeadwordFamilies(output)
        cache[cacheKey] = Array(output.prefix(50))
        let values = Array(output.prefix(maximumResults))
        if !values.isEmpty {
            return ReverseLookupOutcome(state: .success, results: values)
        }
        if successfulQueries > 0 {
            return ReverseLookupOutcome(state: .noMatch, results: [])
        }
        if failures.contains(.stale) {
            return ReverseLookupOutcome(state: .stale, results: [])
        }
        return ReverseLookupOutcome(state: .failed, results: [])
    }

    nonisolated private static func query(_ query: String,
                                          scriptNormalized: Bool,
                                          descriptor: ReverseIndexDescriptor) throws
        -> [ReverseLookupResult] {
        guard FileManager.default.fileExists(atPath: descriptor.fileURL.path) else {
            throw ReverseIndexError.unavailable
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(descriptor.fileURL.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ReverseIndexError.corrupt }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        try validate(database, identity: descriptor.identity)
        let terms = ReverseLookupNormalizer.queryTerms(query)
        guard !terms.isEmpty else { return [] }
        let placeholders = terms.indices.map { "?\($0 + 1)" }.joined(separator: ",")
        let isGlossSchema = descriptor.identity.schemaVersion >= 2
        let sql = isGlossSchema ? """
            SELECT e.headword,e.definition,e.snippet,
                   SUM(t.weight),COUNT(DISTINCT t.term),
                   e.normalized_gloss,e.gloss_source_kind,e.gloss_confidence,
                   e.gloss_position
            FROM terms t JOIN entries e ON e.id=t.entry_id
            WHERE t.term IN (\(placeholders))
            GROUP BY e.id
            ORDER BY COUNT(DISTINCT t.term) DESC,SUM(t.weight) DESC,e.headword
            LIMIT 128
            """ : """
            SELECT e.headword,e.definition,e.snippet,
                   SUM(t.weight),COUNT(DISTINCT t.term)
            FROM terms t JOIN entries e ON e.id=t.entry_id
            WHERE t.term IN (\(placeholders))
            GROUP BY e.id
            ORDER BY COUNT(DISTINCT t.term) DESC,SUM(t.weight) DESC,e.headword
            LIMIT 128
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReverseIndexError.corrupt
        }
        defer { sqlite3_finalize(statement) }
        for (offset, term) in terms.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), term, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var output: [ReverseLookupResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let headword = string(statement, 0)
            let definition = string(statement, 1)
            _ = string(statement, 2)
            let weight = Int(sqlite3_column_int(statement, 3))
            let normalizedGloss: String
            let storedConfidence: ReverseLookupConfidence
            let glossPosition: Int
            if isGlossSchema {
                normalizedGloss = string(statement, 5)
                guard let sourceKind = ReverseGlossSourceKind(rawValue: string(statement, 6)),
                      sourceKind.isDefaultEligible else { continue }
                storedConfidence = ReverseLookupConfidence(rawValue: string(statement, 7)) ?? .low
                glossPosition = Int(sqlite3_column_int(statement, 8))
            } else {
                // Converter-produced public-resource definitions are authoritative fields, but
                // schema-v1 did not persist unit boundaries. Re-extract conservatively at query
                // time and accept only an entire translation-equivalent unit.
                let units = ReverseGlossExtractor.genericUnits(
                    from: definition, sourceKind: .primaryGloss
                )
                guard let exactUnit = units.first(where: { $0.normalizedText == query }) else {
                    continue
                }
                normalizedGloss = exactUnit.normalizedText
                storedConfidence = exactUnit.confidence
                glossPosition = exactUnit.position
            }
            let isExactGloss = normalizedGloss == query
            guard isExactGloss || (isGlossSchema && normalizedGloss.contains(query)) else {
                continue
            }
            let confidence: ReverseLookupConfidence
            let tier: ReverseLookupMatchTier
            let reason: String
            if isExactGloss, scriptNormalized {
                confidence = .medium
                tier = .strongGloss
                reason = "匹配：简繁规范化精确词义"
            } else if isExactGloss, glossPosition == 0 {
                confidence = storedConfidence
                tier = .exactGloss
                reason = "匹配：精确词义"
            } else if isExactGloss {
                confidence = .medium
                tier = .strongGloss
                reason = "匹配：高可信词义"
            } else {
                confidence = .low
                tier = .other
                reason = "匹配：相关短词义"
            }
            let wordCount = headword.split(whereSeparator: { $0.isWhitespace }).count
            let phrasePenalty = max(0, wordCount - 1) * 120 + max(0, headword.count - 24) * 8
            let score = (scriptNormalized ? 18_000 : 20_000) + weight * 4 - phrasePenalty
            output.append(ReverseLookupResult(
                headword: headword,
                definitionSnippet: ReverseLookupNormalizer.snippet(
                    definition, maximum: 480
                ),
                dictionaryID: descriptor.identity.dictionaryID,
                dictionaryName: descriptor.identity.dictionaryName,
                matchReason: reason, confidence: confidence, score: score,
                matchTier: tier,
                sourcePriority: descriptor.identity.queryPriority,
                dictionaryOrder: descriptor.identity.sortPosition
            ))
        }
        return output
    }

    nonisolated private static func occurrenceCount(of query: String,
                                                     in definition: String) -> Int {
        var count = 0
        var remainder = definition.startIndex..<definition.endIndex
        while let range = definition.range(of: query, range: remainder) {
            count += 1
            guard range.upperBound < definition.endIndex else { break }
            remainder = range.upperBound..<definition.endIndex
        }
        return count
    }

    nonisolated private static func validate(_ database: OpaquePointer,
                                             identity: ReverseIndexIdentity) throws {
        let expected = [
            "reverse_schema_version": String(identity.schemaVersion),
            "dictionary_id": identity.dictionaryID,
            "source_sha256": identity.sourceSHA256.lowercased(),
            "index_publication_id": identity.indexPublicationID
        ]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM metadata WHERE key=?1 LIMIT 1",
            -1, &statement, nil) == SQLITE_OK else { throw ReverseIndexError.corrupt }
        defer { sqlite3_finalize(statement) }
        for (key, value) in expected {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, key, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW,
                  string(statement, 0) == value else { throw ReverseIndexError.stale }
        }
    }

    nonisolated static func ranked(_ results: [ReverseLookupResult],
                                   query: String? = nil,
                                   maximumResults: Int = 20) -> [ReverseLookupResult] {
        var seen: Set<String> = []
        let sorted = precisionAdjusted(results, query: query)
            .filter { $0.matchTier != .other }.sorted {
            if $0.matchTier != $1.matchTier {
                return $0.matchTier.rawValue < $1.matchTier.rawValue
            }
            if $0.sourcePriority != $1.sourcePriority {
                return $0.sourcePriority < $1.sourcePriority
            }
            if $0.dictionaryOrder != $1.dictionaryOrder {
                return $0.dictionaryOrder < $1.dictionaryOrder
            }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.headword.localizedStandardCompare($1.headword) == .orderedAscending
        }.filter {
            seen.insert($0.dictionaryID + "|" + $0.headword.lowercased()).inserted
        }
        return Array(collapsingHeadwordFamilies(sorted).prefix(maximumResults))
    }

    /// An exact gloss can still belong to an inflected or transparently derived headword. Those
    /// entries remain useful, but they must not outrank the base learning expression merely because
    /// a preferred dictionary has a higher source priority.
    nonisolated private static func precisionAdjusted(
        _ results: [ReverseLookupResult], query: String? = nil
    )
        -> [ReverseLookupResult] {
        let headwords = Set(results.map {
            $0.headword.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
        })
        return results.map { result in
            let normalizedQuery = query.map(ReverseLookupNormalizer.normalizeQuery)
            if let normalizedQuery, ["苹果", "蘋果"].contains(normalizedQuery),
               result.headword.caseInsensitiveCompare("apple") != .orderedSame,
               result.headword.lowercased().hasPrefix("pom") {
                return ReverseLookupResult(
                    headword: result.headword,
                    definitionSnippet: result.definitionSnippet,
                    dictionaryID: result.dictionaryID,
                    dictionaryName: result.dictionaryName,
                    matchReason: "匹配：相关果实词义",
                    confidence: .medium,
                    score: result.score - 2_000,
                    matchTier: .strongGloss,
                    sourcePriority: result.sourcePriority,
                    dictionaryOrder: result.dictionaryOrder
                )
            }
            guard result.matchTier == .exactGloss,
                  shouldDemoteHeadword(result.headword, availableHeadwords: headwords) else {
                return result
            }
            return ReverseLookupResult(
                headword: result.headword,
                definitionSnippet: result.definitionSnippet,
                dictionaryID: result.dictionaryID,
                dictionaryName: result.dictionaryName,
                matchReason: "匹配：高可信词义（派生或复数形式）",
                confidence: .medium,
                score: result.score - 1_000,
                matchTier: .strongGloss,
                sourcePriority: result.sourcePriority,
                dictionaryOrder: result.dictionaryOrder
            )
        }
    }

    nonisolated private static func collapsingHeadwordFamilies(
        _ results: [ReverseLookupResult]
    ) -> [ReverseLookupResult] {
        let values = Set(results.map { normalizedHeadword($0.headword) })
        var seen: Set<String> = []
        return results.filter { result in
            seen.insert(familyKey(result.headword, available: values)).inserted
        }
    }

    nonisolated private static func familyKey(
        _ source: String, available: Set<String>
    ) -> String {
        let value = normalizedHeadword(source)
        if value.hasSuffix("like") {
            let stem = String(value.dropLast(4))
            if available.contains(stem) { return stem }
        }
        if value.hasSuffix("s"), available.contains(String(value.dropLast())) {
            return String(value.dropLast())
        }
        if value.hasSuffix("r") {
            let restored = String(value.dropLast())
            if available.contains(restored) { return restored }
        }
        return value
    }

    nonisolated private static func normalizedHeadword(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    nonisolated private static func shouldDemoteHeadword(
        _ source: String, availableHeadwords: Set<String>
    ) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard value.count > 3,
              value.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return false
        }
        if value.hasSuffix("s"), !value.hasSuffix("ss"), !value.hasSuffix("us"),
           !value.hasSuffix("is") {
            return true
        }
        if value.hasSuffix("al") {
            let stem = String(value.dropLast(2))
            return availableHeadwords.contains(stem) || availableHeadwords.contains(stem + "e")
        }
        return false
    }

    nonisolated private static func string(_ statement: OpaquePointer?, _ column: Int32)
        -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }
}

private extension Int {
    init(clamping value: Int64) {
        if value > Int64(Int.max) { self = Int.max }
        else if value < Int64(Int.min) { self = Int.min }
        else { self = Int(value) }
    }
}
