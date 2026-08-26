import Foundation
import SwiftData

/// Writes one portfolio snapshot per day, so Evolução has something to draw.
///
/// `PortfolioSnapshot` has been in the schema since the model layer was built
/// and nothing ever wrote one — which meant the evolution chart could only ever
/// be empty, and would stay empty for as long as that went unnoticed. History
/// cannot be backfilled: a snapshot is a record of what the portfolio was worth
/// on a day, and there is no honest way to reconstruct one after the fact
/// (prices, FX rates and holdings all differed). So the only thing that matters
/// is that recording starts, and that it starts now.
///
/// Rules:
/// - **One per day.** Repeated launches overwrite the day's row rather than
///   adding to it, so the series stays one point per day.
/// - **Only when the total is honest.** A partially priced portfolio is not
///   recorded: a dip caused by a provider outage would be indistinguishable
///   from a real one a year from now, and the chart would show a crash that
///   never happened.
@MainActor
enum PortfolioSnapshotRecorder {

    /// Records today's value, replacing any row already written today.
    ///
    /// Returns whether a snapshot was stored, so a caller can tell "nothing to
    /// record" from "recorded".
    @discardableResult
    static func record(
        holdings: [Holding],
        accounts: [Account],
        in ctx: ModelContext,
        now: Date = Date()
    ) -> Bool {
        let open = holdings.filter(\.isOpen)

        // The strict total, not the partial one. The header may show a partial
        // figure with a caveat next to it — a stored data point has no caveat
        // and will be read as fact.
        guard open.isEmpty || PortfolioCalculator.totalMarketValue(open) != nil else {
            return false
        }

        let totalValue = PortfolioCalculator.totalMarketValue(open) ?? 0
        let totalCost = PortfolioCalculator.totalCost(open)
        let cashTotal = accounts
            .filter { $0.type != .brokerage }
            .reduce(Decimal(0)) { $0 + $1.balance }

        // Nothing at all to record on an empty app: a row of zeros would draw a
        // flat line at zero for however long the user takes to add a position.
        guard !(open.isEmpty && cashTotal == 0) else { return false }

        let day = dayStart(now)
        let existing = try? ctx.fetch(FetchDescriptor<PortfolioSnapshot>()).first {
            dayStart($0.date) == day
        }

        if let existing {
            existing.totalValue = totalValue
            existing.totalCost = totalCost
            existing.cashTotal = cashTotal
        } else {
            ctx.insert(PortfolioSnapshot(
                date: day,
                totalValue: totalValue,
                totalCost: totalCost,
                cashTotal: cashTotal
            ))
        }
        try? ctx.save()
        return true
    }

    /// Every snapshot, oldest first.
    static func series(in ctx: ModelContext) -> [PortfolioSnapshot] {
        let descriptor = FetchDescriptor<PortfolioSnapshot>(sortBy: [SortDescriptor(\.date)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    /// Whether there is a line to draw at all.
    ///
    /// One point is a dot, not a trend. The only ways to make a line out of it
    /// are to duplicate it or to extend it to today at the same value — both of
    /// which claim a flat stretch nobody measured. So the chart hides and the
    /// text explains why, and the rule lives here rather than as a `>= 2` buried
    /// in a view body where it can be relaxed without anyone noticing.
    static func drawsChart(_ snapshots: [PortfolioSnapshot]) -> Bool {
        snapshots.count >= 2
    }

    /// Local midnight: the series is one point per calendar day as the user
    /// experiences it, not per UTC day.
    static func dayStart(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}
