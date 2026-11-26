import Foundation

typealias JSONObject = [String: Any]

/// Helpers for Kickbase's loosely typed JSON with cryptic short keys.
enum J {
    static func obj(_ v: Any?) -> JSONObject? { v as? JSONObject }

    static func arr(_ v: Any?) -> [JSONObject] {
        guard let a = v as? [Any] else { return [] }
        return a.compactMap { $0 as? JSONObject }
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func dbl(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func int(_ v: Any?) -> Int? {
        guard let d = dbl(v) else { return nil }
        return Int(d)
    }

    static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }
}

// MARK: - Player

struct Player: Identifiable, Hashable, Sendable {
    let id: String
    let firstName: String
    let lastName: String
    let teamId: String
    let position: Int
    let status: Int
    let marketValue: Double
    let trend24h: Double
    let totalPoints: Double
    let averagePoints: Double
    let price: Double
    let expiresAt: Date?
    let offerCount: Int
    let sellerUserId: String?
    let onMarket: Bool
    /// My own open bid on this market player (`uop`), if any.
    let myOfferPrice: Double?
    /// Squad only: market value gain since purchase (`mvgl`).
    let gainSincePurchase: Double?

    init(json p: JSONObject, fetchedAt: Date = Date()) {
        // Other managers' squads (/managers/{uid}/squad) use `pi`/`pn` instead of `i`/`n`.
        id = J.str(p["i"]) ?? J.str(p["pi"]) ?? UUID().uuidString
        firstName = (J.str(p["fn"]) ?? "").trimmingCharacters(in: .whitespaces)
        // Player details (/players/{id}) use `ln` and `tp` instead of `n` and `p`.
        lastName = (J.str(p["n"]) ?? J.str(p["ln"]) ?? J.str(p["pn"]) ?? "").trimmingCharacters(in: .whitespaces)
        teamId = J.str(p["tid"]) ?? ""
        position = J.int(p["pos"]) ?? 0
        status = J.int(p["st"]) ?? 0
        marketValue = J.dbl(p["mv"]) ?? 0
        trend24h = J.dbl(p["tfhmvt"]) ?? 0
        totalPoints = J.dbl(p["p"]) ?? J.dbl(p["tp"]) ?? 0
        averagePoints = J.dbl(p["ap"]) ?? 0
        price = J.dbl(p["prc"]) ?? 0
        // exs is either seconds until expiry or an epoch timestamp
        if let exs = J.dbl(p["exs"]), exs > 0 {
            expiresAt = exs > 1_000_000
                ? Date(timeIntervalSince1970: exs)
                : fetchedAt.addingTimeInterval(exs)
        } else {
            expiresAt = nil
        }
        offerCount = J.int(p["ofc"]) ?? 0
        // Market: the listing manager is in `u.i` (no `u` = Kickbase listing).
        // `uoid`/`uop` on a market item are the user id/price of MY bid, not the seller.
        let seller = J.str(J.obj(p["u"])?["i"])
        if let seller, !seller.isEmpty, seller != "0" {
            sellerUserId = seller
        } else {
            sellerUserId = nil
        }
        onMarket = J.bool(p["iotm"])
        myOfferPrice = J.dbl(p["uop"]).flatMap { $0 > 0 ? $0 : nil }
        gainSincePurchase = J.dbl(p["mvgl"])
    }

    var fullName: String {
        firstName.isEmpty ? lastName : "\(firstName) \(lastName)"
    }

    var positionName: String {
        switch position {
        case 1: return "TW"
        case 2: return "ABW"
        case 3: return "MIT"
        case 4: return "ST"
        default: return "?"
        }
    }

    var isFit: Bool { status == 0 }

    var statusText: String {
        switch status {
        case 0: return "fit"
        case 1: return "verletzt"
        case 2: return "angeschlagen"
        case 4: return "Aufbautraining"
        case 8: return "Rot-Sperre"
        case 16: return "Gelb-Rot-Sperre"
        case 32: return "Gelb-Sperre"
        case 64: return "nicht im Kader"
        case 128: return "nicht in Liga"
        case 256: return "abwesend"
        default: return "Status \(status)"
        }
    }

    /// Listing price if set, otherwise market value.
    var effectivePrice: Double { price > 0 ? price : marketValue }

    var pointsPerMillion: Double {
        let p = effectivePrice
        return p > 0 ? averagePoints / (p / 1_000_000) : 0
    }

    var expiresIn: Double {
        guard let expiresAt else { return Double.greatestFiniteMagnitude }
        return expiresAt.timeIntervalSinceNow
    }

    var sellerSortKey: String { sellerUserId ?? "" }
}

// MARK: - League, manager, team, offer

struct League: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let competitionId: String

    init(json j: JSONObject) {
        id = J.str(j["i"]) ?? ""
        name = J.str(j["n"]) ?? "Liga"
        competitionId = J.str(j["cpi"]) ?? "1"
    }
}

struct Manager: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let placement: Int
    let seasonPoints: Double
    let matchDayPoints: Double
    let teamValue: Double

    init(json u: JSONObject) {
        id = J.str(u["i"]) ?? ""
        name = J.str(u["n"]) ?? "?"
        placement = J.int(u["spl"]) ?? 999
        seasonPoints = J.dbl(u["sp"]) ?? 0
        matchDayPoints = J.dbl(u["mdp"]) ?? 0
        teamValue = J.dbl(u["tv"]) ?? 0
    }
}

struct Team: Hashable, Sendable {
    let id: String
    let name: String
    let placement: Int
}

struct Offer: Identifiable, Hashable, Sendable {
    let id: String
    let price: Double
    let userId: String
    let userName: String
    let date: String

    init(json o: JSONObject) {
        id = J.str(o["i"]) ?? UUID().uuidString
        price = J.dbl(o["prc"]) ?? 0
        userId = J.str(o["uoid"]) ?? ""
        userName = J.str(o["unm"]) ?? ""
        date = J.str(o["dt"]) ?? ""
    }
}

struct MVPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Aggregated key figures of one manager's squad.
struct ManagerSummary: Identifiable {
    let id: String
    let name: String
    let isMe: Bool
    let squadValue: Double
    let count: Int
    let avgPoints: Double
    let totalPoints: Double
    let trend24h: Double
    let unavailable: Int
    let onMarket: Int
    let positions: String

    init(manager m: Manager, squad: [Player], isMe: Bool) {
        id = m.id
        name = m.name
        self.isMe = isMe
        squadValue = squad.reduce(0.0) { $0 + $1.marketValue }
        count = squad.count
        avgPoints = squad.isEmpty ? 0 : squad.reduce(0.0) { $0 + $1.averagePoints } / Double(squad.count)
        totalPoints = squad.reduce(0.0) { $0 + $1.totalPoints }
        trend24h = squad.reduce(0.0) { $0 + $1.trend24h }
        unavailable = squad.filter { !$0.isFit }.count
        onMarket = squad.filter { $0.onMarket }.count
        positions = (1...4)
            .map { pos in String(squad.filter { $0.position == pos }.count) }
            .joined(separator: "-")
    }
}
