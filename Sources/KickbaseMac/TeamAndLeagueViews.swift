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
            PlayerTable(players: state.squad, sortOrder: $sortOrder) { detailPlayer = $0 }
        }
        .padding()
        .sheet(item: $detailPlayer) { p in
            PlayerDetailView(player: p).environmentObject(state)
        }
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
