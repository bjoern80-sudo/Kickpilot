import Foundation

// Lineup guard: checks the starting eleven before kick-off (read-only, never changes the lineup).
// 1:1 port in `custom_components/kickbase/lineup.py` – change rules in BOTH files.
//
// Kickbase locks each player individually when his club's match starts, so only players
// whose match has not started yet are checked. Problems: starting eleven incomplete,
// starter not fit, starter's club has no match. Tips: a fit bench player of the same
// position averages clearly more points.

enum LineupRules {
    static let startingSize = 11
    /// Bench player must average at least this many points more than the starter (tip).
    static let tipMinAvgGain = 20.0
    /// Warn (sidebar badge) this many hours before the affected kick-off.
    static let leadHours = 2.0
}

struct Match: Hashable, Sendable {
    let id: String
    let matchday: Int
    let kickoff: Date
    let homeId: String
    let awayId: String
    /// 0 not started, 2 finished (1 presumably live).
    let status: Int
    var started: Bool { status != 0 }
}

struct Matchday: Hashable, Sendable {
    let day: Int
    let matches: [Match]

    func match(of teamId: String) -> Match? {
        matches.first { $0.homeId == teamId || $0.awayId == teamId }
    }

    /// First matchday (by number) that still has a match that is not finished.
    static func current(_ days: [Matchday]) -> Matchday? {
        days.sorted { $0.day < $1.day }.first { $0.matches.contains { $0.status != 2 } }
    }
}

struct LineupIssue: Identifiable, Hashable {
    enum Kind: String { case incomplete = "unvollstaendig", notFit = "nicht_fit", noMatch = "kein_spiel", tip = "tipp" }
    let kind: Kind
    let text: String
    var player: Player? = nil
    var replacement: Player? = nil
    /// Last moment the issue can be fixed (kick-off of the player's match, or the next one).
    var deadline: Date? = nil

    var isProblem: Bool { kind != .tip }
    var id: String { "\(kind.rawValue):\(player?.id ?? ""):\(deadline?.timeIntervalSince1970 ?? 0)" }
}

struct LineupCheck {
    var matchday: Int?
    var nextKickoff: Date?
    var starters = 0
    /// Starters whose match has not started yet.
    var openPlayers = 0
    var issues: [LineupIssue] = []

    var problems: [LineupIssue] { issues.filter(\.isProblem) }
    var tips: [LineupIssue] { issues.filter { !$0.isProblem } }

    /// Issues whose deadline is within `leadHours` (and not yet passed).
    func due(now: Date = Date(), leadHours: Double = LineupRules.leadHours) -> [LineupIssue] {
        issues.filter { i in
            guard let d = i.deadline else { return false }
            return d > now && d <= now.addingTimeInterval(leadHours * 3600)
        }
    }

    static func check(squad: [Player], matchday: Matchday?, now: Date = Date()) -> LineupCheck {
        var result = LineupCheck()
        guard let matchday else { return result }
        result.matchday = matchday.day
        result.nextKickoff = matchday.matches.filter { !$0.started && $0.kickoff > now }.map(\.kickoff).min()

        func isOpen(_ p: Player) -> Bool {
            guard let m = matchday.match(of: p.teamId) else { return false }
            return !m.started && m.kickoff > now
        }

        let starters = squad.filter { $0.lineupSlot != nil }
        let bench = squad.filter { $0.lineupSlot == nil }
        result.starters = starters.count
        result.openPlayers = starters.filter(isOpen).count
        guard result.nextKickoff != nil else { return result } // everything has started

        var used = Set<String>()
        func bestBench(_ position: Int, betterThan: Double? = nil) -> Player? {
            let best = bench
                .filter { b in
                    b.position == position && b.isFit && isOpen(b) && !used.contains(b.id)
                        && (betterThan.map { b.averagePoints >= $0 } ?? true)
                }
                .max { $0.averagePoints < $1.averagePoints }
            if let best { used.insert(best.id) }
            return best
        }
        func name(_ p: Player) -> String { "\(p.fullName) (\(p.positionName))" }

        if starters.count < LineupRules.startingSize {
            result.issues.append(.init(
                kind: .incomplete,
                text: "Startelf unvollständig: \(starters.count) von \(LineupRules.startingSize) Plätzen besetzt",
                deadline: result.nextKickoff
            ))
        }

        // Weakest first, so the best replacement goes to the most urgent slot.
        let byAvg = starters.sorted { $0.averagePoints < $1.averagePoints }
        for p in byAvg {
            guard let m = matchday.match(of: p.teamId) else {
                result.issues.append(.init(
                    kind: .noMatch, text: "\(name(p)): Verein hat an diesem Spieltag kein Spiel",
                    player: p, replacement: bestBench(p.position), deadline: result.nextKickoff
                ))
                continue
            }
            guard isOpen(p) else { continue } // match already started – locked
            if !p.isFit {
                result.issues.append(.init(
                    kind: .notFit, text: "\(name(p)) ist \(p.statusText)",
                    player: p, replacement: bestBench(p.position), deadline: m.kickoff
                ))
            }
        }

        for p in byAvg where isOpen(p) && p.isFit {
            guard let sub = bestBench(p.position, betterThan: p.averagePoints + LineupRules.tipMinAvgGain),
                  let pm = matchday.match(of: p.teamId), let sm = matchday.match(of: sub.teamId)
            else { continue }
            result.issues.append(.init(
                kind: .tip,
                text: "\(sub.fullName) (Ø \(Int(sub.averagePoints.rounded()))) statt \(p.fullName) (Ø \(Int(p.averagePoints.rounded())))",
                player: p, replacement: sub, deadline: min(pm.kickoff, sm.kickoff)
            ))
        }
        return result
    }
}
