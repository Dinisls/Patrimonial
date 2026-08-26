import Foundation
@testable import Patrimonial

/// A rate source that answers **one** direction and refuses every other.
///
/// The shared stub for tests that need a foreign position to have a euro value
/// without going to the network. Deliberately not "returns 0,86693 to whoever
/// asks": a stub that answers any question cannot fail when the question is
/// wrong, and a suite built on one is unable to see an inverted conversion — the
/// exact failure this module has had three times.
struct StubRate: FXRateProvider {
    let value: Decimal
    var from: String = "USD"
    var to: String = "EUR"

    func rate(from: String, to: String, on date: Date?) async throws -> FXRate {
        guard from == self.from, to == self.to else {
            throw FXError.currencyNotFound(to)
        }
        guard let rate = FXRate(from: from, to: to, value: value) else {
            throw FXError.currencyNotFound(to)
        }
        return rate
    }
}
