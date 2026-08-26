import Foundation

/// A rate source for tests that **has a direction**.
///
/// The old version answered `1` for any pair it did not recognise, which made
/// it complicit in the failure it was standing in for: ask it the wrong way
/// round and it returned a rate that left every euro figure looking plausible.
/// A stub that cannot be asked the wrong question cannot help find the code that
/// asks it.
///
/// Now: pairs it knows are answered, a currency against itself is 1, and
/// anything else throws. `EUR→USD` is *not* silently derived from `USD→EUR` —
/// deriving it is precisely the inversion under test.
struct MockFXRateProvider: FXRateProvider {
    var mockRates: [String: Decimal] = [:]
    var shouldFail = false
    var callCount = 0

    mutating func setRate(from: String, to: String, date: String, rate: Decimal) {
        mockRates["\(from):\(to):\(date)"] = rate
    }

    static let knownRates: [String: Decimal] = [
        "USD:EUR": Decimal(string: "0.92")!,
        "GBP:EUR": Decimal(string: "1.16")!,
    ]

    func rate(from: String, to: String, on date: Date?) async throws -> FXRate {
        if shouldFail { throw FXError.networkError }
        let dateStr = FrankfurterProvider.formatDate(date ?? Date())
        let value: Decimal
        if let r = mockRates["\(from):\(to):\(dateStr)"] {
            value = r
        } else if from == to {
            value = 1
        } else if let r = Self.knownRates["\(from):\(to)"] {
            value = r
        } else {
            // Deliberately loud. A test that lands here is asking for a pair
            // this stub was never told about — most likely because something
            // inverted the direction on the way.
            throw FXError.currencyNotFound(to)
        }
        guard let rate = FXRate(from: from, to: to, value: value) else {
            throw FXError.currencyNotFound(to)
        }
        return rate
    }
}

final class TrackingFXRateProvider: FXRateProvider, @unchecked Sendable {
    var underlying: any FXRateProvider
    private(set) var callCount = 0

    init(underlying: any FXRateProvider = MockFXRateProvider()) {
        self.underlying = underlying
    }

    func rate(from: String, to: String, on date: Date?) async throws -> FXRate {
        callCount += 1
        return try await underlying.rate(from: from, to: to, on: date)
    }
}
