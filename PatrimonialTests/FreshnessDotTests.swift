import Foundation
import Testing
@testable import Patrimonial

// MARK: - Why two positions show two different dots with both markets shut

/// Reported from the device: HBM orange and NVD grey, side by side, at 15:00 in
/// Lisbon, with the reading that neither market was open yet.
///
/// Two premises in that reading are wrong and the third is the real answer, so
/// each is pinned here rather than argued.
struct FreshnessDotTests {

    private var lisbon: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return cal
    }

    private func lisbonTime(_ h: Int, _ m: Int = 0) -> Date {
        // Monday 10 August 2026, the afternoon the screen was read.
        lisbon.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: h, minute: m
        ))!
    }

    /// First premise: at 15:00 in Lisbon the New York session has not started.
    ///
    /// It has. Lisbon is on WEST and New York on EDT, four hours apart, so
    /// 15:00 there is 10:00 on the floor — half an hour after the bell.
    @Test func newYorkIsOpenAtThreeInTheAfternoonLisbonTime() {
        #expect(MarketCalendar.isOpen(.nyse, at: lisbonTime(15)))
        // And genuinely shut half an hour before the bell, so the test above is
        // not passing because `isOpen` says yes to everything.
        #expect(!MarketCalendar.isOpen(.nyse, at: lisbonTime(14)))
    }

    /// Second premise: orange means the price is out of date.
    ///
    /// Orange is `.delayed`. Out of date is `.stale`, and it is red. An orange
    /// dot beside an American position at 15:00 is the app saying the market is
    /// trading and the price is a fresh quote from it.
    @Test func orangeIsADelayedLiveQuoteNotAStaleOne() {
        let freshness = MarketCalendar.freshness(
            for: .nyse,
            quoteTimestamp: lisbonTime(15).addingTimeInterval(-10),
            source: .rest,
            now: lisbonTime(15)
        )
        #expect(freshness == .delayed(15))

        // Red is what an actually out-of-date price gets, and only once the
        // quote is old while the market is still trading.
        let stale = MarketCalendar.freshness(
            for: .nyse,
            quoteTimestamp: lisbonTime(15).addingTimeInterval(-600),
            source: .rest,
            now: lisbonTime(15)
        )
        #expect(stale == .stale)
    }

    /// Third premise, and the actual answer: grey on the XETRA position is not
    /// "the market is closed".
    ///
    /// XETRA is open at 15:00 Lisbon too — it is 16:00 in Berlin. The grey is
    /// `.dailyClose`: the only source that covers European venues on a free plan
    /// is Alpha Vantage's end-of-day, so the newest price the app can have for
    /// NVD is the last completed session's close, whatever the venue is doing
    /// right now.
    @Test func greyOnAEuropeanPositionIsAnEndOfDayPriceNotAClosedMarket() {
        let now = lisbonTime(15)
        #expect(MarketCalendar.isOpen(.xetra, at: now))

        let freshness = MarketCalendar.freshness(
            for: .xetra,
            quoteTimestamp: now,          // fetched seconds ago…
            source: .dailyClose,
            closeDate: lisbonTime(15).addingTimeInterval(-3 * 86_400),
            now: now
        )
        // …and still reported as a close, because that is what it describes.
        guard case .dailyClose = freshness else {
            Issue.record("um fecho diário passou por cotação viva: \(freshness)")
            return
        }
    }

    /// The two greys the indicator cannot tell apart, which is why the row
    /// spells the close date out in words next to the price. A dot has one
    /// colour and these are two different statements.
    @Test func closedMarketAndEndOfDayShareAColour() {
        let midnight = lisbonTime(23, 30)
        let closedMarket = MarketCalendar.freshness(
            for: .nyse, quoteTimestamp: midnight, source: .rest, now: midnight
        )
        #expect(closedMarket == .closed)

        let endOfDay = MarketCalendar.freshness(
            for: .xetra, quoteTimestamp: midnight, source: .dailyClose,
            closeDate: midnight, now: midnight
        )
        guard case .dailyClose = endOfDay else {
            Issue.record("esperava um fecho diário")
            return
        }
        // Same dot, different fact — the caption under the price is the only
        // thing that separates them.
    }
}
