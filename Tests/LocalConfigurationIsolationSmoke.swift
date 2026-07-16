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
enum LocalConfigurationIsolationSmoke {
    static func main() throws {
        let fileManager = FileManager.default
        let productionURL = AppConfig.productionConfigurationURL(fileManager: fileManager)
        let expectedSuffix = "Library/Application Support/LocalDictionary/LegacyConfig/local.json"
        try expect(productionURL.path.hasSuffix(expectedSuffix),
                   "production configuration location is incorrect")
        try expect(productionURL.path.hasPrefix(fileManager.homeDirectoryForCurrentUser.path),
                   "production configuration escaped the isolated home")

        try? fileManager.removeItem(at: productionURL)
        try expect(AppConfig.loadIfPresent(fileManager: fileManager) == nil,
                   "missing external configuration was not optional")

        try fileManager.createDirectory(at: productionURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: productionURL)
        try expect(AppConfig.loadIfPresent(fileManager: fileManager) == nil,
                   "corrupt external configuration was not ignored safely")

        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("LocalDictionary-ExternalConfig-\(UUID().uuidString)",
                                    isDirectory: true)
        try fileManager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixture) }

        let configuration = try makeConfigurationFixture(in: fixture)
        try configuration.data.write(to: productionURL, options: .atomic)
        guard let loaded = AppConfig.loadIfPresent(fileManager: fileManager) else {
            throw SmokeFailure.failed("valid external configuration did not load")
        }

        let indexSnapshots = try configuration.indexes.map {
            (try Data(contentsOf: $0), try modificationDate(at: $0))
        }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let adapter = LegacyDictionaryConfigAdapter(fileManager: fileManager)
        let first = adapter.adapt(loaded, into: .empty(now: now), now: now)
        try expect(first.sortedDictionaries.map(\.dictionaryID) == [
            DictionarySourceID.oxfordOALD8.rawValue,
            DictionarySourceID.century21.rawValue,
            DictionarySourceID.newOxford.rawValue,
            DictionarySourceID.medicalEnglishChinese.rawValue,
            DictionarySourceID.affixRootA.rawValue
        ], "legacy dictionary order changed")
        try expect(first.dictionaries.count == 5 && first.dictionaries.allSatisfy {
            $0.sourceKind == .legacyReference && $0.queryLevel == .preferred &&
                $0.state == .ready && $0.relativePaths == .empty
        }, "external configuration did not create five path-free legacy descriptors")

        let second = adapter.adapt(loaded, into: first,
                                   now: now.addingTimeInterval(60))
        try expect(second == first, "repeated startup duplicated legacy descriptors")
        let catalogJSON = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        try expect(!catalogJSON.contains(fixture.path),
                   "legacy absolute paths leaked into the catalog")

        for (offset, indexURL) in configuration.indexes.enumerated() {
            try expect(try Data(contentsOf: indexURL) == indexSnapshots[offset].0,
                       "legacy index content was modified")
            try expect(try modificationDate(at: indexURL) == indexSnapshots[offset].1,
                       "legacy index timestamp was modified")
            try expect(!fileManager.fileExists(atPath: indexURL.path + ".building"),
                       "legacy index build artifact was created")
        }

        let explicitURL = fixture.appendingPathComponent("explicit-local.json")
        try configuration.data.write(to: explicitURL)
        try expect(AppConfig.loadIfPresent(at: explicitURL) != nil,
                   "explicit test injection did not load")
        try fileManager.removeItem(at: productionURL)
        try expect(AppConfig.loadIfPresent(fileManager: fileManager) == nil,
                   "explicit injection changed the production default")

        try expect(AppConfig.ConfigError.missing.localizedDescription ==
                   "缺少本机配置 local.json",
                   "safe missing-config error changed unexpectedly")
        try expect(!AppConfig.ConfigError.missing.localizedDescription.contains(fixture.path),
                   "configuration error exposed an absolute path")

        print("LocalConfigurationIsolationSmoke PASS (10/10)")
    }

    private static func makeConfigurationFixture(
        in directory: URL
    ) throws -> (data: Data, indexes: [URL]) {
        let names = ["oxford", "century21", "new-oxford", "medical", "affix-root"]
        var dictionaries: [URL] = []
        var indexes: [URL] = []
        for (offset, name) in names.enumerated() {
            let dictionary = directory.appendingPathComponent("\(name).mdx")
            let index = directory.appendingPathComponent("\(name).sqlite")
            try Data("synthetic-dictionary-\(offset)".utf8).write(to: dictionary)
            try createIndex(at: index, entries: UInt64(10 + offset))
            dictionaries.append(dictionary)
            indexes.append(index)
        }
        let object: [String: Any] = [
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
        return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                indexes)
    }

    private static func createIndex(at url: URL, entries: UInt64) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SmokeFailure.failed("could not create synthetic index")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database,
                           "CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);",
                           nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database,
                           "INSERT INTO metadata VALUES('schema_version','1'),('entry_count','\(entries)');",
                           nil, nil, nil) == SQLITE_OK else {
            throw SmokeFailure.failed("could not initialize synthetic index")
        }
    }

    private static func modificationDate(at url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw SmokeFailure.failed("synthetic index has no modification date")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool,
                               _ message: String) throws {
        guard try condition() else { throw SmokeFailure.failed(message) }
    }
}
