import Foundation

struct AppConfig: Decodable {
    let primaryDictionary: String
    let indexPath: String

    static func load() throws -> AppConfig {
        guard let url = Bundle.main.url(forResource: "local", withExtension: "json") else {
            throw ConfigError.missing
        }
        return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    }

    enum ConfigError: LocalizedError {
        case missing

        var errorDescription: String? {
            "缺少本机配置 local.json"
        }
    }
}

