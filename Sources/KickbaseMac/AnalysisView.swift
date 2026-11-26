import SwiftUI

/// Compare all managers' squads and inspect one squad in detail.
struct AnalysisView: View {
    @EnvironmentObject var state: AppState
    @Binding var selectedManagerId: String?
    @State private var loadingAll = false
    @State private var sortOrder = [KeyPathComparator(\Player.marketValue, order: .reverse)]
    @State private var detailPlayer: Player? = nil

    private var summaries: [ManagerSummary] {
        state.managers.compactMap { m in
            guard let squad = state.managerSquads[m.id] else { return nil }
            return ManagerSummary(manager: m, squad: squad, isMe: m.id == state.myUserId)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kader-Vergleich").font(.headline)
                Spacer()
                if loadingAll { ProgressView().controlSize(.small) }
                Button {
                    Task {
                        loadingAll = true
                        await state.loadAllManagerSquads()
                        loadingAll = false
                    }
                } label: {
                    Label("Alle Kader laden", systemImage: "arrow.down.circle")
                }
                .disabled(loadingAll)
            }

            if summaries.isEmpty {
                Text("Lade alle Kader, um die Teams der Liga zu vergleichen – oder wähle unten einen Manager.")
                    .foregroundColor(.secondary)
            } else {
                Table(summaries) {
                    TableColumn("Manager") { s in
                        Text(s.isMe ? "\(s.name) (du)" : s.name)
                            .fontWeight(s.isMe ? .bold : .regular)
                    }
                    TableColumn("Kaderwert") { s in Text(Fmt.eur(s.squadValue)).monospacedDigit() }
                    TableColumn("Spieler") { s in Text("\(s.count)") }
                        .width(55)
                    TableColumn("Ø Pkt./Spieler") { s in Text(Fmt.int(s.avgPoints)).monospacedDigit() }
                    TableColumn("Punkte Kader") { s in Text(Fmt.int(s.totalPoints)).monospacedDigit() }
                    TableColumn("24h") { s in TrendText(value: s.trend24h) }
                    TableColumn("Ausfälle") { s in
                        Text("\(s.unavailable)").foregroundColor(s.unavailable > 0 ? .red : .primary)
                    }
                    .width(60)
                    TableColumn("Auf Markt") { s in Text("\(s.onMarket)") }
                        .width(65)
                    TableColumn("TW-ABW-MIT-ST") { s in Text(s.positions).monospacedDigit() }
                }
                .frame(height: min(CGFloat(summaries.count) * 26 + 34, 280))
            }

            Divider()

            Picker("Kader von", selection: $selectedManagerId) {
                Text("Manager wählen …").tag(String?.none)
                ForEach(state.managers) { m in
                    Text(m.id == state.myUserId ? "\(m.name) (du)" : m.name).tag(Optional(m.id))
                }
            }
            .frame(width: 340)

            if let id = selectedManagerId {
                if let squad = state.managerSquads[id] {
                    ManagerInsights(squad: squad)
                    PlayerTable(players: squad, sortOrder: $sortOrder) { detailPlayer = $0 }
                } else {
                    ProgressView("Lade Kader …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Spacer()
            }
        }
        .padding()
        .task(id: selectedManagerId) {
            if let id = selectedManagerId, state.managerSquads[id] == nil {
                await state.loadManagerSquad(id)
            }
        }
        .sheet(item: $detailPlayer) { p in
            PlayerDetailView(player: p).environmentObject(state)
        }
    }
}

struct ManagerInsights: View {
    let squad: [Player]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            InsightBox(
                title: "Wertvollste Spieler",
                lines: top(\.marketValue).map { "\($0.fullName) – \(Fmt.mio($0.marketValue))" }
            )
            InsightBox(
                title: "Beste Ø-Punkte",
                lines: top(\.averagePoints).map { "\($0.fullName) – \(Fmt.int($0.averagePoints))" }
            )
            InsightBox(
                title: "Größte Verlierer (24h)",
                lines: squad.filter { $0.trend24h < 0 }
                    .sorted { $0.trend24h < $1.trend24h }
                    .prefix(3)
                    .map { "\($0.fullName) \(Fmt.signedEur($0.trend24h))" }
            )
            InsightBox(
                title: "Ausfälle / auf dem Markt",
                lines: squad.filter { !$0.isFit || $0.onMarket }
                    .map { "\($0.fullName) – \($0.onMarket ? "auf dem Markt" : $0.statusText)" }
            )
        }
    }

    private func top(_ key: KeyPath<Player, Double>) -> [Player] {
        Array(squad.sorted { $0[keyPath: key] > $1[keyPath: key] }.prefix(3))
    }
}
