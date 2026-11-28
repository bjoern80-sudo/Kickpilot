import Foundation

/// League rules and tuning of the transfer automation.
enum AutoRules {
    static let maxSquadSize = 18
    static let maxPerClub = 3
    /// Minimum players per position that must always stay in the squad
    /// (1 TW, 2 ABW, 3 MIT, 4 ST): at least 1 goalkeeper, 3 defenders, 1 striker.
    static let minPerPosition: [Int: Int] = [1: 1, 2: 3, 4: 1]

    static func positionName(_ pos: Int) -> String {
        switch pos {
        case 1: return "Torhüter"
        case 2: return "Abwehrspieler"
        case 3: return "Mittelfeldspieler"
        case 4: return "Stürmer"
        default: return "Spieler"
        }
    }
    /// Players that are never planned for sale (best by Ø points) – a full lineup.
    static let keepCore = 11
    /// Selling to Kickbase always pays 100 % of the market value (confirmed by the user).
    static let kickbaseSaleFactor = 1.0
    /// Margin on top of the strongest expected competitor bid (percentage points).
    static let bidMarginPct = 1.0
    /// Overpay assumed for managers without enough history.
    static let defaultOverpayPct = 3.0
    /// Minimum number of buys before a manager's profile counts.
    static let minSamples = 3
    /// Days of market value momentum used to judge a player.
    static let momentumDays = 3.0
    /// Planned holding period: sell after this many days of further growth.
    static let holdDays = 3.0
    /// Trend stability: at least this many rising days among the last 5.
    static let minRisingDays = 4
    /// Minimum expected profit per bid: at least this share of the bid (scales with price) …
    static let minProfitPct = 5.0
    /// … and never less than this absolute floor.
    static let minProfit = 100_000.0
    /// Trend reversal: the bottom lies within the last this many days …
    static let reversalWindow = 6
    /// … has been followed by at least this many rising days in a row …
    static let reversalMinRises = 2
    /// … and before the bottom the value fell by at least this much (percent, within 10 days).
    static let reversalMinDropPct = 5.0
    /// The relevant peak is the highest value within this many days before the current rise.
    static let peakLookbackDays = 30
    /// Small dips (in percent) that do not end a rising phase.
    static let riseTolerancePct = 0.5
    /// Backtest window in days.
    static let backtestDays = 120
    /// Budget deadline: every Friday 20:30 (German time). Purchases that complete after it
    /// count for the following week and may push the budget below zero again right away.
    static let deadlineWeekday = 6 // Sunday = 1 … Friday = 6
    static let deadlineHour = 20
    static let deadlineMinute = 30
    /// Kickbase updates all market values once a day at 22:00 (German time).
    static let marketValueUpdateHour = 22
    /// Total bids may push the budget down to −30 % of the team value (league rule).
    static let maxDebtShareOfTeamValue = 0.30
    /// From this many hours before the deadline the sale plan is pushed.
    static let deadlineWarningHours = 6.0

    static var berlin: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return c
    }

    /// Next Friday 20:30 Europe/Berlin (today if it is still before 20:30 on a Friday).
    static func nextDeadline(after now: Date = Date()) -> Date {
        berlin.nextDate(
            after: now,
            matching: DateComponents(hour: deadlineHour, minute: deadlineMinute, second: 0, weekday: deadlineWeekday),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(7 * 86_400)
    }
}

/// Market value on a given day from a (sorted ascending) history.
func marketValue(in history: [MVPoint], at date: Date) -> Double? {
    history.last(where: { $0.date <= date })?.value ?? history.first?.value
}

func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
    return s[idx]
}

// MARK: - Bidder profiles

/// How much a manager typically pays above the market value of the purchase day.
struct BidderProfile: Identifiable {
    let id: String
    let name: String
    let samples: Int
    let medianOverpay: Double?
    /// 75th percentile – used as "what they would roughly bid".
    let typicalHighOverpay: Double?
    let maxOverpay: Double?
    let buysPerWeek: Double

    var isReliable: Bool { samples >= AutoRules.minSamples }
    /// Expected bid premium in percent, falling back to a default.
    var expectedOverpay: Double { (isReliable ? typicalHighOverpay : nil) ?? AutoRules.defaultOverpayPct }

    init(manager: Manager, transfers: [Transfer], history: [String: [MVPoint]]) {
        id = manager.id
        name = manager.name
        let buys = transfers.filter { $0.buyerId == manager.id }
        let ratios: [Double] = buys.compactMap { t in
            guard let h = history[t.playerId], let mv = marketValue(in: h, at: t.date), mv > 0 else { return nil }
            return (t.price / mv - 1) * 100
        }
        samples = ratios.count
        medianOverpay = percentile(ratios, 0.5)
        typicalHighOverpay = percentile(ratios, 0.75)
        maxOverpay = ratios.max()
        if let oldest = transfers.map(\.date).min() {
            let weeks = max(1, Date().timeIntervalSince(oldest) / (7 * 86_400))
            buysPerWeek = Double(buys.count) / weeks
        } else {
            buysPerWeek = 0
        }
    }
}

// MARK: - Trend & peaks

enum TrendPattern: String, Hashable {
    /// Rose on most of the last days.
    case steadyRise = "stabiler Anstieg"
    /// Fell to a bottom and is rising again since.
    case reversal = "Trendumkehr"
    case none = "kein Muster"

    var short: String {
        switch self {
        case .steadyRise: return "Anstieg"
        case .reversal: return "Umkehr"
        case .none: return "–"
        }
    }
}

/// Market value trend of a player: current rise, previous peak and expected sale value.
struct TrendEvaluation: Hashable {
    let pattern: TrendPattern
    /// Bottom of a reversal and how far the value fell before it.
    let trough: Double?
    let dropBeforeTroughPct: Double?
    let current: Double
    /// Average absolute gain per day over the last `momentumDays`.
    let dailyGain: Double
    let momentumPct: Double
    /// Rising days among the last 5.
    let risingDays: Int
    /// Highest value within `peakLookbackDays` before the current rising phase – usually not exceeded.
    let peak: Double?
    let peakDate: Date?
    /// Expected value after `holdDays`, capped at the previous peak.
    let expectedSale: Double

    var headroomPct: Double? {
        guard let peak, current > 0 else { return nil }
        return (peak / current - 1) * 100
    }

    /// - Parameter points: daily history, ascending; the last point is "today".
    static func evaluate(_ points: [MVPoint]) -> TrendEvaluation? {
        let v = points.map(\.value)
        let n = v.count
        let back = Int(AutoRules.momentumDays)
        guard n >= max(6, back + 1), let current = v.last, current > 0 else { return nil }

        let base = v[n - 1 - back]
        var dailyGain = (current - base) / Double(back)
        let momentumPct = base > 0 ? (current / base - 1) * 100 : 0
        let risingDays = (n - 5..<n).filter { v[$0] > v[$0 - 1] }.count

        // Trend reversal: recent bottom, clear fall before it, rising every day since.
        var pattern: TrendPattern = risingDays >= AutoRules.minRisingDays && momentumPct > 0 ? .steadyRise : .none
        var trough: Double? = nil
        var drop: Double? = nil
        let window = min(AutoRules.reversalWindow, n - 1)
        if n >= 12, let t = (n - window..<n).min(by: { v[$0] < v[$1] }),
           n - 1 - t >= AutoRules.reversalMinRises,
           (t + 1..<n).allSatisfy({ v[$0] > v[$0 - 1] }),
           let before = v[max(0, t - 10)..<t].max(), v[t] > 0 {
            let fell = (before / v[t] - 1) * 100
            if fell >= AutoRules.reversalMinDropPct {
                trough = v[t]
                drop = fell
                if pattern == .none {
                    pattern = .reversal
                    // Momentum since the bottom.
                    dailyGain = (current - v[t]) / Double(n - 1 - t)
                }
            }
        }

        // Walk back to the start of the current rising phase (small dips tolerated).
        var start = n - 1
        while start > 0, v[start - 1] <= v[start] * (1 + AutoRules.riseTolerancePct / 100) {
            start -= 1
        }
        var peak: Double? = nil
        var peakDate: Date? = nil
        let lookFrom = max(0, start - AutoRules.peakLookbackDays)
        if start > 0, let idx = v[lookFrom..<start].indices.max(by: { v[$0] < v[$1] }) {
            peak = v[idx]
            peakDate = points[idx].date
        }

        let projected = current + max(0, dailyGain) * AutoRules.holdDays
        let expectedSale = peak.map { $0 > current ? min($0, projected) : current } ?? current
        return TrendEvaluation(
            pattern: pattern, trough: trough, dropBeforeTroughPct: drop,
            current: current, dailyGain: dailyGain, momentumPct: momentumPct,
            risingDays: risingDays, peak: peak, peakDate: peakDate, expectedSale: expectedSale
        )
    }
}

/// History with today's market value appended – only if it is a new value.
/// Kickbase updates market values once a day at 22:00; before that the current
/// value equals the last history point and appending it would fake a "flat" day.
func historyWithCurrent(_ h: [MVPoint], current: Double, now: Date) -> [MVPoint] {
    guard current > 0 else { return h }
    guard let last = h.last else { return [MVPoint(date: now, value: current)] }
    if abs(last.value - current) < 1 { return h }
    if Calendar.current.isDate(last.date, inSameDayAs: now) {
        return h.dropLast() + [MVPoint(date: last.date, value: current)]
    }
    return h + [MVPoint(date: now, value: current)]
}

enum BidCheck {
    case ok(profit: Double)
    case skip(String)

    /// The buy rules shared by live planning and the backtest.
    static func check(_ t: TrendEvaluation, bid: Double, isFit: Bool) -> BidCheck {
        if !isFit { return .skip("nicht fit") }
        if t.pattern == .none {
            return .skip(t.dailyGain > 0
                ? "weder stabiler Anstieg (\(t.risingDays)/5 Tage) noch Trendumkehr"
                : "kein Aufwärtstrend")
        }
        guard let peak = t.peak else { return .skip("zu wenig Verlauf für einen Hochpunkt") }
        if peak <= t.current { return .skip("liegt schon über dem letzten Hochpunkt (\(Fmt.mio(peak)))") }
        let profit = t.expectedSale - bid
        let required = max(AutoRules.minProfit, bid * AutoRules.minProfitPct / 100)
        if profit < required {
            return .skip("Gewinn bis Hochpunkt zu klein (\(Fmt.signedEur(profit)))")
        }
        return .ok(profit: profit)
    }
}

func roundBid(_ raw: Double) -> Double { (raw / 10_000).rounded(.up) * 10_000 + 1_111 }

// MARK: - Backtest

/// How the buy rule would have done in the past: buy at day d (MV + premium),
/// sell after `holdDays` at the then market value.
struct BacktestStats: Hashable {
    var signals = 0
    var wins = 0
    var totalProfitPct = 0.0
    /// Sold value reached the predicted target.
    var targetReached = 0

    var hitRate: Double { signals > 0 ? Double(wins) / Double(signals) * 100 : 0 }
    var avgProfitPct: Double { signals > 0 ? totalProfitPct / Double(signals) : 0 }
    var targetRate: Double { signals > 0 ? Double(targetReached) / Double(signals) * 100 : 0 }

    mutating func add(bid: Double, sold: Double, target: Double) {
        signals += 1
        if sold > bid { wins += 1 }
        if sold >= target { targetReached += 1 }
        totalProfitPct += (sold / bid - 1) * 100
    }
}

struct BacktestResult: Hashable {
    var all = BacktestStats()
    var steady = BacktestStats()
    var reversal = BacktestStats()

    static func run(histories: [[MVPoint]], premiumPct: Double) -> BacktestResult {
        var r = BacktestResult()
        let hold = Int(AutoRules.holdDays)
        for h in histories where h.count > 30 {
            let firstDay = max(10, h.count - AutoRules.backtestDays)
            guard firstDay < h.count - hold else { continue }
            for d in firstDay..<(h.count - hold) {
                guard let t = TrendEvaluation.evaluate(Array(h[0...d])) else { continue }
                let bid = roundBid(t.current * (1 + premiumPct / 100))
                guard case .ok = BidCheck.check(t, bid: bid, isFit: true) else { continue }
                let sold = h[d + hold].value
                r.all.add(bid: bid, sold: sold, target: t.expectedSale)
                if t.pattern == .reversal {
                    r.reversal.add(bid: bid, sold: sold, target: t.expectedSale)
                } else {
                    r.steady.add(bid: bid, sold: sold, target: t.expectedSale)
                }
            }
        }
        return r
    }
}

// MARK: - Plan

struct BuyProposal: Identifiable, Hashable {
    let player: Player
    let bid: Double
    /// Market value growth over `AutoRules.momentumDays` in percent.
    let momentumPct: Double
    /// Strongest expected competitor premium in percent (and who).
    let competitorPct: Double
    let competitorName: String
    /// Expected sale value (capped at the last peak) minus the bid.
    let expectedGain: Double
    let trend: TrendEvaluation
    /// Auction ends after Friday 20:30 – does not count for this week's balance.
    let afterDeadline: Bool
    var id: String { player.id }
    var bidOverMVPct: Double { player.marketValue > 0 ? (bid / player.marketValue - 1) * 100 : 0 }
}

struct SaleProposal: Identifiable, Hashable {
    let player: Player
    let expectedProceeds: Double
    /// Gain vs. own purchase price (or 7-day growth if unknown), in percent.
    let gainPct: Double
    let gainBasis: String
    var id: String { player.id }
}

struct SkippedCandidate: Identifiable, Hashable {
    let player: Player
    let reason: String
    var id: String { player.id }
}

struct AutoPlan {
    var buys: [BuyProposal] = []
    var skipped: [SkippedCandidate] = []
    var sales: [SaleProposal] = []
    /// Budget that can be raised on Friday from non-core players.
    var reserve: Double = 0
    /// Room for bids on auctions ending before the deadline (balance-able by Friday).
    var bidLimit: Double = 0
    /// Overall room: budget − all open bids + 30 % of the team value.
    var globalLimit: Double = 0
    var debtLimit: Double = 0
    /// All my open bids, including auctions ending after the deadline.
    var allOpenBids: Double = 0
    var deadline = AutoRules.nextDeadline()
    var budgetAfterSales: Double = 0
    /// Budget minus open bids ending before the deadline (basis of the Friday balance).
    var committedBudget: Double = 0
    /// Expected premium of the strongest competitor (percent) and who it is.
    var competitorPct: Double = AutoRules.defaultOverpayPct
    var competitorName = "–"
    var backtest = BacktestResult()

    /// Bid the model would place on this player (same formula as for proposals).
    func recommendedBid(for p: Player) -> Double {
        roundBid(max(p.marketValue * (1 + (competitorPct + AutoRules.bidMarginPct) / 100), p.effectivePrice))
    }
    /// My open bids on players whose auction ends before the deadline.
    var openBids: Double = 0

    var totalBids: Double { buys.reduce(0) { $0 + $1.bid } }
}

enum AutoPlanner {
    /// - Parameters:
    ///   - openBidPlayerIds: players I already bid on (skipped for new bids).
    static func plan(
        budget: Double,
        squad: [Player],
        market: [Player],
        myUserId: String,
        transfers: [Transfer],
        profiles: [BidderProfile],
        history: [String: [MVPoint]],
        openBidPlayerIds: Set<String>,
        now: Date = Date()
    ) -> AutoPlan {
        var plan = AutoPlan()
        plan.deadline = AutoRules.nextDeadline(after: now)
        // Open bids that may still win before the deadline count as already spent.
        plan.openBids = market
            .filter { ($0.expiresAt ?? .distantFuture) <= plan.deadline }
            .compactMap(\.myOfferPrice)
            .reduce(0, +)
        let committedBudget = budget - plan.openBids
        plan.committedBudget = committedBudget

        // League rule: all bids together may push the budget to at most −30 % of the team value.
        let teamValue = squad.reduce(0) { $0 + $1.marketValue }
        plan.debtLimit = teamValue * AutoRules.maxDebtShareOfTeamValue
        plan.allOpenBids = market.compactMap(\.myOfferPrice).reduce(0, +)
        plan.globalLimit = max(0, budget - plan.allOpenBids + plan.debtLimit)

        // Players outside the best 11 (Ø points) can be sold to Kickbase on Friday.
        let core = Set(squad.sorted { $0.averagePoints > $1.averagePoints }.prefix(AutoRules.keepCore).map(\.id))
        let sellable = squad.filter { !core.contains($0.id) }
        plan.reserve = sellable.reduce(0) { $0 + $1.marketValue * AutoRules.kickbaseSaleFactor }
        // Never bid more than can be balanced again by Friday.
        plan.bidLimit = max(0, committedBudget + plan.reserve)

        // Strongest competitor (other managers) – their typical high premium.
        let rivals = profiles.filter { $0.id != myUserId }
        let strongest = rivals.max { $0.expectedOverpay < $1.expectedOverpay }
        let competitorPct = strongest?.expectedOverpay ?? AutoRules.defaultOverpayPct
        let competitorName = strongest?.name ?? "–"
        plan.competitorPct = competitorPct
        plan.competitorName = competitorName

        // Players I already bid on may still join the squad.
        let pending = market.filter { $0.myOfferPrice != nil }
        var squadCount = squad.count + pending.count
        var perClub = Dictionary(grouping: squad + pending, by: \.teamId).mapValues(\.count)
        var remaining = plan.bidLimit
        var globalRemaining = plan.globalLimit

        plan.backtest = BacktestResult.run(
            histories: Array(history.values),
            premiumPct: competitorPct + AutoRules.bidMarginPct
        )

        // Evaluate every market player (not my own listings); best expected profit first.
        let evaluated: [(Player, TrendEvaluation, Double, BidCheck)] = market.compactMap { p in
            guard p.sellerUserId != myUserId, p.marketValue > 0 else { return nil }
            let h = historyWithCurrent(history[p.id] ?? [], current: p.marketValue, now: now)
            guard let t = TrendEvaluation.evaluate(h) else {
                plan.skipped.append(.init(player: p, reason: "kein Marktwertverlauf"))
                return nil
            }
            // Odd amount just above a round number beats "round" bids of others.
            let bid = plan.recommendedBid(for: p)
            return (p, t, bid, BidCheck.check(t, bid: bid, isFit: p.isFit))
        }
        .sorted { a, b in
            func profit(_ c: BidCheck) -> Double { if case .ok(let x) = c { return x } else { return -.infinity } }
            return profit(a.3) > profit(b.3)
        }

        for (p, trend, bid, check) in evaluated {
            let momentum = trend.momentumPct
            let expectedGain: Double
            switch check {
            case .skip(let reason):
                plan.skipped.append(.init(player: p, reason: reason))
                continue
            case .ok(let profit):
                expectedGain = profit
            }
            let ends = p.expiresAt ?? .distantFuture
            let afterDeadline = ends > plan.deadline

            // Only bid on the day the listing ends: by then the trend is more reliable.
            let endsToday = p.expiresAt.map { AutoRules.berlin.isDate($0, inSameDayAs: now) } ?? false

            if openBidPlayerIds.contains(p.id) {
                plan.skipped.append(.init(player: p, reason: "Du hast schon geboten"))
            } else if !endsToday {
                plan.skipped.append(.init(player: p, reason: "Angebot endet nicht heute"))
            } else if squadCount >= AutoRules.maxSquadSize {
                plan.skipped.append(.init(player: p, reason: "Kader voll (\(AutoRules.maxSquadSize))"))
            } else if perClub[p.teamId, default: 0] >= AutoRules.maxPerClub {
                plan.skipped.append(.init(player: p, reason: "Schon \(AutoRules.maxPerClub) Spieler dieses Vereins"))
            } else if bid > globalRemaining {
                plan.skipped.append(.init(player: p, reason: "Über der Minus-Grenze (−\(Int(AutoRules.maxDebtShareOfTeamValue * 100)) % Teamwert)"))
            } else if !afterDeadline && bid > remaining {
                plan.skipped.append(.init(player: p, reason: "Nicht bis Freitag ausgleichbar"))
            } else {
                plan.buys.append(.init(
                    player: p, bid: bid, momentumPct: momentum,
                    competitorPct: competitorPct, competitorName: competitorName,
                    expectedGain: expectedGain, trend: trend, afterDeadline: afterDeadline
                ))
                squadCount += 1
                perClub[p.teamId, default: 0] += 1
                globalRemaining -= bid
                if !afterDeadline { remaining -= bid }
            }
        }
        plan.buys.sort { $0.expectedGain > $1.expectedGain }

        plan.sales = saleProposals(
            budget: committedBudget, squad: squad, core: core, myUserId: myUserId,
            transfers: transfers, history: history, now: now
        )
        plan.budgetAfterSales = committedBudget + plan.sales.reduce(0) { $0 + $1.expectedProceeds }
        return plan
    }

    /// Weakest players with the best value gain, until the budget is ≥ 0.
    static func saleProposals(
        budget: Double,
        squad: [Player],
        core: Set<String>,
        myUserId: String,
        transfers: [Transfer],
        history: [String: [MVPoint]],
        now: Date
    ) -> [SaleProposal] {
        guard budget < 0 else { return [] }

        let lastBuy: [String: Transfer] = Dictionary(
            transfers.filter { $0.buyerId == myUserId }.map { ($0.playerId, $0) },
            uniquingKeysWith: { a, b in a.date > b.date ? a : b }
        )
        let weekAgo = now.addingTimeInterval(-7 * 86_400)

        func gain(_ p: Player) -> (Double, String) {
            if let g = p.gainSincePurchase, p.marketValue - g > 0 {
                return (g / (p.marketValue - g) * 100, "seit Kauf")
            }
            if let t = lastBuy[p.id], t.price > 0 {
                return ((p.marketValue / t.price - 1) * 100, "ggü. Kaufpreis")
            }
            if let h = history[p.id], let then = marketValue(in: h, at: weekAgo), then > 0 {
                return ((p.marketValue / then - 1) * 100, "7 Tage")
            }
            return (0, "unbekannt")
        }

        // Rank: weak (low Ø points) and high gain first; core players only as last resort.
        let byPoints = squad.sorted { $0.averagePoints < $1.averagePoints }.map(\.id)
        let byGain = squad.sorted { gain($0).0 > gain($1).0 }.map(\.id)
        func rank(_ p: Player) -> Int {
            (byPoints.firstIndex(of: p.id) ?? 0) + (byGain.firstIndex(of: p.id) ?? 0)
        }
        let ordered = squad.filter { !core.contains($0.id) }.sorted { rank($0) < rank($1) }
            + squad.filter { core.contains($0.id) }.sorted { rank($0) < rank($1) }

        var result: [SaleProposal] = []
        var balance = budget
        // Remaining players per position – never go below the minimum line-up.
        var perPosition = Dictionary(grouping: squad, by: \.position).mapValues(\.count)
        for p in ordered where balance < 0 {
            let minimum = AutoRules.minPerPosition[p.position] ?? 0
            guard perPosition[p.position, default: 0] > minimum else { continue }
            perPosition[p.position, default: 0] -= 1
            let proceeds = p.marketValue * AutoRules.kickbaseSaleFactor
            let g = gain(p)
            result.append(.init(player: p, expectedProceeds: proceeds, gainPct: g.0, gainBasis: g.1))
            balance += proceeds
        }
        return result
    }
}

// MARK: - Injury warning
// Same as injury_alerts in planner.py. Kickbase updates market values at 22:00; an
// injured player usually loses value from the next update on, so selling before 22:00
// still brings today's market value (100 % on a sale to Kickbase).

struct InjuryAlert: Identifiable, Hashable {
    static let injuredStatus = 1 // `st` 1 = verletzt

    let player: Player
    let proceeds: Double
    let sellable: Bool
    /// Why a sale is not possible, otherwise "".
    let reason: String
    /// Among the best 11 by Ø points.
    let inCore: Bool
    var id: String { player.id }

    /// Own players newly reported injured since the last check (`knownInjured`).
    static func alerts(squad: [Player], knownInjured: Set<String>) -> [InjuryAlert] {
        let byAvg = squad.sorted { $0.averagePoints > $1.averagePoints }
        let core = Set(byAvg.prefix(AutoRules.keepCore).map(\.id))
        let perPosition = Dictionary(grouping: squad, by: \.position).mapValues(\.count)
        return byAvg.filter { $0.status == injuredStatus && !knownInjured.contains($0.id) }.map { p in
            let minimum = AutoRules.minPerPosition[p.position] ?? 0
            let sellable = perPosition[p.position, default: 0] > minimum
            return InjuryAlert(
                player: p, proceeds: p.marketValue * AutoRules.kickbaseSaleFactor, sellable: sellable,
                reason: sellable ? "" : "Mindestbesetzung (\(minimum) \(p.positionName))",
                inCore: core.contains(p.id)
            )
        }
    }

    static func injuredIds(_ squad: [Player]) -> Set<String> {
        Set(squad.filter { $0.status == injuredStatus }.map(\.id))
    }
}

// MARK: - Points forecast
// Same as forecast_points in planner.py. Transparent rule of thumb: half season average,
// half form of the last 4 matchdays, scaled by how often the player actually played, the
// opponent's table position and home advantage.

/// Points history: `ap` and `ph` (last 5 matchdays, NEWEST first; nil = not played).
struct PlayerForm: Hashable, Sendable {
    let playerId: String
    let averagePoints: Double
    let recent: [Double?]

    init(json j: JSONObject, playerId: String? = nil) {
        self.playerId = playerId ?? J.str(j["i"]) ?? ""
        averagePoints = J.dbl(j["ap"]) ?? 0
        recent = J.arr(j["ph"]).map { J.bool($0["hp"]) ? (J.dbl($0["p"]) ?? 0) : nil }
    }
}

enum ForecastRules {
    static let formWindow = 4
    static let opponentSpread = 0.20
    static let homeFactor = 1.05
    static let awayFactor = 0.95
    static let strickenFactor = 0.5
    static let leagueSize = 18
    /// Upgrade buys: forecast must beat the weakest starter of the same position by this much.
    static let upgradeMinGain = 20.0
}

struct Fixture: Hashable { let opponentId: String; let home: Bool }

enum PointsForecast {
    /// Expected points of `player` on the next matchday (0 if he cannot play).
    static func points(_ player: Player, form: PlayerForm?, fixture: Fixture?, tablePlace: [String: Int]) -> Double {
        guard let fixture else { return 0 }
        let statusFactor: Double
        switch player.status {
        case 0: statusFactor = 1
        case 2: statusFactor = ForecastRules.strickenFactor
        default: return 0
        }
        let avg = (form?.averagePoints ?? 0) > 0 ? form!.averagePoints : player.averagePoints
        var recent = form?.recent ?? []
        // ph[0] = current matchday; "not played" there usually means "not yet played".
        if let first = recent.first, first == nil { recent.removeFirst() }
        let window = Array(recent.prefix(ForecastRules.formWindow))
        let played = window.compactMap { $0 }
        let share: Double, base: Double
        if window.isEmpty {
            share = 1; base = avg
        } else {
            share = Double(played.count) / Double(window.count)
            base = played.isEmpty ? 0 : 0.5 * avg + 0.5 * played.reduce(0, +) / Double(played.count)
        }
        let mid = Double(ForecastRules.leagueSize + 1) / 2
        let opponent = tablePlace[fixture.opponentId].map {
            1 + ForecastRules.opponentSpread * (Double($0) - mid) / (Double(ForecastRules.leagueSize) - mid)
        } ?? 1
        let venue = fixture.home ? ForecastRules.homeFactor : ForecastRules.awayFactor
        return max(0, base * share * opponent * venue * statusFactor)
    }
}

struct UpgradeProposal: Identifiable, Hashable {
    let player: Player
    let bid: Double
    let forecast: Double
    let replaces: Player
    let replacesForecast: Double
    let afterDeadline: Bool
    var gain: Double { forecast - replacesForecast }
    var id: String { player.id }

    /// Market players that clearly beat my weakest starter of the same position (sporting buys).
    /// Same budget rules as the trading buys. Read-only. Same as upgrade_proposals in planner.py.
    static func proposals(plan: AutoPlan, squad: [Player], market: [Player], myUserId: String,
                          forecasts: [String: Double], now: Date = Date()) -> [UpgradeProposal] {
        let starters = squad.filter { $0.lineupSlot != nil }
        let taken = Set(plan.buys.map(\.player.id))
        var remaining = plan.bidLimit - plan.buys.filter { !$0.afterDeadline }.reduce(0) { $0 + $1.bid }
        var globalRemaining = plan.globalLimit - plan.totalBids
        var squadCount = squad.count + plan.buys.count
        var perClub = Dictionary(grouping: squad + plan.buys.map(\.player), by: \.teamId).mapValues(\.count)
        func fc(_ p: Player) -> Double { forecasts[p.id] ?? 0 }

        var candidates: [(Double, Player, Player)] = []
        for p in market {
            guard !taken.contains(p.id), p.myOfferPrice == nil, p.sellerUserId != myUserId, p.isFit,
                  let ends = p.expiresAt, AutoRules.berlin.isDate(ends, inSameDayAs: now) else { continue }
            let same = starters.filter { $0.position == p.position }
            guard let weakest = same.min(by: { fc($0) < fc($1) }) else { continue }
            let gain = fc(p) - fc(weakest)
            if gain >= ForecastRules.upgradeMinGain { candidates.append((gain, p, weakest)) }
        }
        var result: [UpgradeProposal] = []
        var replaced = Set<String>()
        for (_, p, weakest) in candidates.sorted(by: { $0.0 > $1.0 }) where !replaced.contains(weakest.id) {
            let bid = plan.recommendedBid(for: p)
            let afterDeadline = (p.expiresAt ?? .distantFuture) > plan.deadline
            guard squadCount < AutoRules.maxSquadSize, perClub[p.teamId, default: 0] < AutoRules.maxPerClub,
                  bid <= globalRemaining, afterDeadline || bid <= remaining else { continue }
            result.append(.init(player: p, bid: bid, forecast: fc(p), replaces: weakest,
                                replacesForecast: fc(weakest), afterDeadline: afterDeadline))
            replaced.insert(weakest.id)
            squadCount += 1
            perClub[p.teamId, default: 0] += 1
            globalRemaining -= bid
            if !afterDeadline { remaining -= bid }
        }
        return result
    }
}

// MARK: - Sell signal: falling market value
// Same as trend_sales in planner.py. Players outside the best 11 whose market value has
// fallen two days in a row and is clearly below its recent peak.

enum TrendSaleRules {
    static let fallingDays = 2
    static let peakLookbackDays = 14
    static let minDropPct = 3.0
}

struct TrendSale: Identifiable, Hashable {
    let player: Player
    let proceeds: Double
    let dropPct: Double
    let peak: Double
    let peakDate: Date
    var id: String { player.id }

    static func signals(squad: [Player], history: [String: [MVPoint]], now: Date = Date()) -> [TrendSale] {
        let core = Set(squad.sorted { $0.averagePoints > $1.averagePoints }.prefix(AutoRules.keepCore).map(\.id))
        var perPosition = Dictionary(grouping: squad, by: \.position).mapValues(\.count)
        var result: [TrendSale] = []
        for p in squad where !core.contains(p.id) && !p.onMarket {
            guard perPosition[p.position, default: 0] > (AutoRules.minPerPosition[p.position] ?? 0) else { continue }
            let h = historyWithCurrent(history[p.id] ?? [], current: p.marketValue, now: now)
            let n = TrendSaleRules.fallingDays
            guard h.count >= n + 2 else { continue }
            let tail = h.suffix(n + 1).map(\.value)
            guard zip(tail, tail.dropFirst()).allSatisfy({ $1 < $0 }) else { continue }
            let window = h.suffix(TrendSaleRules.peakLookbackDays)
            guard let peak = window.max(by: { $0.value < $1.value }), peak.value > 0, let last = h.last else { continue }
            let drop = (1 - last.value / peak.value) * 100
            guard drop >= TrendSaleRules.minDropPct else { continue }
            result.append(.init(player: p, proceeds: p.marketValue * AutoRules.kickbaseSaleFactor,
                                dropPct: drop, peak: peak.value, peakDate: peak.date))
            perPosition[p.position, default: 0] -= 1
        }
        return result.sorted { $0.dropPct > $1.dropPct }
    }
}
