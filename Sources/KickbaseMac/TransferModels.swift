import Foundation

/// One entry of /v4/leagues/{lid}/managers/{uid}/transfer (seen from that manager).
struct ManagerTransferEntry: Hashable, Sendable {
    let userId: String
    let playerId: String
    let playerName: String
    let teamId: String
    let date: Date
    let price: Double
    let isBuy: Bool

    init?(json e: JSONObject, userId: String) {
        guard let pid = J.str(e["pi"]),
              let date = KickbaseAPI.parseDate(J.str(e["dt"])) else { return nil }
        let tty = J.int(e["tty"]) ?? 0
        guard tty == 1 || tty == 2 else { return nil }
        self.userId = userId
        playerId = pid
        playerName = J.str(e["pn"]) ?? "Spieler \(pid)"
        teamId = J.str(e["tid"]) ?? ""
        self.date = date
        price = J.dbl(e["trp"]) ?? 0
        isBuy = tty == 1
    }
}

/// A league transfer. `buyerId`/`sellerId` nil means Kickbase.
struct Transfer: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let playerId: String
    let playerName: String
    let teamId: String
    let price: Double
    let buyerId: String?
    let sellerId: String?

    func involves(_ managerId: String) -> Bool {
        buyerId == managerId || sellerId == managerId
    }

    /// Joins the per-manager lists: a buy by A and a sale by B of the same player
    /// at (almost) the same time and price becomes one transfer B → A.
    static func merge(_ entries: [ManagerTransferEntry]) -> [Transfer] {
        let buys = entries.filter { $0.isBuy }
        var sales = entries.filter { !$0.isBuy }
        var result: [Transfer] = []

        for b in buys {
            var sellerId: String? = nil
            if let idx = sales.firstIndex(where: { s in
                s.playerId == b.playerId && s.userId != b.userId
                    && abs(s.date.timeIntervalSince(b.date)) <= 300
                    && abs(s.price - b.price) <= 1
            }) {
                sellerId = sales[idx].userId
                sales.remove(at: idx)
            }
            result.append(Transfer(entry: b, buyerId: b.userId, sellerId: sellerId))
        }
        for s in sales {
            result.append(Transfer(entry: s, buyerId: nil, sellerId: s.userId))
        }
        return result.sorted { $0.date > $1.date }
    }

    private init(entry e: ManagerTransferEntry, buyerId: String?, sellerId: String?) {
        let ts = Int(e.date.timeIntervalSince1970)
        id = "\(e.playerId)-\(ts)-\(buyerId ?? "kb")-\(sellerId ?? "kb")"
        date = e.date
        playerId = e.playerId
        playerName = e.playerName
        teamId = e.teamId
        price = e.price
        self.buyerId = buyerId
        self.sellerId = sellerId
    }
}

enum TransferPeriod: String, CaseIterable, Identifiable {
    case day = "24 h"
    case week = "7 Tage"
    case all = "Alles"

    var id: String { rawValue }

    var cutoff: Date? {
        switch self {
        case .day: return Date().addingTimeInterval(-86_400)
        case .week: return Date().addingTimeInterval(-7 * 86_400)
        case .all: return nil
        }
    }

    func contains(_ date: Date) -> Bool {
        guard let cutoff else { return true }
        return date >= cutoff
    }
}

/// Transfer key figures of one manager.
struct ManagerTransferStats: Identifiable {
    let id: String
    let name: String
    let isMe: Bool
    let buys: Int
    let sales: Int
    let spent: Double
    let earned: Double
    /// Average of (price / current market value − 1) over buys, in percent.
    let avgOverpay: Double?
    let recentBuys: [Transfer]
    let count24h: Int
    let spent24h: Double

    var balance: Double { earned - spent }
    var transferCount: Int { buys + sales }
    var overpaySortKey: Double { avgOverpay ?? -Double.greatestFiniteMagnitude }

    /// "Particularly active": at least 3 transfers or 20 Mio. € spent in 24 h.
    var isHot: Bool { count24h >= 3 || spent24h >= 20_000_000 }

    /// - Parameters:
    ///   - transfers: transfers in the selected period (any manager).
    ///   - all: every loaded transfer, used for the 24 h activity hint.
    init(
        manager: Manager,
        isMe: Bool,
        transfers: [Transfer],
        all: [Transfer],
        marketValue: (String) -> Double?
    ) {
        id = manager.id
        name = manager.name
        self.isMe = isMe
        let bought = transfers.filter { $0.buyerId == manager.id }
        let sold = transfers.filter { $0.sellerId == manager.id }
        buys = bought.count
        sales = sold.count
        spent = bought.reduce(0.0) { $0 + $1.price }
        earned = sold.reduce(0.0) { $0 + $1.price }

        let ratios: [Double] = bought.compactMap { t in
            guard let mv = marketValue(t.playerId), mv > 0 else { return nil }
            return (t.price / mv - 1) * 100
        }
        avgOverpay = ratios.isEmpty ? nil : ratios.reduce(0, +) / Double(ratios.count)
        recentBuys = Array(bought.sorted { $0.date > $1.date }.prefix(5))

        let dayAgo = Date().addingTimeInterval(-86_400)
        let recent = all.filter { $0.date >= dayAgo && $0.involves(manager.id) }
        count24h = recent.count
        spent24h = recent.filter { $0.buyerId == manager.id }.reduce(0.0) { $0 + $1.price }
    }
}
