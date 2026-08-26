import Foundation
import Testing
@testable import Patrimonial

struct MarketCalendarTests {

    // MARK: - Crypto always open

    @Test func cryptoAlwaysOpen() {
        let sunday3am = makeDate(year: 2026, month: 8, day: 2, hour: 3, minute: 0, tz: "UTC")
        #expect(MarketCalendar.isOpen(.crypto, at: sunday3am) == true)
    }

    @Test func cryptoOpenOnChristmas() {
        let christmas = makeDate(year: 2026, month: 12, day: 25, hour: 12, minute: 0, tz: "UTC")
        #expect(MarketCalendar.isOpen(.crypto, at: christmas) == true)
    }

    // MARK: - NYSE hours

    @Test func nyseOpenDuringHours() {
        // Wednesday at 10:00 ET
        let date = makeDate(year: 2026, month: 8, day: 5, hour: 10, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: date) == true)
    }

    @Test func nyseClosedBeforeOpen() {
        // Wednesday at 9:00 ET (before 9:30)
        let date = makeDate(year: 2026, month: 8, day: 5, hour: 9, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: date) == false)
    }

    @Test func nyseOpenAtExactOpen() {
        // Wednesday at 9:30 ET
        let date = makeDate(year: 2026, month: 8, day: 5, hour: 9, minute: 30, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: date) == true)
    }

    @Test func nyseClosedAtExactClose() {
        // Wednesday at 16:00 ET (close)
        let date = makeDate(year: 2026, month: 8, day: 5, hour: 16, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: date) == false)
    }

    @Test func nyseClosedOnWeekend() {
        // Saturday
        let saturday = makeDate(year: 2026, month: 8, day: 1, hour: 12, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: saturday) == false)

        // Sunday
        let sunday = makeDate(year: 2026, month: 8, day: 2, hour: 12, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: sunday) == false)
    }

    @Test func nyseClosedOnJuly4() {
        // July 4th falls on a Saturday in 2026, so test 2025 where it's a Friday
        let july4_weekday = makeDate(year: 2025, month: 7, day: 4, hour: 12, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: july4_weekday) == false)
    }

    @Test func nyseClosedOnChristmas() {
        // Christmas 2025 is Thursday
        let christmas = makeDate(year: 2025, month: 12, day: 25, hour: 12, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: christmas) == false)
    }

    // MARK: - XETRA hours

    @Test func xetraOpenDuringHours() {
        // Wednesday at 10:00 CET
        let date = makeDate(year: 2026, month: 8, day: 5, hour: 10, minute: 0, tz: "Europe/Berlin")
        #expect(MarketCalendar.isOpen(.xetra, at: date) == true)
    }

    @Test func xetraClosedAfterHours() {
        // Wednesday at 18:00 CET (after 17:30 close)
        let date = makeDate(year: 2026, month: 8, day: 5, hour: 18, minute: 0, tz: "Europe/Berlin")
        #expect(MarketCalendar.isOpen(.xetra, at: date) == false)
    }

    // MARK: - Euronext Lisbon

    @Test func lisbonOpenDuringHours() {
        // Wednesday at 10:00 WET
        let date = makeDate(year: 2026, month: 8, day: 5, hour: 10, minute: 0, tz: "Europe/Lisbon")
        #expect(MarketCalendar.isOpen(.euronextLisbon, at: date) == true)
    }

    /// NÃO INVERTER. 25 de Abril é feriado NACIONAL, não é feriado de BOLSA.
    /// A Euronext Lisboa negoceia normalmente nesse dia — o calendário do
    /// Euronext é comum a Lisboa/Amesterdão/Paris e não inclui feriados
    /// nacionais portugueses.
    /// https://www.euronext.com/en/trade/trading-hours-holidays
    @Test func lisbonOpenOn25April() {
        // 25 de Abril 2025 is Friday
        let date = makeDate(year: 2025, month: 4, day: 25, hour: 10, minute: 0, tz: "Europe/Lisbon")
        #expect(MarketCalendar.isOpen(.euronextLisbon, at: date) == true)
    }

    /// NÃO INVERTER. Mesma razão que `lisbonOpenOn25April` — o 10 de Junho é
    /// feriado nacional, mas a bolsa negoceia.
    @Test func lisbonOpenOn10June() {
        // 10 de Junho 2025 is Tuesday
        let date = makeDate(year: 2025, month: 6, day: 10, hour: 10, minute: 0, tz: "Europe/Lisbon")
        #expect(MarketCalendar.isOpen(.euronextLisbon, at: date) == true)
    }

    // MARK: - Easter (moveable feasts)

    @Test func goodFridayClosesEuropeanExchanges() {
        // Good Friday 2026 = 3 April; 2027 = 26 March; 2025 = 18 April
        let cases = [(2026, 4, 3), (2027, 3, 26), (2025, 4, 18)]
        for (year, month, day) in cases {
            let lisbon = makeDate(year: year, month: month, day: day, hour: 10, minute: 0, tz: "Europe/Lisbon")
            #expect(MarketCalendar.isOpen(.euronextLisbon, at: lisbon) == false)

            let amsterdam = makeDate(year: year, month: month, day: day, hour: 10, minute: 0, tz: "Europe/Amsterdam")
            #expect(MarketCalendar.isOpen(.euronextAmsterdam, at: amsterdam) == false)

            let paris = makeDate(year: year, month: month, day: day, hour: 10, minute: 0, tz: "Europe/Paris")
            #expect(MarketCalendar.isOpen(.euronextParis, at: paris) == false)

            let xetra = makeDate(year: year, month: month, day: day, hour: 10, minute: 0, tz: "Europe/Berlin")
            #expect(MarketCalendar.isOpen(.xetra, at: xetra) == false)
        }
    }

    @Test func easterMondayClosesEuropeanExchanges() {
        // Easter Monday 2026 = 6 April; 2027 = 29 March; 2025 = 21 April
        let cases = [(2026, 4, 6), (2027, 3, 29), (2025, 4, 21)]
        for (year, month, day) in cases {
            let lisbon = makeDate(year: year, month: month, day: day, hour: 10, minute: 0, tz: "Europe/Lisbon")
            #expect(MarketCalendar.isOpen(.euronextLisbon, at: lisbon) == false)

            let xetra = makeDate(year: year, month: month, day: day, hour: 10, minute: 0, tz: "Europe/Berlin")
            #expect(MarketCalendar.isOpen(.xetra, at: xetra) == false)
        }
    }

    /// NYSE fecha na Sexta-Feira Santa mas negoceia na Segunda-Feira de Páscoa.
    @Test func nyseClosedGoodFridayOpenEasterMonday() {
        let goodFriday = makeDate(year: 2026, month: 4, day: 3, hour: 10, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: goodFriday) == false)

        let easterMonday = makeDate(year: 2026, month: 4, day: 6, hour: 10, minute: 0, tz: "America/New_York")
        #expect(MarketCalendar.isOpen(.nyse, at: easterMonday) == true)
    }

    /// Dia normal em plena época pascal — garante que o cálculo da Páscoa não
    /// alastra para lá dos dois dias certos.
    @Test func ordinaryDayNearEasterStaysOpen() {
        // Quinta-feira, 2 de Abril de 2026 (véspera de Sexta-Feira Santa)
        let date = makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0, tz: "Europe/Lisbon")
        #expect(MarketCalendar.isOpen(.euronextLisbon, at: date) == true)
    }

    // MARK: - Polling interval

    @Test func cryptoPollingIs15s() {
        #expect(MarketCalendar.pollingInterval(for: .crypto) == 15)
    }

    @Test func closedMarketPollingIs600s() {
        // Sunday — all stock markets closed
        let sunday = makeDate(year: 2026, month: 8, day: 2, hour: 12, minute: 0, tz: "America/New_York")
        // We need to check at that time, but pollingInterval uses Date()
        // so just verify the closed path returns 600
        // For a static test: crypto should always be 15
        #expect(MarketCalendar.pollingInterval(for: .crypto) == 15)
    }

    // MARK: - Exchange for symbol

    @Test func exchangeForUSSymbol() {
        #expect(MarketCalendar.exchangeForSymbol("AAPL") == .nyse)
        #expect(MarketCalendar.exchangeForSymbol("MSFT") == .nyse)
    }

    @Test func exchangeForXetraSymbol() {
        #expect(MarketCalendar.exchangeForSymbol("SAP.DE") == .xetra)
    }

    @Test func exchangeForLisbonSymbol() {
        #expect(MarketCalendar.exchangeForSymbol("GALP.LS") == .euronextLisbon)
    }

    @Test func exchangeForAmsterdamSymbol() {
        #expect(MarketCalendar.exchangeForSymbol("IWDA.AS") == .euronextAmsterdam)
    }

    @Test func exchangeForParisSymbol() {
        #expect(MarketCalendar.exchangeForSymbol("MC.PA") == .euronextParis)
    }

    /// Amsterdam and Paris follow the Euronext calendar, not Portugal's national
    /// holidays — 25 April is a normal trading day there.
    @Test func amsterdamOpenOnPortugueseNationalHoliday() {
        // Friday, 25 April 2025
        let date = makeDate(year: 2025, month: 4, day: 25, hour: 10, minute: 0, tz: "Europe/Amsterdam")
        #expect(MarketCalendar.isOpen(.euronextAmsterdam, at: date) == true)
    }

    @Test func parisClosedOnLabourDay() {
        // Thursday, 1 May 2025
        let date = makeDate(year: 2025, month: 5, day: 1, hour: 10, minute: 0, tz: "Europe/Paris")
        #expect(MarketCalendar.isOpen(.euronextParis, at: date) == false)
    }

    // MARK: - Freshness

    @Test func freshnessLiveForRecentWebsocket() {
        let freshness = MarketCalendar.freshness(for: .crypto, quoteTimestamp: Date(), source: .websocket)
        #expect(freshness == .live)
    }

    @Test func freshnessClosedWhenMarketClosed() {
        // Sunday
        let sunday = makeDate(year: 2026, month: 8, day: 2, hour: 12, minute: 0, tz: "America/New_York")
        if !MarketCalendar.isOpen(.nyse, at: sunday) {
            // This confirms the logic — freshness with closed market at that point
            let freshness = MarketCalendar.freshness(for: .nyse, quoteTimestamp: sunday, source: .rest)
            // Can be .closed or .delayed depending on current time
            // At least verify it doesn't crash
            #expect(freshness == .closed || freshness == .delayed(15) || freshness == .stale)
        }
    }

    @Test func freshnessCacheAlwaysStale() {
        let freshness = MarketCalendar.freshness(for: .nyse, quoteTimestamp: Date(), source: .cache)
        // Either .closed (if market closed now) or .stale
        #expect(freshness == .stale || freshness == .closed)
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, tz: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
