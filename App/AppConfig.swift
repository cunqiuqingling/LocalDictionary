import Foundation

enum DictionarySourceID: String {
    case oxfordOALD8 = "oxford-oald8"
    case century21 = "century21"
    case newOxford = "new-oxford"
    case medicalEnglishChinese = "medical-en-zh-2003"
    case affixRootA = "affix-root-a"
}

struct SupplementalDictionaryConfiguration {
    let id: DictionarySourceID
    let displayName: String
    let priority: Int
    let dictionaryPath: String
    let indexPath: String
}

struct AppConfig: Decodable {
    let primaryDictionary: String
    let indexPath: String
    let century21Dictionary: String?
    let century21IndexPath: String?
    let newOxfordDictionary: String?
    let newOxfordIndexPath: String?
    let medicalDictionary: String?
    let medicalIndexPath: String?
    let affixRootDictionary: String?
    let affixRootIndexPath: String?

    var supplementalDictionaries: [SupplementalDictionaryConfiguration] {
        var configurations: [SupplementalDictionaryConfiguration] = []
        appendConfiguration(to: &configurations,
                            id: .century21,
                            displayName: "21世纪大英汉词典",
                            priority: 1,
                            dictionaryPath: century21Dictionary,
                            indexPath: century21IndexPath)
        appendConfiguration(to: &configurations,
                            id: .newOxford,
                            displayName: "新牛津英文",
                            priority: 2,
                            dictionaryPath: newOxfordDictionary,
                            indexPath: newOxfordIndexPath)
        appendConfiguration(to: &configurations,
                            id: .medicalEnglishChinese,
                            displayName: "英中医学辞海",
                            priority: 3,
                            dictionaryPath: medicalDictionary,
                            indexPath: medicalIndexPath)
        appendConfiguration(to: &configurations,
                            id: .affixRootA,
                            displayName: "词根词缀",
                            priority: 4,
                            dictionaryPath: affixRootDictionary,
                            indexPath: affixRootIndexPath)
        return configurations.sorted { $0.priority < $1.priority }
    }

    static func load() throws -> AppConfig {
        guard let url = Bundle.main.url(forResource: "local", withExtension: "json") else {
            throw ConfigError.missing
        }
        return try load(from: url)
    }

    static func loadIfPresent(in bundle: Bundle = .main) -> AppConfig? {
        guard let url = bundle.url(forResource: "local", withExtension: "json") else {
            return nil
        }
        return try? load(from: url)
    }

    static func loadIfPresent(at url: URL) -> AppConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? load(from: url)
    }

    static func load(from url: URL) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    }

    enum ConfigError: LocalizedError {
        case missing

        var errorDescription: String? {
            "缺少本机配置 local.json"
        }
    }

    private func appendConfiguration(
        to configurations: inout [SupplementalDictionaryConfiguration],
        id: DictionarySourceID,
        displayName: String,
        priority: Int,
        dictionaryPath: String?,
        indexPath: String?
    ) {
        guard let dictionaryPath,
              let indexPath,
              !dictionaryPath.isEmpty,
              !indexPath.isEmpty else { return }
        configurations.append(SupplementalDictionaryConfiguration(
            id: id,
            displayName: displayName,
            priority: priority,
            dictionaryPath: dictionaryPath,
            indexPath: indexPath
        ))
    }
}
