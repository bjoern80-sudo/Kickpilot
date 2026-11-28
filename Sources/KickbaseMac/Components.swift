import SwiftUI

enum Fmt {
    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let twoDigits: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func int(_ v: Double) -> String {
        whole.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }

    static func eur(_ v: Double) -> String { int(v) + " €" }

    static func signedEur(_ v: Double) -> String { (v > 0 ? "+" : "") + eur(v) }

    static func mio(_ v: Double) -> String {
        (twoDigits.string(from: NSNumber(value: v / 1_000_000)) ?? "") + " Mio. €"
    }

    static func dec(_ v: Double) -> String {
        twoDigits.string(from: NSNumber(value: v)) ?? String(v)
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM. HH:mm"
        return f
    }()

    private static let oneDigit: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    /// "26.11. 17:16"
    static func shortDateTime(_ d: Date) -> String { dateTime.string(from: d) + " Uhr" }

    /// "112,4 %" or with sign "+12,4 %"
    static func pct(_ v: Double, signed: Bool = false) -> String {
        let s = oneDigit.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v)
        return (signed && v > 0 ? "+" : "") + s + " %"
    }

    /// "Sa 15:30 Uhr" in German time (kick-off within the current week).
    static func kickoff(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "EE HH:mm 'Uhr'"
        return f.string(from: d).replacingOccurrences(of: ".", with: "")
    }

    /// "Fr 28.11. 20:30 Uhr" in German time.
    static func deadline(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "EE dd.MM. HH:mm"
        return f.string(from: d) + " Uhr"
    }

    static func remaining(_ date: Date?) -> String {
        guard let date else { return "–" }
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "abgelaufen" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

/// KPI tile: label with icon, big rounded number.
struct StatCard: View {
    let title: String
    let value: String
    var color: Color? = nil
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.caption).foregroundColor(.secondary)
                }
                Text(title).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Text(value)
                .font(Theme.number(20))
                .foregroundColor(color ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

struct TrendText: View {
    let value: Double

    var body: some View {
        Text(Fmt.signedEur(value))
            .monospacedDigit()
            .foregroundColor(Theme.signColor(value))
    }
}

struct PlayerNameCell: View {
    let player: Player

    var body: some View {
        HStack(spacing: 6) {
            Text(player.fullName)
            if !player.isFit {
                Badge(text: player.statusShort, color: .loss, help: player.statusText)
            }
            if player.onMarket {
                Image(systemName: "tag.fill").foregroundColor(.warn)
                    .help("Auf dem Transfermarkt")
                    .accessibilityLabel("Auf dem Transfermarkt")
            }
        }
    }
}

/// Squad table used for your own team and other managers' squads.
struct PlayerTable: View {
    @EnvironmentObject var state: AppState
    let players: [Player]
    @Binding var sortOrder: [KeyPathComparator<Player>]
    var onOpen: (Player) -> Void
    @State private var selection: Player.ID? = nil

    var body: some View {
        Table(players.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.lastName) { p in PlayerNameCell(player: p) }
                .width(min: 140, ideal: 200)
            TableColumn("Pos.", value: \.position) { p in PositionChip(position: p.position) }
                .width(44)
            TableColumn("Verein", value: \.teamId) { p in ClubCell(name: state.teamName(p.teamId)) }
                .width(min: 90, ideal: 120)
            TableColumn("Marktwert", value: \.marketValue) { p in
                Text(Fmt.eur(p.marketValue)).monospacedDigit()
            }
            .width(min: 90, ideal: 110)
            TableColumn("24 h", value: \.trend24h) { p in TrendText(value: p.trend24h) }
                .width(min: 80, ideal: 95)
            TableColumn("Punkte", value: \.totalPoints) { p in
                Text(Fmt.int(p.totalPoints)).monospacedDigit()
            }
            .width(min: 45, ideal: 60)
            TableColumn("Ø", value: \.averagePoints) { p in
                Text(Fmt.int(p.averagePoints)).monospacedDigit()
            }
            .width(min: 35, ideal: 50)
        }
        .contextMenu(forSelectionType: Player.ID.self) { ids in
            if let p = player(for: ids) {
                Button("Details anzeigen") { onOpen(p) }
            }
        } primaryAction: { ids in
            if let p = player(for: ids) { onOpen(p) }
        }
    }

    private func player(for ids: Set<Player.ID>) -> Player? {
        guard let id = ids.first else { return nil }
        return players.first { $0.id == id }
    }
}

struct InsightBox: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if lines.isEmpty {
                Text("–").foregroundColor(.secondary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.callout).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface(padding: 12)
    }
}

/// Remaining time; under 6 h with a clock icon (not only color).
struct ExpiryText: View {
    let date: Date?
    let soon: Bool

    var body: some View {
        HStack(spacing: 3) {
            if soon { Image(systemName: "clock.badge.exclamationmark") }
            Text(Fmt.remaining(date)).monospacedDigit()
        }
        .foregroundColor(soon ? .warn : .primary)
        .accessibilityLabel(soon ? "Läuft bald ab: \(Fmt.remaining(date))" : Fmt.remaining(date))
    }
}
