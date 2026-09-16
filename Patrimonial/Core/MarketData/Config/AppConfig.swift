import Foundation

enum AppConfig {
    private static let secrets: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return dict
    }()

    private static func key(_ name: String) -> String {
        guard let key = secrets[name] as? String,
              !key.isEmpty,
              key != "YOUR_KEY_HERE" else {
            return ""
        }
        return key
    }

    static var finnhubAPIKey: String { key("FINNHUB_API_KEY") }
    static var twelveDataAPIKey: String { key("TWELVEDATA_API_KEY") }
    static var alphaVantageAPIKey: String { key("ALPHAVANTAGE_API_KEY") }

    static var hasFinnhubKey: Bool { !finnhubAPIKey.isEmpty }
    static var hasTwelveDataKey: Bool { !twelveDataAPIKey.isEmpty }
    static var hasAlphaVantageKey: Bool { !alphaVantageAPIKey.isEmpty }

    static var proxyURL: String { key("PROXY_URL") }
    static var proxySecret: String { key("PROXY_SECRET") }
    static var hasProxy: Bool { !proxyURL.isEmpty }
}
