import Foundation

nonisolated struct MarketCalendar: Sendable {
    enum Exchange: String, Sendable, CaseIterable {
        case nyse = "NYSE"
        case nasdaq = "NASDAQ"
        case xetra = "XETRA"
        case euronextLisbon = "LISBON"
        case euronextAmsterdam = "AMSTERDAM"
        case euronextParis = "PARIS"
        case crypto = "CRYPTO"

        var timeZone: TimeZone {
            switch self {
            case .nyse, .nasdaq: TimeZone(identifier: "America/New_York")!
            case .xetra: TimeZone(identifier: "Europe/Berlin")!
            case .euronextLisbon: TimeZone(identifier: "Europe/Lisbon")!
            case .euronextAmsterdam: TimeZone(identifier: "Europe/Amsterdam")!
            case .euronextParis: TimeZone(identifier: "Europe/Paris")!
            case .crypto: TimeZone(identifier: "UTC")!
            }
        }

        var tradingHours: (open: (hour: Int, minute: Int), close: (hour: Int, minute: Int)) {
            switch self {
            case .nyse, .nasdaq: ((9, 30), (16, 0))
            case .xetra: ((9, 0), (17, 30))
            case .euronextLisbon: ((8, 0), (16, 30))
            case .euronextAmsterdam, .euronextParis: ((9, 0), (17, 30))
            case .crypto: ((0, 0), (23, 59))
            }
        }

        /// The venues no free intraday plan reaches — Twelve Data refuses them
        /// and Finnhub answers 403 — and so the only ones the Alpha Vantage
        /// end-of-day fallback is allowed to spend its 25 daily requests on.
        var isEuropean: Bool {
            switch self {
            case .xetra, .euronextLisbon, .euronextAmsterdam, .euronextParis: true
            case .nyse, .nasdaq, .crypto: false
            }
        }

        /// The currency a listing on this venue trades in. Needed because
        /// Alpha Vantage's `GLOBAL_QUOTE` does not report one, and inventing a
        /// currency is how a EUR price ends up with a USD→EUR rate applied.
        var nativeCurrency: String {
            switch self {
            case .xetra, .euronextLisbon, .euronextAmsterdam, .euronextParis: "EUR"
            case .nyse, .nasdaq: "USD"
            case .crypto: ""
            }
        }

        /// The one MIC this venue is keyed under.
        ///
        /// NASDAQ reports itself as XNGS, XNMS or XNCM depending on the listing
        /// tier, and NYSE's own book, Arca and BATS all answer for NYSE. Those
        /// are spellings, not venues, and a key that admits three spellings is
        /// three positions where the user holds one.
        var canonicalMIC: String {
            switch self {
            case .nyse: "XNYS"
            case .nasdaq: "XNAS"
            case .xetra: "XETR"
            case .euronextLisbon: "XLIS"
            case .euronextAmsterdam: "XAMS"
            case .euronextParis: "XPAR"
            case .crypto: "CRYPTO"
            }
        }

        /// The suffix Alpha Vantage expects for this venue, appended to the bare
        /// ticker a search result carries: `QDVE` on XETR is `QDVE.DE`.
        ///
        /// Only the four venues whose suffix is known are listed. An unmapped
        /// venue returns nil and its row shows a dash — spending a request from
        /// a budget of 25 on a guessed suffix buys nothing but a wrong answer.
        var alphaVantageSuffix: String? {
            switch self {
            case .xetra: ".DE"
            case .euronextLisbon: ".LS"
            case .euronextAmsterdam: ".AS"
            case .euronextParis: ".PA"
            case .nyse, .nasdaq, .crypto: nil
            }
        }
    }

    /// The trading currency implied by an Alpha Vantage suffix, as the code the
    /// provider *would* have reported if it reported one.
    ///
    /// It reports none. Verified live: `GLOBAL_QUOTE` has no currency field,
    /// and `TIME_SERIES_DAILY`'s "Meta Data" carries information, symbol, last
    /// refreshed, output size and time zone — and nothing about units. So the
    /// suffix is the only thing in the response that says what the numbers
    /// mean.
    ///
    /// **`.LON` is deliberately absent, and this is the interesting entry.**
    ///
    /// It used to answer `GBp`, on the strength of one reading: Alpha Vantage
    /// answers `VOD.LON` with 120,15 for a share that trades at 1,20 £. The
    /// premise — that the venue decides the unit — is false. Measured live on
    /// 2026-08-14:
    ///
    /// - `VOD.LON` → 120,15, and Vodafone's LSE line is quoted in **pence**;
    /// - `3GOL.LON` → 155,48, and *that* LSE line is quoted in **US dollars**
    ///   (Yahoo, same instrument, same day: `3GOL.L` = 158,47 **USD**). The
    ///   pence line of the very same ETP is a different ticker, `3LGO`, at
    ///   about 10 950 GBp.
    ///
    /// On the LSE the unit is a property of the **line**, not of the venue, and
    /// the suffix cannot tell them apart. Answering `GBp` for both divides
    /// 3GOL by 100 and stamps it GBP — a price 100× low with the wrong currency
    /// on it, which then picks up a GBP→EUR rate. That is the whole family of
    /// bugs this module exists to prevent, so the answer is no answer:
    /// `normalization(forSymbol:)` refuses, and a listing whose unit is unknown
    /// gets **no quote** instead of a wrong one.
    ///
    /// London is not thereby unpriced. It routes to the last resort, which
    /// reports its currency per line and needs no table (`GBp` for VOD, `USD`
    /// for 3GOL). If Alpha Vantage is ever wanted for London, the unit has to
    /// come from the listing's recorded currency, threaded down from
    /// `PriceStore` — not from the string.
    ///
    /// Nil for a bare ticker, which is a US listing this provider is never
    /// asked for anyway. Nil is "no opinion", not "USD".
    static func alphaVantageCurrency(forSuffixOf symbol: String) -> String? {
        guard let dot = symbol.lastIndex(of: ".") else { return nil }
        switch symbol[dot...].uppercased() {
        case ".DE", ".LS", ".AS", ".PA": return "EUR"
        default: return nil
        }
    }

    static func isEuropean(_ symbol: String) -> Bool {
        exchangeForSymbol(symbol).isEuropean
    }

    // MARK: - Yahoo venues

    /// A venue as the last-resort quote source addresses it.
    ///
    /// Deliberately a separate table from `Exchange` rather than eight new
    /// cases: `Exchange` carries trading hours and a holiday calendar, and none
    /// of these venues need one — the fallback only ever serves a dated daily
    /// close. Modelling them as full exchanges would mean inventing opening
    /// times for Bogotá to support a provider that reports one number a day.
    struct YahooVenue: Sendable, Equatable {
        let suffix: String
        /// The venue's trading currency, used **only** when the response omits
        /// one. It is never a default applied over a reported value.
        ///
        /// **Nil where the venue has no single trading currency.** The LSE
        /// quotes VOD in pence and 3GOL in dollars, and Borsa Italiana lists
        /// USD lines beside its euro ones; on those two, a table entry would be
        /// a guess dressed as a reading. Nil means the response must say, and
        /// a response that does not say produces no quote — a dash, never a
        /// number wearing the wrong currency.
        let currency: String?
    }

    /// MIC → Yahoo suffix. Explicit, and the only way a symbol is built for
    /// that provider: nothing here is inferred from a ticker.
    static func yahooVenue(for mic: String) -> YahooVenue? {
        switch mic.uppercased() {
        // London and Milan, added 2026-08-14 because a 3GOL position on XMIL
        // was showing a dash: neither venue was in any routing table, so the
        // search offered instruments the app could never price. Both verified
        // live through `URLSession` on the same day — `3GOL.MI` → 136,81 EUR
        // (Milan), `3GOL.L` → 158,47 USD (LSE), `VOD.L` → 121,55 GBp (LSE).
        // Currency nil on both: see `YahooVenue.currency`.
        case "XLON": YahooVenue(suffix: ".L", currency: nil)
        case "XMIL", "MTAA": YahooVenue(suffix: ".MI", currency: nil)

        case "XETR": YahooVenue(suffix: ".DE", currency: "EUR")
        case "XFRA": YahooVenue(suffix: ".F", currency: "EUR")
        case "XMUN": YahooVenue(suffix: ".MU", currency: "EUR")
        case "XDUS": YahooVenue(suffix: ".DU", currency: "EUR")
        case "XHAM": YahooVenue(suffix: ".HM", currency: "EUR")
        case "XLIS": YahooVenue(suffix: ".LS", currency: "EUR")
        case "XAMS": YahooVenue(suffix: ".AS", currency: "EUR")
        case "XPAR": YahooVenue(suffix: ".PA", currency: "EUR")
        case "XSWX", "XVTX": YahooVenue(suffix: ".SW", currency: "CHF")
        case "XWBO": YahooVenue(suffix: ".VI", currency: "EUR")
        case "XWAR": YahooVenue(suffix: ".WA", currency: "PLN")
        case "XBUE": YahooVenue(suffix: ".BA", currency: "ARS")
        case "XMEX": YahooVenue(suffix: ".MX", currency: "MXN")
        case "XTSE": YahooVenue(suffix: ".TO", currency: "CAD")
        // Bogotá is `.CL` — Yahoo's suffix for Colombia, not Chile, which is
        // `.SN`. Verified live: ECOPETROL.CL and ISA.CL both answer in COP on
        // BVC.
        case "XBOG": YahooVenue(suffix: ".CL", currency: "COP")
        // Lima (XLIM) is deliberately absent. `.LM` answers, but with a null
        // currency, an exchange of "YHD" — Yahoo's placeholder, not Lima — and
        // a `regularMarketTime` from 2019. That is a dead endpoint wearing a
        // suffix, and mapping it would publish a price for a venue nobody is
        // quoting.
        // US listings need no suffix, and never reach this provider anyway —
        // two others cover them.
        default: nil
        }
    }

    /// The symbol to ask Yahoo about, for a ticker held on a known venue. Nil
    /// when the MIC is not in the table, which is what keeps a guessed suffix
    /// off the wire.
    static func yahooSymbol(_ symbol: String, mic: String) -> String? {
        guard let venue = yahooVenue(for: mic) else { return nil }
        return symbol.hasSuffix(venue.suffix) ? symbol : symbol + venue.suffix
    }

    /// The venue currency implied by a Yahoo suffix, for the one case where the
    /// response carries no `meta.currency`. Nil when the suffix is unknown —
    /// the quote is then dropped rather than given an assumed currency.
    static func yahooCurrency(forSuffixOf symbol: String) -> String? {
        guard let dot = symbol.lastIndex(of: ".") else { return nil }
        let suffix = String(symbol[dot...]).uppercased()
        // The same table, read backwards, so the two can never disagree.
        return allYahooMICs
            .lazy
            .compactMap { yahooVenue(for: $0) }
            .first { $0.suffix == suffix }?
            .currency ?? nil
    }

    static let allYahooMICs = [
        "XLON", "XMIL", "MTAA",
        "XETR", "XFRA", "XMUN", "XDUS", "XHAM",
        "XLIS", "XAMS", "XPAR", "XSWX", "XVTX", "XWBO", "XWAR",
        "XBUE", "XMEX", "XTSE", "XBOG",
    ]

    /// Whether any provider can price a listing on this venue at all.
    ///
    /// The search offers what the app can hold, and holding something it cannot
    /// price is a position condemned to a dash. So the same tables that route a
    /// quote decide what the search is allowed to present as buyable: the two
    /// US-only providers by MIC, Alpha Vantage through `Exchange`, and the last
    /// resort through the Yahoo table. A venue in none of them has no route,
    /// and the row says so before the purchase rather than the portfolio saying
    /// it after.
    static func hasQuoteRoute(mic: String?) -> Bool {
        guard let mic, !mic.isEmpty else { return false }
        if isUnitedStatesMIC(mic) { return true }
        if let exchange = exchangeForMIC(mic), exchange.alphaVantageSuffix != nil { return true }
        return yahooVenue(for: mic) != nil
    }

    /// The venue of a *search result*, resolved from its MIC.
    ///
    /// `exchangeForSymbol` reads the suffix, which search results do not have:
    /// Twelve Data returns `QDVE` with `mic_code: XETR`, and a suffix-only
    /// lookup calls that NYSE/USD. The MIC is the only thing that actually
    /// identifies the listing, so it is what routes the quote and what decides
    /// the currency.
    ///
    /// Nil for the venues no configured provider reaches — XBUE, XBOG, XMEX,
    /// XTSE and the rest. Those rows are honestly unpriceable here, and saying
    /// so is the point: the alternative is what shipped, where an Apple CEDEAR
    /// in Buenos Aires wore the NASDAQ price.
    static func exchangeForMIC(_ mic: String) -> Exchange? {
        switch mic.uppercased() {
        case "XNGS", "XNMS", "XNCM", "XNAS": .nasdaq
        case "XNYS", "ARCX", "BATS", "XASE": .nyse
        // XFRA, XMUN, XDUS and XHAM are deliberately absent. They are separate
        // German venues with their own prices, and Alpha Vantage's `.DE` is the
        // XETRA listing — lending it to them would be the same conflation this
        // map exists to end, just harder to spot because the currency matches.
        case "XETR": .xetra
        case "XLIS": .euronextLisbon
        case "XAMS": .euronextAmsterdam
        case "XPAR": .euronextParis
        default: nil
        }
    }

    /// The MICs whose listings Twelve Data's free plan and Finnhub actually
    /// cover. Both are US-only sources, and neither takes a venue parameter —
    /// Twelve Data's `mic_code` is gated behind a paid plan (verified: it
    /// answers 404 with an upgrade notice), and Finnhub has no such field at
    /// all. So they are asked with a bare ticker and answer about whichever
    /// listing they consider canonical, which for a globally duplicated ticker
    /// is the US one.
    ///
    /// This set is therefore not a routing convenience: it is the boundary of
    /// what those two providers can be *asked*. A position on any other venue
    /// must skip them entirely rather than accept an answer they were never in
    /// a position to give correctly.
    static let unitedStatesMICs: Set<String> = [
        "XNGS", "XNMS", "XNCM", "XNAS", "XNYS", "ARCX", "BATS", "XASE",
    ]

    static func isUnitedStatesMIC(_ mic: String) -> Bool {
        unitedStatesMICs.contains(mic.uppercased())
    }

    /// A venue as a plain name rather than a MIC.
    ///
    /// Not decoration: `AssetSearchResult` falls back to `exchange` when the
    /// provider sends no `mic_code`, so rows in this app really do carry
    /// "NASDAQ" where others carry "XNAS". Without this table those two key
    /// apart, and the user's second purchase of the same listing opens a second
    /// position beside the first.
    ///
    /// Deliberately short. Every entry here is a name a provider has actually
    /// been seen to send; guessing at the rest would merge venues that differ.
    private static func exchangeForVenueName(_ name: String) -> Exchange? {
        switch name {
        case "NASDAQ", "NASDAQ GLOBAL SELECT", "NASDAQ CAPITAL MARKET": .nasdaq
        case "NYSE", "NYSE ARCA", "ARCA", "BATS", "NYSE AMERICAN", "AMEX": .nyse
        case "XETRA", "ETR", "GER", "DEUTSCHE BOERSE XETRA": .xetra
        case "EURONEXT LISBON", "LISBON", "LIS": .euronextLisbon
        case "EURONEXT AMSTERDAM", "AMSTERDAM", "AMS": .euronextAmsterdam
        case "EURONEXT PARIS", "PARIS", "PAR": .euronextParis
        default: nil
        }
    }

    /// The single spelling of a venue that everything keys on.
    ///
    /// Unknown venues come back uppercased and otherwise untouched. There is
    /// nothing to widen them with, and folding them into a neighbour would
    /// merge listings that really are different — XMUN and XDUS are separate
    /// German markets with separate prices, not two names for one.
    static func canonicalVenue(_ venue: String) -> String {
        let raw = venue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let exchange = exchangeForMIC(raw) { return exchange.canonicalMIC }
        if let exchange = exchangeForVenueName(raw) { return exchange.canonicalMIC }
        return raw
    }

    /// Whether two MICs name the same trading venue.
    ///
    /// Defined as equality of the canonical spelling, and not merely equivalent
    /// to it. `ListingID` keys on `canonicalVenue`, so any venue pair this
    /// answers "yes" to and the key answers "no" to would be a position that
    /// the buy sheet accepts as a top-up and the calculator files as a new
    /// holding. One function, so the two cannot drift apart.
    static func venuesAgree(_ a: String, _ b: String) -> Bool {
        canonicalVenue(a) == canonicalVenue(b)
    }

    /// Whether the venue trades at all on this calendar day — weekends and
    /// holidays excluded, opening hours ignored.
    ///
    /// Split out of `isOpen` because the session boundary needs the day without
    /// the hours: at 18:00 on a Monday the market is shut, but Monday is still
    /// the session the current price belongs to.
    static func isTradingDay(_ exchange: Exchange, on date: Date = Date()) -> Bool {
        if exchange == .crypto { return true }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchange.timeZone

        let weekday = cal.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return false }

        return !isHoliday(exchange, date: date, calendar: cal)
    }

    /// The instant the trading session that the *current price* belongs to
    /// began.
    ///
    /// Not the same thing as "today", and the difference is what put "Hoje
    /// +5,46 €" back on the header after the per-lot rule had already been
    /// written. A position opened on Friday at the closing price was read on
    /// Saturday, when the latest quote is still Friday's close and the previous
    /// close is Thursday's. `startOfDay(now)` said the session began on
    /// Saturday, so the Friday lot counted as an *earlier* holding and was
    /// credited with the Thursday → Friday move it had not been alive for. The
    /// arithmetic was the fixed arithmetic; the boundary it was measured from
    /// was a calendar day rather than a session.
    ///
    /// So: walk back from `date` to the most recent day the venue trades and
    /// whose opening bell has already rung. On a Saturday that is Friday; at
    /// 07:00 on a Monday, before the open, it is still Friday; at 18:00 on a
    /// Monday, after the close, it is Monday, because Monday's close is what
    /// the quote now reports.
    static func currentSessionStart(_ exchange: Exchange, at date: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchange.timeZone

        // Crypto never closes, so the session is simply the day, in the venue's
        // own zone.
        if exchange == .crypto { return cal.startOfDay(for: date) }

        let hours = exchange.tradingHours
        // Ten days back clears any run of holidays a major venue actually has —
        // the longest is Christmas into New Year, four sessions.
        for offset in 0...10 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: date),
                  isTradingDay(exchange, on: day),
                  let open = cal.date(
                    bySettingHour: hours.open.hour, minute: hours.open.minute,
                    second: 0, of: day
                  ),
                  open <= date
            else { continue }
            return cal.startOfDay(for: day)
        }
        return cal.startOfDay(for: date)
    }

    /// The stretch of time a price describes: when the session it belongs to
    /// opened, and — only when that session is already over — when it closed.
    ///
    /// The end is what a start alone could not express. A start says which
    /// purchases are *not* older than the price; it says nothing about
    /// purchases that are *newer* than it. With an end-of-day quote those
    /// exist: buy at 14:00 on a day whose latest available close is the
    /// previous session's, and the purchase is neither an earlier holding nor
    /// a participant in the session being reported.
    ///
    /// `end == nil` means the session is still running, so nothing can be newer
    /// than the price and the distinction does not arise.
    struct SessionWindow: Equatable, Sendable {
        let start: Date
        let end: Date?

        /// A session still in progress: everything from `start` on took part.
        static func open(from start: Date) -> SessionWindow {
            SessionWindow(start: start, end: nil)
        }

        func contains(_ date: Date) -> Bool {
            guard date >= start else { return false }
            guard let end else { return true }
            return date <= end
        }

        /// Bought after the session the price comes from had already closed.
        func isAfter(_ date: Date) -> Bool {
            guard let end else { return false }
            return date > end
        }
    }

    /// The session that produced a close reported for `closeDate`.
    ///
    /// Anchored on the last instant of that day in the venue's own zone, so the
    /// walk back in `currentSessionStart` lands on that day when it traded and
    /// on the preceding session when it did not — a close dated to a holiday is
    /// the previous session's close, not a session of its own.
    static func sessionWindow(_ exchange: Exchange, endingOn closeDate: Date) -> SessionWindow {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchange.timeZone
        let anchor = cal.date(
            bySettingHour: 23, minute: 59, second: 59, of: closeDate
        ) ?? closeDate
        return SessionWindow(
            start: currentSessionStart(exchange, at: anchor),
            end: currentSessionEnd(exchange, at: anchor)
        )
    }

    /// The closing bell of the session `currentSessionStart` identifies.
    static func currentSessionEnd(_ exchange: Exchange, at date: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchange.timeZone

        let sessionDay = currentSessionStart(exchange, at: date)
        // Crypto's session is the day itself; it ends when the day does.
        if exchange == .crypto {
            return cal.date(byAdding: .day, value: 1, to: sessionDay) ?? sessionDay
        }
        let hours = exchange.tradingHours
        return cal.date(
            bySettingHour: hours.close.hour, minute: hours.close.minute,
            second: 0, of: sessionDay
        ) ?? sessionDay
    }

    /// The session boundary to use when the venue is not known.
    ///
    /// The earliest of the known venues' session starts, deliberately. The two
    /// errors are not symmetric: a boundary set too far back classifies an older
    /// lot as belonging to this session, which measures it from its own purchase
    /// price and *understates* the day change; a boundary set too late credits a
    /// position with a move that predates it, which is the bug this whole rule
    /// exists to stop. When there is nothing to read, take the error that
    /// understates.
    static func widestSessionStart(at date: Date = Date()) -> Date {
        let starts = Exchange.allCases
            .filter { $0 != .crypto }
            .map { currentSessionStart($0, at: date) }
        guard let earliest = starts.min() else {
            return Calendar.current.startOfDay(for: date)
        }
        return earliest
    }

    static func isOpen(_ exchange: Exchange, at date: Date = Date()) -> Bool {
        if exchange == .crypto { return true }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchange.timeZone

        if !isTradingDay(exchange, on: date) { return false }

        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let current = hour * 60 + minute
        let hours = exchange.tradingHours
        let openMinute = hours.open.hour * 60 + hours.open.minute
        let closeMinute = hours.close.hour * 60 + hours.close.minute

        return current >= openMinute && current < closeMinute
    }

    /// - Parameter now: the instant to judge against. Defaulted, but present
    ///   because this function asks "is the market open?" of the wall clock,
    ///   which made `closedMarketReadsAsClosedNotStale` pass or fail depending
    ///   on what time of day the suite was run — green every evening, red
    ///   whenever it ran while New York was trading.
    static func freshness(
        for exchange: Exchange,
        quoteTimestamp: Date,
        source: QuoteSource,
        closeDate: Date? = nil,
        now: Date = Date()
    ) -> QuoteFreshness {
        // End-of-day data describes a settled session, so it reports as a close
        // whether or not the market happens to be open right now — and never as
        // live, however recently it was fetched.
        if source == .dailyClose {
            return .dailyClose(closeDate ?? quoteTimestamp)
        }

        if exchange == .crypto {
            let age = now.timeIntervalSince(quoteTimestamp)
            switch source {
            case .websocket: return age < 30 ? .live : .stale
            case .rest: return age < 60 ? .delayed(15) : .stale
            case .cache, .dailyClose: return .stale
            }
        }

        if !isOpen(exchange, at: now) {
            return .closed
        }

        let age = now.timeIntervalSince(quoteTimestamp)
        switch source {
        case .websocket: return age < 30 ? .live : .stale
        case .rest: return age < 60 ? .delayed(15) : .stale
        case .cache, .dailyClose: return .stale
        }
    }

    static func pollingInterval(for exchange: Exchange) -> TimeInterval {
        if exchange == .crypto { return 15 }
        return isOpen(exchange) ? 15 : 1800
    }

    static func exchangeForSymbol(_ symbol: String) -> Exchange {
        if symbol.hasSuffix(".DE") { return .xetra }
        if symbol.hasSuffix(".LS") { return .euronextLisbon }
        if symbol.hasSuffix(".AS") { return .euronextAmsterdam }
        if symbol.hasSuffix(".PA") { return .euronextParis }
        return .nyse
    }

    // MARK: - Holidays (major US + DE + Euronext market holidays)

    private static func isHoliday(_ exchange: Exchange, date: Date, calendar cal: Calendar) -> Bool {
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)
        let year = cal.component(.year, from: date)

        switch exchange {
        case .nyse, .nasdaq:
            return isUSHoliday(month: month, day: day, year: year, calendar: cal, date: date)
        case .xetra:
            return isXetraHoliday(month: month, day: day, year: year)
        case .euronextLisbon, .euronextAmsterdam, .euronextParis:
            return isEuronextHoliday(month: month, day: day, year: year)
        case .crypto:
            return false
        }
    }

    private static func isUSHoliday(month: Int, day: Int, year: Int, calendar cal: Calendar, date: Date) -> Bool {
        if isUSFixedHoliday(month: month, day: day, year: year) { return true }

        // NYSE and NASDAQ close on Good Friday, but trade on Easter Monday.
        if let goodFriday = goodFriday(year: year),
           month == goodFriday.month && day == goodFriday.day { return true }

        let weekday = cal.component(.weekday, from: date)   // 1 = Sunday
        let monday = 2, thursday = 5
        let sunday = 1, friday = 6, saturday = 7

        // Observed closures. A fixed-date holiday landing on a weekend moves to
        // the nearest weekday and the exchange really does shut: 4 July 2026 is
        // a Saturday, so NYSE closes on Friday the 3rd. Without this the app
        // called that a normal session and would have shown its prices as live.
        if weekday == friday, let next = cal.date(byAdding: .day, value: 1, to: date),
           cal.component(.weekday, from: next) == saturday,
           isUSFixedHoliday(
               month: cal.component(.month, from: next),
               day: cal.component(.day, from: next),
               year: cal.component(.year, from: next)
           ) { return true }

        if weekday == monday, let prev = cal.date(byAdding: .day, value: -1, to: date),
           cal.component(.weekday, from: prev) == sunday,
           isUSFixedHoliday(
               month: cal.component(.month, from: prev),
               day: cal.component(.day, from: prev),
               year: cal.component(.year, from: prev)
           ) { return true }

        // MLK Day: 3rd Monday of January
        if month == 1 && weekday == monday && Self.ordinalWeekday(day) == 3 { return true }

        // Presidents Day: 3rd Monday of February
        if month == 2 && weekday == monday && Self.ordinalWeekday(day) == 3 { return true }

        // Memorial Day: last Monday of May. May has 31 days, so the last Monday
        // is always the 25th or later and no later Monday can follow — this one
        // was already right.
        if month == 5 && weekday == monday && day > 24 { return true }

        // Labor Day: 1st Monday of September. Likewise sound.
        if month == 9 && weekday == monday && day <= 7 { return true }

        // Thanksgiving: 4th Thursday of November
        if month == 11 && weekday == thursday && Self.ordinalWeekday(day) == 4 { return true }

        return false
    }

    /// The fixed-date US market holidays, separate so the weekend-observance
    /// rule can ask about a neighbouring day without recursing into the
    /// moveable ones.
    private static func isUSFixedHoliday(month: Int, day: Int, year: Int) -> Bool {
        if month == 1 && day == 1 { return true }
        if month == 7 && day == 4 { return true }
        if month == 12 && day == 25 { return true }
        // Juneteenth, an NYSE closure since 2021 and simply missing before.
        if month == 6 && day == 19 && year >= 2021 { return true }
        return false
    }

    /// Which occurrence of its weekday a day-of-month is: the 19th is the 3rd
    /// Monday when it falls on a Monday, because days 15–21 are the third of
    /// each weekday.
    ///
    /// This replaces `Calendar.weekOfMonth`, which counted something else
    /// entirely — the week *of the month* the date falls in, where week 1 is
    /// the partial week containing the 1st. The two coincide only by accident.
    /// Martin Luther King Day was therefore never detected in any year tested,
    /// and Thanksgiving was missed in 2024 and 2025.
    ///
    /// Worse, `weekOfMonth` depends on the calendar's `firstWeekday`, so the
    /// answer changed with the device locale: Thanksgiving 2026 computed as
    /// week 4 under a Sunday-first calendar and week 5 under the Monday-first
    /// one a Portuguese device uses. Arithmetic on the day of the month has no
    /// such dependency.
    static func ordinalWeekday(_ dayOfMonth: Int) -> Int {
        (dayOfMonth - 1) / 7 + 1
    }

    private static func isXetraHoliday(month: Int, day: Int, year: Int) -> Bool {
        if month == 1 && day == 1 { return true }
        if month == 5 && day == 1 { return true }
        if month == 12 && (day == 25 || day == 26) { return true }
        if month == 12 && day == 31 { return true }
        if isEasterClosure(month: month, day: day, year: year) { return true }
        return false
    }

    /// Euronext cash-market closures. The calendar is shared by Lisbon, Amsterdam
    /// and Paris — Euronext publishes one list for these three markets.
    ///
    /// Deliberately does NOT include Portugal's national holidays (25 April,
    /// 10 June). Those are public holidays in Portugal but NOT market holidays:
    /// Euronext Lisbon trades normally on both. See
    /// https://www.euronext.com/en/trade/trading-hours-holidays
    private static func isEuronextHoliday(month: Int, day: Int, year: Int) -> Bool {
        if month == 1 && day == 1 { return true }
        if month == 5 && day == 1 { return true }
        if month == 12 && (day == 25 || day == 26) { return true }
        if isEasterClosure(month: month, day: day, year: year) { return true }
        return false
    }

    // MARK: - Easter

    /// Good Friday and Easter Monday — the two moveable feasts on which every
    /// major European exchange closes.
    private static func isEasterClosure(month: Int, day: Int, year: Int) -> Bool {
        guard let easter = easterSunday(year: year) else { return false }
        for offset in [-2, 1] {  // Good Friday, Easter Monday
            guard let date = utcCalendar.date(byAdding: .day, value: offset, to: easter) else { continue }
            let comps = utcCalendar.dateComponents([.month, .day], from: date)
            if comps.month == month && comps.day == day { return true }
        }
        return false
    }

    private static func goodFriday(year: Int) -> (month: Int, day: Int)? {
        guard let easter = easterSunday(year: year),
              let date = utcCalendar.date(byAdding: .day, value: -2, to: easter)
        else { return nil }
        let comps = utcCalendar.dateComponents([.month, .day], from: date)
        guard let month = comps.month, let day = comps.day else { return nil }
        return (month, day)
    }

    /// Easter Sunday via the anonymous Gregorian algorithm (Meeus/Jones/Butcher).
    /// Foundation's `Calendar` has no concept of Easter, so it has to be computed.
    private static func easterSunday(year: Int) -> Date? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return utcCalendar.date(from: comps)
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
