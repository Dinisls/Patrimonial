import Foundation

/// Alpha Vantage's free tier allows 25 requests a day for the whole key — not
/// per feature. European quotes and Step 7's historical series therefore draw
/// from one shared pot, which needs a priority rule rather than first-come.
///
/// The rule: quotes may spend down to zero, history may not. `historyReserve`
/// requests at the end of the day are quote-only, so a chart can never leave a
/// Lisbon position showing a dash.
///
/// Two further guarantees:
/// - **One call per symbol per day.** A symbol already fetched today is refused
///   again regardless of what asked — polling, pull-to-refresh, or a relaunch.
/// - **Survives relaunch.** The counters live in `UserDefaults`, because an
///   in-memory bucket resets every cold start and would blow past 25 by lunch.
actor AlphaVantageBudget {
    static let shared = AlphaVantageBudget()

    private let dailyLimit: Int
    private let historyReserve: Int
    private let store: any AlphaVantageBudgetStore
    private let now: @Sendable () -> Date

    private var state: AlphaVantageBudgetState

    init(
        dailyLimit: Int = 25,
        historyReserve: Int = 5,
        store: any AlphaVantageBudgetStore = UserDefaultsBudgetStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dailyLimit = dailyLimit
        self.historyReserve = historyReserve
        self.store = store
        self.now = now
        self.state = store.load()
    }

    // MARK: - Quotes

    /// True when a live quote call for `symbol` may go out right now.
    ///
    /// False means "serve the cache": either the symbol was already fetched
    /// today, or the day is spent. Neither is an error — the caller must fall
    /// silent, not raise.
    func reserveQuote(symbol: String) -> Bool {
        rollOverIfNeeded()
        guard state.symbolDays[symbol] != state.day else { return false }
        guard state.used < dailyLimit else { return false }
        state.used += 1
        state.symbolDays[symbol] = state.day
        persist()
        return true
    }

    /// Hands a reservation back when the request never reached Alpha Vantage —
    /// a connectivity failure costs them nothing, so it must not cost us the
    /// day. Only for that case: an HTTP error still counted against the quota.
    func releaseQuote(symbol: String) {
        rollOverIfNeeded()
        guard state.symbolDays[symbol] == state.day else { return }
        state.symbolDays.removeValue(forKey: symbol)
        state.used = max(0, state.used - 1)
        persist()
    }

    func hasFetchedToday(symbol: String) -> Bool {
        rollOverIfNeeded()
        return state.symbolDays[symbol] == state.day
    }

    // MARK: - History (Step 7)

    /// Refused as soon as granting it would eat into the quote reserve, so
    /// charts degrade before prices do.
    func reserveHistory() -> Bool {
        rollOverIfNeeded()
        guard dailyLimit - state.used > historyReserve else { return false }
        state.used += 1
        persist()
        return true
    }

    // MARK: - Introspection

    var remainingToday: Int {
        rollOverIfNeeded()
        return max(0, dailyLimit - state.used)
    }

    var remainingForHistory: Int {
        rollOverIfNeeded()
        return max(0, dailyLimit - state.used - historyReserve)
    }

    // MARK: - Private

    /// Alpha Vantage counts a day in US/Eastern, so that is the boundary the
    /// counter resets on — not the phone's local midnight, which would hand out
    /// a fresh 25 while their side is still counting the old day.
    private func rollOverIfNeeded() {
        let today = Self.dayKey(for: now())
        guard state.day != today else { return }
        state = AlphaVantageBudgetState(day: today, used: 0, symbolDays: [:])
        persist()
    }

    private func persist() {
        store.save(state)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }
}

// MARK: - Persistence

nonisolated struct AlphaVantageBudgetState: Codable, Sendable {
    var day: String = ""
    var used: Int = 0
    /// symbol → the day it was last fetched on.
    var symbolDays: [String: String] = [:]
}

nonisolated protocol AlphaVantageBudgetStore: Sendable {
    func load() -> AlphaVantageBudgetState
    func save(_ state: AlphaVantageBudgetState)
}

/// `@unchecked` because `UserDefaults` is thread-safe but not annotated as
/// `Sendable`; nothing here is mutated outside it.
nonisolated struct UserDefaultsBudgetStore: AlphaVantageBudgetStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "alphaVantage.budget") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AlphaVantageBudgetState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(AlphaVantageBudgetState.self, from: data)
        else { return AlphaVantageBudgetState() }
        return state
    }

    func save(_ state: AlphaVantageBudgetState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
