import Foundation

struct FrankfurterProvider: FXRateProvider {
    /// `api.frankfurter.app` now answers 301 to `api.frankfurter.dev/v1`.
    ///
    /// URLSession follows that redirect, so rates kept arriving and nothing
    /// looked wrong — which is the danger. The old host is one redirect-policy
    /// change away from failing silently, and a silent FX failure means every
    /// foreign position shows a dash with no explanation. The canonical host is
    /// requested directly. Query form verified unchanged: `?from=USD&to=EUR`
    /// returns `{"amount":1.0,"base":"USD","date":…,"rates":{"EUR":0.86693}}`.
    static let baseURL = "https://api.frankfurter.dev/v1"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func rate(from: String, to: String, on date: Date?) async throws -> FXRate {
        let adjusted = Self.adjustToBusinessDay(date ?? Date())
        let dateStr = Self.formatDate(adjusted)

        guard let url = URL(string: "\(Self.baseURL)/\(dateStr)?from=\(from)&to=\(to)") else {
            throw FXError.invalidRequest
        }

        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FXError.networkError
        }

        let decoded = try JSONDecoder().decode(FrankfurterResponse.self, from: data)

        // The base is read, not assumed — ponto J. The response says which
        // currency it is quoting *from*, and until now that field was decoded
        // and discarded: a reply about the wrong base was indistinguishable
        // from a reply about the right one, which is the same blindness the
        // return type is being changed to end.
        guard decoded.base.caseInsensitiveCompare(from) == .orderedSame else {
            throw FXError.currencyNotFound(from)
        }

        guard let rateDouble = decoded.rates[to] else {
            throw FXError.currencyNotFound(to)
        }

        let value = Decimal(string: String(rateDouble)) ?? Decimal(rateDouble)
        // Labelled with what was asked *and* confirmed, so the caller can check
        // rather than trust.
        guard let rate = FXRate(from: from, to: to, value: value) else {
            throw FXError.currencyNotFound(to)
        }
        return rate
    }

    static func adjustToBusinessDay(_ date: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: date)
        switch weekday {
        case 1: return cal.date(byAdding: .day, value: -2, to: date)!
        case 7: return cal.date(byAdding: .day, value: -1, to: date)!
        default: return date
        }
    }

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        // Ponto K. A fixed format needs a fixed locale and calendar: on a device
        // set to the Buddhist calendar `yyyy` writes 2569, which is both a URL
        // the API rejects and a cache key that never hits. `AlphaVantageProvider`
        // already does this; the two now read the same.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

nonisolated struct FrankfurterResponse: Decodable, Sendable {
    let base: String
    let date: String
    let rates: [String: Double]
}

nonisolated enum FXError: Error, LocalizedError {
    case invalidRequest
    case networkError
    case currencyNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "Pedido FX inválido"
        case .networkError: "Erro de rede ao obter taxa de câmbio"
        case .currencyNotFound(let c): "Moeda \(c) não encontrada"
        }
    }
}
