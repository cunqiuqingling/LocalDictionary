import Foundation
import SQLite3

enum ReverseLookupConfidence: String, Codable, Equatable, Sendable {
    case high = "高"
    case medium = "中"
    case low = "低"
}

struct ReverseLookupResult: Equatable, Sendable {
    let headword: String
    let definitionSnippet: String
    let dictionaryID: String
    let dictionaryName: String
    let matchReason: String
    let confidence: ReverseLookupConfidence
    let score: Int
}

struct ReverseIndexIdentity: Equatable, Sendable {
    static let schemaVersion = 1

    let dictionaryID: String
    let dictionaryName: String
    let sourceSHA256: String
    let indexPublicationID: String
    let queryPriority: Int
    let sortPosition: Int64
}

struct ReverseIndexEntry: Equatable, Sendable {
    let headword: String
    let plainText: String
}

enum ReverseIndexError: LocalizedError, Equatable, Sendable {
    case invalidIdentity
    case unavailable
    case corrupt
    case stale
    case cancelled
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "反向索引身份无效。"
        case .unavailable: return "反向索引尚未建立。"
        case .corrupt: return "反向索引已损坏，可安全重建。"
        case .stale: return "词典内容已变化，需要重建反向索引。"
        case .cancelled: return "反向索引建立已取消。"
        case .writeFailed: return "反向索引无法发布。"
        }
    }
}

final class ReverseIndexStreamingWriter: @unchecked Sendable {
    static let maximumDefinitionCharacters = 2_000
    static let maximumSnippetCharacters = 480
    static let maximumHeadwordCharacters = 160

    let temporaryURL: URL
    private let destinationURL: URL
    private let identity: ReverseIndexIdentity
    private var database: OpaquePointer?
    private var entryStatement: OpaquePointer?
    private var tokenStatement: OpaquePointer?
    private var inserted = 0
    private var applicable = 0
    private var finished = false

    init(destinationURL: URL, identity: ReverseIndexIdentity) throws {
        guard Self.valid(identity) else { throw ReverseIndexError.invalidIdentity }
        self.destinationURL = destinationURL
        self.identity = identity
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
                  snippet TEXT NOT NULL
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
        if Task.isCancelled { throw ReverseIndexError.cancelled }
        let headword = Self.cleanHeadword(entry.headword)
        let normalized = ReverseLookupNormalizer.normalizeDefinition(entry.plainText)
        guard !headword.isEmpty, ReverseLookupNormalizer.containsCJK(normalized) else {
            inserted += 1
            return
        }
        let definition = String(normalized.prefix(Self.maximumDefinitionCharacters))
        let snippet = ReverseLookupNormalizer.snippet(
            definition, maximum: Self.maximumSnippetCharacters
        )
        let lemma = headword.lowercased(with: Locale(identifier: "en_US_POSIX"))
        sqlite3_reset(entryStatement)
        sqlite3_clear_bindings(entryStatement)
        bind(headword, to: entryStatement, at: 1)
        bind(lemma, to: entryStatement, at: 2)
        bind(definition, to: entryStatement, at: 3)
        bind(snippet, to: entryStatement, at: 4)
        guard sqlite3_step(entryStatement) == SQLITE_DONE else {
            throw ReverseIndexError.writeFailed
        }
        let entryID = sqlite3_last_insert_rowid(database)
        let weightedTerms = ReverseLookupNormalizer.weightedTerms(in: definition)
        for (term, weight) in weightedTerms {
            sqlite3_reset(tokenStatement)
            sqlite3_clear_bindings(tokenStatement)
            bind(term, to: tokenStatement, at: 1)
            sqlite3_bind_int64(tokenStatement, 2, entryID)
            sqlite3_bind_int(tokenStatement, 3, Int32(weight))
            guard sqlite3_step(tokenStatement) == SQLITE_DONE else {
                throw ReverseIndexError.writeFailed
            }
        }
        inserted += 1
        applicable += 1
    }

    @discardableResult
    func finish() throws -> (entryCount: Int, applicableEntryCount: Int) {
        guard !finished, let database else { throw ReverseIndexError.writeFailed }
        finalizeStatements()
        do {
            try execute("COMMIT")
            try metadata("entry_count", String(inserted))
            try metadata("applicable_entry_count", String(applicable))
            try execute("PRAGMA optimize")
            var integrity: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1,
                                     &integrity, nil) == SQLITE_OK,
                  sqlite3_step(integrity) == SQLITE_ROW,
                  String(cString: sqlite3_column_text(integrity, 0)) == "ok" else {
                sqlite3_finalize(integrity)
                throw ReverseIndexError.corrupt
            }
            sqlite3_finalize(integrity)
            sqlite3_close(database)
            self.database = nil
            let fileDescriptor = open(temporaryURL.path, O_RDONLY)
            if fileDescriptor >= 0 {
                _ = fsync(fileDescriptor)
                close(fileDescriptor)
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL, withItemAt: temporaryURL,
                    backupItemName: nil, options: []
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            finished = true
            return (inserted, applicable)
        } catch {
            abort()
            throw error
        }
    }

    func abort() {
        finalizeStatements()
        if let database {
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
                "INSERT INTO entries(headword,lemma,definition,snippet) VALUES(?1,?2,?3,?4)",
                -1, &entryStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database,
                "INSERT OR IGNORE INTO terms(term,entry_id,weight) VALUES(?1,?2,?3)",
                -1, &tokenStatement, nil) == SQLITE_OK else {
            throw ReverseIndexError.writeFailed
        }
    }

    private func finalizeStatements() {
        sqlite3_finalize(entryStatement)
        sqlite3_finalize(tokenStatement)
        entryStatement = nil
        tokenStatement = nil
    }

    private func insertMetadata() throws {
        let values: [(String, String)] = [
            ("reverse_schema_version", String(ReverseIndexIdentity.schemaVersion)),
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
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ReverseIndexError.writeFailed
        }
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReverseIndexError.writeFailed
        }
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

actor ReverseLookupService {
    private var descriptors: [ReverseIndexDescriptor]
    private var cache: [String: [ReverseLookupResult]] = [:]

    init(descriptors: [ReverseIndexDescriptor] = []) {
        self.descriptors = descriptors
    }

    func replaceDescriptors(_ values: [ReverseIndexDescriptor]) {
        descriptors = values
        cache.removeAll()
    }

    func lookup(_ source: String, maximumResults: Int = 20) async
        -> [ReverseLookupResult] {
        let query = ReverseLookupNormalizer.normalizeQuery(source)
        guard !query.isEmpty else { return [] }
        if let cached = cache[query] { return Array(cached.prefix(maximumResults)) }
        var output: [ReverseLookupResult] = []
        for descriptor in descriptors {
            guard !Task.isCancelled else { break }
            if let values = try? Self.query(query, descriptor: descriptor) {
                output.append(contentsOf: values)
            }
        }
        var seen: Set<String> = []
        output = output.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.headword.localizedStandardCompare($1.headword) == .orderedAscending
        }.filter {
            seen.insert($0.headword.lowercased()).inserted
        }
        cache[query] = Array(output.prefix(50))
        return Array(output.prefix(maximumResults))
    }

    nonisolated private static func query(_ query: String,
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
        let sql = """
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
            let snippet = string(statement, 2)
            let weight = Int(sqlite3_column_int(statement, 3))
            let matchedTerms = Int(sqlite3_column_int(statement, 4))
            let exact = definition.contains(query)
            let allTerms = matchedTerms == terms.count
            let confidence: ReverseLookupConfidence = exact ? .high : (allTerms ? .medium : .low)
            let reason = exact ? "中文释义精确短语命中" :
                (allTerms ? "全部 CJK n-gram 命中" : "部分 CJK n-gram 命中")
            let score = (exact ? 10_000 : 0) + (allTerms ? 2_000 : 0) +
                weight * 4 - descriptor.identity.queryPriority * 100 -
                Int(clamping: descriptor.identity.sortPosition)
            output.append(ReverseLookupResult(
                headword: headword, definitionSnippet: snippet,
                dictionaryID: descriptor.identity.dictionaryID,
                dictionaryName: descriptor.identity.dictionaryName,
                matchReason: reason, confidence: confidence, score: score
            ))
        }
        return output
    }

    nonisolated private static func validate(_ database: OpaquePointer,
                                             identity: ReverseIndexIdentity) throws {
        let expected = [
            "reverse_schema_version": String(ReverseIndexIdentity.schemaVersion),
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
