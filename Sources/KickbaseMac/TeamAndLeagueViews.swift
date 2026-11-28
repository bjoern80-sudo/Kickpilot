import Charts
import SwiftUI

struct TeamView: View {
    @EnvironmentObject var state: AppState
    @State private var sortOrder = [KeyPathComparator(\Player.marketValue, order: .reverse)]
    @State private var detailPlayer: Player? = nil

    private var teamValue: Double { state.squad.reduce(0.0) { $0 + $1.marketValue } }
    private var trend: Double { state.squad.reduce(0.0) { $0 + $1.trend24h } }
    private var points: Double { state.squad.reduce(0.0) { $0 + $1.totalPoints } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatCard(title: "Budget", value: Fmt.eur(state.budget),
                         color: state.budget < 0 ? .red : nil)
                StatCard(title: "Teamwert", value: Fmt.eur(teamValue))
                StatCard(title: "Marktwert 24h", value: Fmt.signedEur(trend),
                         color: trend > 0 ? .green : (trend < 0 ? .red : nil))
                StatCard(title: "Punkte (Kader)", value: Fmt.int(points))
                StatCard(title: "Spieler", value: "\(state.squad.count)")
            }
            if let check = state.lineupCheck { LineupBanner(check: check) }
            PlayerTable(players: state.squad, sortOrder: $sortOrder) { detailPlayer = $0 }
        }
        .padding()
        .sheet(item: $detailPlayer) { p in
            PlayerDetailView(player: p).environmentObject(state)
        }
    }
}

/// Lineup guard: hints only – the lineup has to be changed in the Kickbase app.
struct LineupBanner: View {
    let check: LineupCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if check.nextKickoff == nil {
                    Label("Spieltag \(check.matchday ?? 0) läuft – alle Spiele angepfiffen", systemImage: "lock.fill")
                        .foregroundColor(.secondary)
                } else if check.problems.isEmpty {
                    Label("Aufstellung ok", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Label("Aufstellung prüfen", systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
                }
                if let next = check.nextKickoff {
                    Text("· Spieltag \(check.matchday ?? 0), nächster Anpfiff \(Fmt.kickoff(next))")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(check.starters) / \(LineupRules.startingSize) in der Startelf")
                    .font(.caption).foregroundColor(.secondary)
            }
            .font(.callout.weight(.semibold))
            ForEach(check.issues) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: i.isProblem ? "exclamationmark.circle.fill" : "arrow.left.arrow.right")
                        .foregroundColor(i.isProblem ? .red : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.isProblem ? i.text : "Tipp: \(i.text)")
                        Text(detail(i)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if !check.problems.isEmpty {
                Text("Aufstellung bitte in der Kickbase-App ändern – Kickpilot ändert sie nie selbst.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            (check.problems.isEmpty ? Color.green : Color.red).opacity(check.nextKickoff == nil ? 0.04 : 0.08)
        ))
    }

    private func detail(_ i: LineupIssue) -> String {
        var parts: [String] = []
        switch i.kind {
        case .incomplete: break
        case .tip: parts.append("Stärker auf der Bank")
        default:
            parts.append(i.replacement.map { "Ersatz: \($0.fullName) (Ø \(Int($0.averagePoints.rounded())))" }
                ?? "Kein fitter Ersatz auf dieser Position")
        }
        if let d = i.deadline { parts.append("bis \(Fmt.kickoff(d))") }
        return parts.joined(separator: " · ")
    }
}

struct LeagueView: View {
    @EnvironmentObject var state: AppState
    var onSelectManager: (String) -> Void
    @State private var selection: Manager.ID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Doppelklick auf einen Manager öffnet die Kader-Analyse.")
                .font(.caption)
                .foregroundColor(.secondary)
            Table(state.managers, selection: $selection) {
                TableColumn("Platz") { m in Text("\(m.placement)").monospacedDigit() }
                    .width(50)
                TableColumn("Manager") { m in
                    Text(m.id == state.myUserId ? "\(m.name) (du)" : m.name)
                        .fontWeight(m.id == state.myUserId ? .bold : .regular)
                }
                TableColumn("Punkte") { m in Text(Fmt.int(m.seasonPoints)).monospacedDigit() }
                TableColumn("Letzter Spieltag") { m in Text(Fmt.int(m.matchDayPoints)).monospacedDigit() }
                TableColumn("Teamwert") { m in Text(Fmt.eur(m.teamValue)).monospacedDigit() }
            }
            .contextMenu(forSelectionType: Manager.ID.self) { ids in
                if let id = ids.first {
                    Button("Kader analysieren") { onSelectManager(id) }
                }
            } primaryAction: { ids in
                if let id = ids.first { onSelectManager(id) }
            }
        }
        .padding()
    }
}

struct PlayerDetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let player: Player
    @State private var history: [MVPoint] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.fullName).font(.title2.bold())
                    Text("\(player.positionName) · \(state.teamName(player.teamId)) · \(player.statusText)")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Schließen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                StatCard(title: "Marktwert", value: Fmt.eur(player.marketValue))
                StatCard(title: "24h", value: Fmt.signedEur(player.trend24h),
                         color: player.trend24h > 0 ? .green : (player.trend24h < 0 ? .red : nil))
                StatCard(title: "Punkte", value: Fmt.int(player.totalPoints))
                StatCard(title: "Ø Punkte", value: Fmt.int(player.averagePoints))
            }

            Text("Marktwert der letzten 12 Monate").font(.headline)
            Group {
                if loading {
                    ProgressView()
                } else if history.isEmpty {
                    Text("Keine Daten verfügbar").foregroundColor(.secondary)
                } else {
                    Chart(history) { point in
                        LineMark(
                            x: .value("Datum", point.date),
                            y: .value("Mio. €", point.value / 1_000_000)
                        )
                        .interpolationMethod(.monotone)
                    }
                    .chartYAxisLabel("Mio. €")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
        }
        .padding(24)
        .frame(width: 640)
        .task {
            history = await state.marketValueHistory(for: player)
            loading = false
        }
    }
}
