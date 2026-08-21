import Foundation
import SQLite3

enum LegacyDictionaryRegistrationRetirementError: LocalizedError, Equatable, Sendable {
    case dictionaryNotFound
    case notLegacyExternalReference
    case alreadyRetired

    var errorDescription: String? {
        switch self {
        case .dictionaryNotFound: return "找不到要移除的旧配置词典。"
        case .notLegacyExternalReference: return "该词典不是可退役的旧配置登记。"
        case .alreadyRetired: return "该旧配置登记已经移除。"
        }
    }
}

/// Pure Catalog mutation for removing a legacy registration.  It deliberately has no file-system
/// dependency: external MDX/MDD, SQLite and local.json are outside App deletion authority.
enum LegacyDictionaryRegistrationRetirement {
    static func retiring(
        dictionaryID: String,
        in catalog: DictionaryCatalog,
        now: Date = Date()
    ) throws -> DictionaryCatalog {
        guard let index = catalog.dictionaries.firstIndex(where: {
            $0.dictionaryID == dictionaryID
        }) else { throw LegacyDictionaryRegistrationRetirementError.dictionaryNotFound }
        let current = catalog.dictionaries[index]
        guard current.sourceKind == .legacyReference,
              current.storageOwnership == .externalReference else {
            throw LegacyDictionaryRegistrationRetirementError.notLegacyExternalReference
        }
        guard !current.isRetiredLegacyRegistration else {
            throw LegacyDictionaryRegistrationRetirementError.alreadyRetired
        }
        var updated = catalog
        updated.dictionaries[index].enabled = false
        updated.dictionaries[index].state = .disabled
        updated.dictionaries[index].retiredLegacyRegistrationAt = now
        updated.dictionaries[index].updatedAt = now
        updated.updatedAt = now

        let active = updated.dictionaries.filter { !$0.isRetiredLegacyRegistration }
            .sorted {
                if $0.sortPosition != $1.sortPosition {
                    return $0.sortPosition < $1.sortPosition
                }
                return $0.dictionaryID < $1.dictionaryID
            }
        let retired = updated.dictionaries.filter(\.isRetiredLegacyRegistration)
            .sorted { $0.dictionaryID < $1.dictionaryID }
        let positions = Dictionary(uniqueKeysWithValues: (active + retired).enumerated().map {
            ($0.element.dictionaryID, Int64($0.offset + 1))
        })
        for descriptorIndex in updated.dictionaries.indices {
            updated.dictionaries[descriptorIndex].sortPosition =
                positions[updated.dictionaries[descriptorIndex].dictionaryID] ??
                updated.dictionaries[descriptorIndex].sortPosition
        }
        return updated
    }
}

struct LegacyDictionaryConfigAdapter {
    private struct Definition {
        let id: DictionarySourceID
        let displayName: String
        let sortPosition: Int64
        let dictionaryPath: String
        let indexPath: String
        let formatterIdentifier: String
        let capabilities: DictionaryCapabilities
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func adapt(_ config: AppConfig,
               into catalog: DictionaryCatalog,
               now: Date = Date()) -> DictionaryCatalog {
        var byID = Dictionary(uniqueKeysWithValues: catalog.dictionaries.map {
            ($0.dictionaryID, $0)
        })
        var changed = false

        for definition in definitions(from: config) {
            let inspection = inspect(dictionaryPath: definition.dictionaryPath,
                                     indexPath: definition.indexPath)
            let identifier = definition.id.rawValue
            if let existing = byID[identifier] {
                guard existing.sourceKind == .legacyReference else { continue }
                // The Catalog tombstone is the user's explicit removal choice.  Re-adapting
                // local.json must not make that external reference reappear on every launch.
                guard !existing.isRetiredLegacyRegistration else { continue }
                var refreshed = existing
                refreshed.state = inspection.state
                refreshed.indexMetadata = inspection.metadata
                if refreshed != existing {
                    refreshed.updatedAt = now
                    byID[identifier] = refreshed
                    changed = true
                }
                continue
            }

            byID[identifier] = DictionaryDescriptor(
                dictionaryID: identifier,
                displayName: definition.displayName,
                sourceKind: .legacyReference,
                queryLevel: .preferred,
                sortPosition: definition.sortPosition,
                enabled: true,
                state: inspection.state,
                indexMetadata: inspection.metadata,
                formatterIdentifier: definition.formatterIdentifier,
                capabilities: definition.capabilities,
                relativePaths: .empty,
                createdAt: now,
                updatedAt: now,
                storageOwnership: .externalReference,
                openResourceMetadata: nil
            )
            changed = true
        }

        guard changed else { return catalog }
        var updated = catalog
        updated.schemaVersion = DictionaryCatalog.currentSchemaVersion
        updated.updatedAt = now
        updated.dictionaries = Array(byID.values).sorted {
            if $0.queryLevel.rank != $1.queryLevel.rank {
                return $0.queryLevel.rank < $1.queryLevel.rank
            }
            if $0.sortPosition != $1.sortPosition {
                return $0.sortPosition < $1.sortPosition
            }
            return $0.dictionaryID < $1.dictionaryID
        }
        return updated
    }

    func markingUnresolvableLegacyReferencesUnavailable(
        in catalog: DictionaryCatalog,
        now: Date = Date()
    ) -> DictionaryCatalog {
        var updated = catalog
        var changed = false
        updated.dictionaries = catalog.dictionaries.map { dictionary in
            guard dictionary.sourceKind == .legacyReference,
                  !dictionary.isRetiredLegacyRegistration,
                  dictionary.state != .unavailable else { return dictionary }
            var unavailable = dictionary
            unavailable.state = .unavailable
            unavailable.updatedAt = now
            changed = true
            return unavailable
        }
        if changed { updated.updatedAt = now }
        return updated
    }

    private func definitions(from config: AppConfig) -> [Definition] {
        var values: [Definition] = []
        append(&values, id: .oxfordOALD8, displayName: "牛津高阶 8", position: 1,
               dictionaryPath: config.primaryDictionary, indexPath: config.indexPath,
               formatter: DictionaryFormatterIdentifier.oxfordOALD8V1,
               capabilities: .oxford)
        append(&values, id: .century21, displayName: "21 世纪大英汉词典", position: 2,
               dictionaryPath: config.century21Dictionary,
               indexPath: config.century21IndexPath,
               formatter: DictionaryFormatterIdentifier.century21V1,
               capabilities: .century21)
        append(&values, id: .newOxford, displayName: "新牛津英文", position: 3,
               dictionaryPath: config.newOxfordDictionary,
               indexPath: config.newOxfordIndexPath,
               formatter: DictionaryFormatterIdentifier.newOxfordV1,
               capabilities: .newOxford)
        append(&values, id: .medicalEnglishChinese, displayName: "英中医学辞海", position: 4,
               dictionaryPath: config.medicalDictionary,
               indexPath: config.medicalIndexPath,
               formatter: DictionaryFormatterIdentifier.medicalEnglishChineseV1,
               capabilities: .medical)
        append(&values, id: .affixRootA, displayName: "The Affix Root of Vocabulary", position: 5,
               dictionaryPath: config.affixRootDictionary,
               indexPath: config.affixRootIndexPath,
               formatter: DictionaryFormatterIdentifier.affixRootAV1,
               capabilities: .affixRoot)
        return values
    }

    private func append(_ values: inout [Definition], id: DictionarySourceID,
                        displayName: String, position: Int64,
                        dictionaryPath: String?, indexPath: String?, formatter: String,
                        capabilities: DictionaryCapabilities) {
        guard let dictionaryPath, let indexPath,
              !dictionaryPath.isEmpty, !indexPath.isEmpty else { return }
        values.append(Definition(id: id, displayName: displayName,
                                 sortPosition: position,
                                 dictionaryPath: dictionaryPath, indexPath: indexPath,
                                 formatterIdentifier: formatter,
                                 capabilities: capabilities))
    }

    private func inspect(dictionaryPath: String, indexPath: String)
        -> (state: DictionaryState, metadata: DictionaryIndexMetadata) {
        let dictionaryURL = URL(fileURLWithPath: dictionaryPath)
        let indexURL = URL(fileURLWithPath: indexPath)
        let dictionaryAttributes = try? fileManager.attributesOfItem(atPath: dictionaryPath)
        let indexAttributes = try? fileManager.attributesOfItem(atPath: indexPath)
        let sourceSize = Self.unsignedSize(dictionaryAttributes?[.size])
        let sourceModifiedAt = dictionaryAttributes?[.modificationDate] as? Date
        let indexSize = Self.unsignedSize(indexAttributes?[.size])
        let indexedAt = indexAttributes?[.modificationDate] as? Date
        var metadata = DictionaryIndexMetadata(
            schemaVersion: nil,
            entryCount: nil,
            indexFileSize: indexSize,
            sourceFileSize: sourceSize,
            sourceModifiedAt: sourceModifiedAt,
            sourceSHA256: nil,
            indexedAt: indexedAt
        )

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dictionaryURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return (.unavailable, metadata) }
        guard fileManager.fileExists(atPath: indexURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return (.unavailable, metadata) }
        guard let indexValues = Self.readIndexMetadata(at: indexURL) else {
            return (.invalid, metadata)
        }
        metadata.schemaVersion = indexValues.schemaVersion
        metadata.entryCount = indexValues.entryCount
        return (.ready, metadata)
    }

    private static func readIndexMetadata(at url: URL)
        -> (schemaVersion: Int?, entryCount: UInt64?)? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "SELECT key, value FROM metadata WHERE key IN ('schema_version', 'entry_count');"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var schemaVersion: Int?
        var entryCount: UInt64?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyBytes = sqlite3_column_text(statement, 0),
                  let valueBytes = sqlite3_column_text(statement, 1) else { continue }
            let key = String(cString: keyBytes)
            let value = String(cString: valueBytes)
            if key == "schema_version" { schemaVersion = Int(value) }
            if key == "entry_count" { entryCount = UInt64(value) }
        }
        guard schemaVersion != nil, entryCount != nil else { return nil }
        return (schemaVersion, entryCount)
    }

    private static func unsignedSize(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }
}

private extension DictionaryCapabilities {
    static let oxford = DictionaryCapabilities(
        englishLookup: true, chineseLookup: false, bilingualDefinitions: true,
        pronunciations: true, examples: true, synonyms: true, antonyms: true,
        morphology: true, semanticRelations: true)
    static let century21 = DictionaryCapabilities(
        englishLookup: true, chineseLookup: false, bilingualDefinitions: true,
        pronunciations: true, examples: true, synonyms: true, antonyms: true,
        morphology: true, semanticRelations: true)
    static let newOxford = DictionaryCapabilities(
        englishLookup: true, chineseLookup: false, bilingualDefinitions: true,
        pronunciations: true, examples: true, synonyms: true, antonyms: true,
        morphology: true, semanticRelations: true)
    static let medical = DictionaryCapabilities(
        englishLookup: true, chineseLookup: false, bilingualDefinitions: true,
        pronunciations: false, examples: false, synonyms: true, antonyms: false,
        morphology: false, semanticRelations: true)
    static let affixRoot = DictionaryCapabilities(
        englishLookup: true, chineseLookup: false, bilingualDefinitions: true,
        pronunciations: false, examples: true, synonyms: false, antonyms: false,
        morphology: true, semanticRelations: true)
}
