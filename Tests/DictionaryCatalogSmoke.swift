import Foundation
import SQLite3

private enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
@MainActor
enum DictionaryCatalogSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-CatalogSmoke-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try testEmptyCatalog(root: root)
        try testAtomicSaveAndReload(root: root)
        try testBackupRecovery(root: root)
        try testDoubleCorruption(root: root)
        try testMutationsRejectUnavailableCatalog(root: root)
        try testLoadedBackupMutationPreservesPreviousBackup(root: root)
        try testTwoStoreMutationsMergeLatestCatalog(root: root)
        try testExplicitV1Migration(root: root)
        try testMissingLegacyConfiguration(root: root)
        try testLegacyAdaptationAndIdempotence(root: root)
        try testStableSort()
        try testAbsolutePathRejection(root: root)
        print("DictionaryCatalogSmoke PASS")
    }

    private static func testEmptyCatalog(root: URL) throws {
        let store = makeStore(root: root, name: "empty")
        let loaded = store.load()
        try expect(loaded.schemaVersion == DictionaryCatalog.currentSchemaVersion && loaded.dictionaries.isEmpty,
                   "empty catalog did not load")
    }

    private static func testAtomicSaveAndReload(root: URL) throws {
        let store = makeStore(root: root, name: "atomic")
        let catalog = sampleCatalog()
        try store.save(catalog)
        try expect(store.load() == catalog, "catalog save/reload mismatch")
        try expect(FileManager.default.fileExists(atPath: store.catalogURL.path),
                   "primary catalog missing")
        try expect(!FileManager.default.fileExists(atPath: store.backupURL.path),
                   "first v2 commit fabricated a previous backup")
    }

    private static func testBackupRecovery(root: URL) throws {
        let store = makeStore(root: root, name: "backup")
        let catalog = sampleCatalog()
        try store.save(catalog)
        var updated = catalog
        updated.updatedAt = catalog.updatedAt.addingTimeInterval(1)
        try store.save(updated)
        try Data("not-json".utf8).write(to: store.catalogURL)
        try expect(store.load() == catalog, "valid backup was not recovered")
    }

    private static func testDoubleCorruption(root: URL) throws {
        let store = makeStore(root: root, name: "double-corrupt")
        try FileManager.default.createDirectory(at: store.directoryURL,
                                                withIntermediateDirectories: true)
        try Data("broken-primary".utf8).write(to: store.catalogURL)
        try Data("broken-backup".utf8).write(to: store.backupURL)
        let loaded = store.loadResult()
        try expect(loaded.catalog == nil && loaded.provenance == .corrupt,
                   "double corruption was silently treated as an empty catalog")
    }

    private static func testMutationsRejectUnavailableCatalog(root: URL) throws {
        let corrupt = makeStore(root: root, name: "mutation-corrupt")
        try FileManager.default.createDirectory(at: corrupt.directoryURL, withIntermediateDirectories: true)
        let primary = Data("broken-primary".utf8)
        let backup = Data("broken-backup".utf8)
        try primary.write(to: corrupt.catalogURL)
        try backup.write(to: corrupt.backupURL)
        let primaryBefore = try Data(contentsOf: corrupt.catalogURL)
        let backupBefore = try Data(contentsOf: corrupt.backupURL)
        do {
            _ = try corrupt.mutate { catalog, _ in catalog.updatedAt = Date() }
            throw SmokeFailure.failed("corrupt catalog mutation unexpectedly succeeded")
        } catch DictionaryCatalogStoreError.catalogCorrupt {
            // Expected: mutation cannot transform a damaged catalog into an empty one.
        }
        let primaryAfter = try Data(contentsOf: corrupt.catalogURL)
        let backupAfter = try Data(contentsOf: corrupt.backupURL)
        try expect(primaryAfter == primaryBefore && backupAfter == backupBefore,
                   "corrupt catalog evidence changed during rejected mutation")

        let unsupported = makeStore(root: root, name: "mutation-unsupported")
        try FileManager.default.createDirectory(at: unsupported.directoryURL, withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(sampleCatalog())
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["schemaVersion"] = 999
        let unsupportedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try unsupportedData.write(to: unsupported.catalogURL)
        do {
            _ = try unsupported.mutate { catalog, _ in catalog.updatedAt = Date() }
            throw SmokeFailure.failed("unsupported catalog mutation unexpectedly succeeded")
        } catch DictionaryCatalogStoreError.unsupportedCatalogVersion {
            // Expected.
        }
        let unsupportedAfter = try Data(contentsOf: unsupported.catalogURL)
        try expect(unsupportedAfter == unsupportedData,
                   "unsupported catalog was rewritten")
    }

    private static func testLoadedBackupMutationPreservesPreviousBackup(root: URL) throws {
        let store = makeStore(root: root, name: "backup-mutation")
        let original = sampleCatalog()
        try store.save(original)
        var second = original
        second.updatedAt = original.updatedAt.addingTimeInterval(1)
        try store.save(second)
        let previousBackup = try Data(contentsOf: store.backupURL)
        try Data("damaged-primary".utf8).write(to: store.catalogURL)
        let mutation = try store.mutate { catalog, provenance in
            try expect(provenance == .loadedBackup, "mutation did not use valid backup")
            catalog.updatedAt = catalog.updatedAt.addingTimeInterval(1)
        }
        try expect(mutation.catalog.updatedAt == original.updatedAt.addingTimeInterval(1),
                   "loaded backup mutation did not update the recovered catalog")
        let backupAfter = try Data(contentsOf: store.backupURL)
        try expect(backupAfter == previousBackup,
                   "loaded backup mutation overwrote previous valid backup")
        try expect(store.loadResult().provenance == .loadedPrimary,
                   "loaded backup mutation did not safely republish primary")
    }

    private static func testTwoStoreMutationsMergeLatestCatalog(root: URL) throws {
        let directory = root.appendingPathComponent("two-store", isDirectory: true)
        let first = DictionaryCatalogStore(directoryURL: directory)
        let second = DictionaryCatalogStore(directoryURL: directory)
        try first.save(sampleCatalog())
        _ = try first.mutate { catalog, _ in
            catalog.dictionaries.append(descriptor(id: "first", level: .normal, position: 11,
                                                    now: catalog.updatedAt))
        }
        _ = try second.mutate { catalog, _ in
            catalog.dictionaries.append(descriptor(id: "second", level: .normal, position: 12,
                                                    now: catalog.updatedAt))
        }
        try expect(Set(first.load().dictionaries.map(\.dictionaryID)) == Set(["sample", "first", "second"]),
                   "two store mutations lost a latest durable descriptor")
    }

    private static func testMissingLegacyConfiguration(root: URL) throws {
        let missing = root.appendingPathComponent("does-not-exist/local.json")
        try expect(AppConfig.loadIfPresent(at: missing) == nil,
                   "missing local.json was not treated as optional")
    }

    private static func testExplicitV1Migration(root: URL) throws {
        let store = makeStore(root: root, name: "v1-migration")
        let v2 = sampleCatalog()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var object = try JSONSerialization.jsonObject(with: encoder.encode(v2)) as! [String: Any]
        object["schemaVersion"] = 1
        var values = object["dictionaries"] as! [[String: Any]]
        values[0].removeValue(forKey: "storageOwnership")
        values[0].removeValue(forKey: "openResourceMetadata")
        object["dictionaries"] = values
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: store.legacyCatalogURL)
        let loaded = store.loadResult()
        try expect(loaded.provenance == .migratedFromV1,
                   "v1 catalog was not explicitly migrated")
        try expect(loaded.catalog?.dictionaries.first?.storageOwnership == .appManagedImported,
                   "managed local v1 ownership was not migrated")
        try expect(FileManager.default.fileExists(atPath: store.legacyCatalogURL.path) &&
                   !FileManager.default.fileExists(atPath: store.catalogURL.path),
                   "v1 migration modified legacy input before v2 save")
    }

    private static func testLegacyAdaptationAndIdempotence(root: URL) throws {
        let fixture = root.appendingPathComponent("legacy-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let names = ["oxford", "century21", "new-oxford", "medical", "affix-root"]
        var dictionaries: [URL] = []
        var indexes: [URL] = []
        for (offset, name) in names.enumerated() {
            let dictionary = fixture.appendingPathComponent("\(name).mdx")
            let index = fixture.appendingPathComponent("\(name).sqlite")
            try Data("fixture-\(name)".utf8).write(to: dictionary)
            try createIndex(at: index, entries: UInt64(1_000 + offset))
            dictionaries.append(dictionary)
            indexes.append(index)
        }

        let configURL = fixture.appendingPathComponent("local.json")
        let configObject: [String: Any] = [
            "primaryDictionary": dictionaries[0].path,
            "indexPath": indexes[0].path,
            "century21Dictionary": dictionaries[1].path,
            "century21IndexPath": indexes[1].path,
            "newOxfordDictionary": dictionaries[2].path,
            "newOxfordIndexPath": indexes[2].path,
            "medicalDictionary": dictionaries[3].path,
            "medicalIndexPath": indexes[3].path,
            "affixRootDictionary": dictionaries[4].path,
            "affixRootIndexPath": indexes[4].path
        ]
        try JSONSerialization.data(withJSONObject: configObject,
                                   options: [.sortedKeys]).write(to: configURL)
        guard let config = AppConfig.loadIfPresent(at: configURL) else {
            throw SmokeFailure.failed("valid legacy local.json did not decode")
        }

        let indexSnapshots = try indexes.map {
            (try Data(contentsOf: $0), try modificationDate(at: $0))
        }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let adapter = LegacyDictionaryConfigAdapter()
        let first = adapter.adapt(config, into: .empty(now: now), now: now)
        try expect(first.dictionaries.count == 5, "legacy adapter did not create five records")
        try expect(first.sortedDictionaries.map(\.dictionaryID) == [
            DictionarySourceID.oxfordOALD8.rawValue,
            DictionarySourceID.century21.rawValue,
            DictionarySourceID.newOxford.rawValue,
            DictionarySourceID.medicalEnglishChinese.rawValue,
            DictionarySourceID.affixRootA.rawValue
        ], "legacy dictionary order changed")
        try expect(first.sortedDictionaries.map(\.sortPosition) == [1, 2, 3, 4, 5],
                   "legacy positions changed")
        try expect(first.dictionaries.allSatisfy {
            $0.sourceKind == .legacyReference && $0.queryLevel == .preferred &&
                $0.enabled && $0.state == .ready
        }, "legacy defaults are incorrect")
        try expect(first.sortedDictionaries.compactMap { $0.indexMetadata.entryCount } ==
                   [1_000, 1_001, 1_002, 1_003, 1_004],
                   "legacy entry counts were not read safely")

        let second = adapter.adapt(config, into: first,
                                   now: now.addingTimeInterval(60))
        try expect(second == first, "repeated adaptation duplicated or rewrote legacy records")

        var userAdjusted = first
        userAdjusted.dictionaries[0].queryLevel = .normal
        userAdjusted.dictionaries[0].sortPosition = 99
        let preserved = adapter.adapt(config, into: userAdjusted,
                                      now: now.addingTimeInterval(120))
        let adjustedID = userAdjusted.dictionaries[0].dictionaryID
        let preservedDictionary = preserved.dictionaries.first {
            $0.dictionaryID == adjustedID
        }
        try expect(preservedDictionary?.queryLevel == .normal &&
                   preservedDictionary?.sortPosition == 99,
                   "legacy adaptation reset a user-defined level or order")

        let unavailable = adapter.markingUnresolvableLegacyReferencesUnavailable(in: first,
                                                                                   now: now)
        try expect(unavailable.dictionaries.allSatisfy { $0.state == .unavailable },
                   "missing legacy configuration left stale ready states")

        let encoded = try JSONEncoder().encode(first)
        let json = String(decoding: encoded, as: UTF8.self)
        try expect(!json.contains(fixture.path), "catalog leaked a legacy absolute path")
        try expect(first.dictionaries.allSatisfy {
            $0.relativePaths == .empty
        }, "legacy catalog persisted source paths")

        for (index, url) in indexes.enumerated() {
            let afterData = try Data(contentsOf: url)
            let afterDate = try modificationDate(at: url)
            try expect(afterData == indexSnapshots[index].0 && afterDate == indexSnapshots[index].1,
                       "legacy index was modified")
            try expect(!FileManager.default.fileExists(atPath: url.path + ".building"),
                       "legacy adapter created an index build artifact")
        }
    }

    private static func testStableSort() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let values = [
            descriptor(id: "z", level: .normal, position: 2, now: now),
            descriptor(id: "b", level: .preferred, position: 1, now: now),
            descriptor(id: "a", level: .preferred, position: 1, now: now),
            descriptor(id: "c", level: .fallback, position: 0, now: now)
        ]
        let expected = ["a", "b", "z", "c"]
        for input in [values, Array(values.reversed()), Array(values.dropFirst()) + [values[0]]] {
            let catalog = DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion, createdAt: now,
                                            updatedAt: now, dictionaries: input)
            try expect(catalog.sortedDictionaries.map(\.dictionaryID) == expected,
                       "stable sort key changed with input order")
        }
    }

    private static func testAbsolutePathRejection(root: URL) throws {
        let store = makeStore(root: root, name: "unsafe-path")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var unsafe = descriptor(id: "unsafe", level: .normal, position: 1, now: now)
        unsafe.relativePaths = DictionaryRelativePaths(dictionary: "/private/dictionary.mdx",
                                                       resources: [], index: nil)
        let catalog = DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion, createdAt: now,
                                        updatedAt: now, dictionaries: [unsafe])
        do {
            try store.save(catalog)
            throw SmokeFailure.failed("absolute catalog path was accepted")
        } catch DictionaryCatalogValidationError.absoluteOrUnsafePath {
            // Expected.
        }
        try expect(!FileManager.default.fileExists(atPath: store.catalogURL.path),
                   "invalid catalog was written")
    }

    private static func sampleCatalog() -> DictionaryCatalog {
        let now = Date(timeIntervalSince1970: 1_750_000_000.123_456)
        return DictionaryCatalog(schemaVersion: DictionaryCatalog.currentSchemaVersion, createdAt: now, updatedAt: now,
                                 dictionaries: [
                                    descriptor(id: "sample", level: .normal,
                                               position: 10, now: now)
                                 ])
    }

    private static func descriptor(id: String, level: DictionaryQueryLevel,
                                   position: Int64, now: Date) -> DictionaryDescriptor {
        DictionaryDescriptor(
            dictionaryID: id,
            displayName: "Sample \(id)",
            sourceKind: .managedLocal,
            queryLevel: level,
            sortPosition: position,
            enabled: true,
            state: .ready,
            indexMetadata: DictionaryIndexMetadata(
                schemaVersion: 1, entryCount: 12, indexFileSize: 4096,
                sourceFileSize: 1024, sourceModifiedAt: now,
                sourceSHA256: nil, indexedAt: now),
            formatterIdentifier: "generic-safe.v1",
            capabilities: .unknown,
            relativePaths: DictionaryRelativePaths(
                dictionary: "Dictionaries/\(id)/source/dictionary.mdx",
                resources: [], index: "Indexes/\(id).sqlite"),
            createdAt: now,
            updatedAt: now)
    }

    private static func makeStore(root: URL, name: String) -> DictionaryCatalogStore {
        DictionaryCatalogStore(directoryURL: root.appendingPathComponent(name,
                                                                          isDirectory: true))
    }

    private static func createIndex(at url: URL, entries: UInt64) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SmokeFailure.failed("failed to create fixture index")
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO metadata(key, value) VALUES('schema_version', '1');
        INSERT INTO metadata(key, value) VALUES('entry_count', '\(entries)');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SmokeFailure.failed("failed to populate fixture index")
        }
    }

    private static func modificationDate(at url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values.contentModificationDate else {
            throw SmokeFailure.failed("fixture modification date missing")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw SmokeFailure.failed(message) }
    }
}
