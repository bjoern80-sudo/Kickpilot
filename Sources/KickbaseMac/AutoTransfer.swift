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
    /// Kickbase's instant offer is assumed slightly below market value (safety margin).
    static let kickbaseSaleFactor = 0.97
    /// Margin on top of the strongest expected competitor bid (percentage points).
    static let bidMarginPct = 1.0
    /// Overpay assumed for managers without enough history.
    static let defaultOverpayPct = 3.0
    /// Minimum number of buys before a manager's profile counts.
    static let minSamples = 3
    /// Days of market value momentum used to judge a player.
    static let momentumDays = 3.0
    /// Budget deadline: every Friday 19:00 (German time).
    static let deadlineWeekday = 6 // Sunday = 1 … Friday = 6
    static let deadlineHour = 19
    /// Purchases that complete from Friday 20:00 on count for the following week
    /// and may push the budget below zero.
    static let freeWindowHour = 20
    /// Total bids may push the budget down to −30 % of the team value (league rule).
    static let maxDebtShareOfTeamValue = 0.30
    /// From this many hours before the deadline the sale plan is pushed.
    static let deadlineWarningHours = 6.0

    static var berlin: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return c
    }

    /// Next Friday 19:00 Europe/Berlin (today if it is still before 19:00 on a Friday).
    static func nextDeadline(after now: Date = Date()) -> Date {
        berlin.nextDate(
            after: now,
            matching: DateComponents(hour: deadlineHour, minute: 0, second: 0, weekday: deadlineWeekday),
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

// MARK: - Plan

struct BuyProposal: Identifiable, Hashable {
    let player: Player
    let bid: Double
    /// Market value growth over `AutoRules.momentumDays` in percent.
    let momentumPct: Double
    /// Strongest expected competitor premium in percent (and who).
    let competitorPct: Double
    let competitorName: String
    /// Expected value gain if the momentum holds, minus the premium paid.
    let expectedGain: Double
    /// Auction ends Friday 20:00 or later – does not count for this week's balance.
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
    /// Friday 20:00 – auctions ending from here on count for the following week.
    var freeFrom = AutoRules.nextDeadline().addingTimeInterval(3600)
    var budgetAfterSales: Double = 0
    /// Budget minus open bids ending before the deadline (basis of the Friday balance).
    var committedBudget: Double = 0
    /// Expected premium of the strongest competitor (percent) and who it is.
    var competitorPct: Double = AutoRules.defaultOverpayPct
    var competitorName = "–"

    /// Bid the model would place on this player (same formula as for proposals).
    func recommendedBid(for p: Player) -> Double {
        let raw = max(p.marketValue * (1 + (competitorPct + AutoRules.bidMarginPct) / 100), p.effectivePrice)
        return (raw / 10_000).rounded(.up) * 10_000 + 1_111
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
        plan.freeFrom = plan.deadline.addingTimeInterval(
            Double(AutoRules.freeWindowHour - AutoRules.deadlineHour) * 3600
        )

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

        let candidates: [(Player, Double)] = market.compactMap { p in
            guard p.sellerUserId != myUserId, p.marketValue > 0 else { return nil }
            let past = now.addingTimeInterval(-AutoRules.momentumDays * 86_400)
            let mvThen = history[p.id].flatMap { marketValue(in: $0, at: past) }
                ?? (p.marketValue - p.trend24h * AutoRules.momentumDays)
            guard mvThen > 0 else { return nil }
            return (p, (p.marketValue / mvThen - 1) * 100)
        }
        .sorted { $0.1 > $1.1 }

        for (p, momentum) in candidates {
            guard momentum > 0, p.trend24h > 0 else { continue }

            // Odd amount just above a round number beats "round" bids of others.
            let bid = plan.recommendedBid(for: p)
            let expectedGain = p.marketValue * momentum / 100 - (bid - p.marketValue)
            let ends = p.expiresAt ?? .distantFuture
            let afterDeadline = ends >= plan.freeFrom
            let inGap = ends > plan.deadline && ends < plan.freeFrom

            if openBidPlayerIds.contains(p.id) {
                plan.skipped.append(.init(player: p, reason: "Du hast schon geboten"))
            } else if expectedGain <= 0 {
                plan.skipped.append(.init(player: p, reason: "Aufpreis frisst den erwarteten Zuwachs"))
            } else if squadCount >= AutoRules.maxSquadSize {
                plan.skipped.append(.init(player: p, reason: "Kader voll (\(AutoRules.maxSquadSize))"))
            } else if perClub[p.teamId, default: 0] >= AutoRules.maxPerClub {
                plan.skipped.append(.init(player: p, reason: "Schon \(AutoRules.maxPerClub) Spieler dieses Vereins"))
            } else if inGap {
                plan.skipped.append(.init(player: p, reason: "Endet Freitag zwischen 19 und 20 Uhr"))
            } else if bid > globalRemaining {
                plan.skipped.append(.init(player: p, reason: "Über der Minus-Grenze (−\(Int(AutoRules.maxDebtShareOfTeamValue * 100)) % Teamwert)"))
            } else if !afterDeadline && bid > remaining {
                plan.skipped.append(.init(player: p, reason: "Nicht bis Freitag ausgleichbar"))
            } else {
                plan.buys.append(.init(
                    player: p, bid: bid, momentumPct: momentum,
                    competitorPct: competitorPct, competitorName: competitorName,
                    expectedGain: expectedGain, afterDeadline: afterDeadline
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
