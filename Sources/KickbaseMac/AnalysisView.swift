import SwiftUI

/// Compare all managers' squads and inspect one squad in detail.
struct AnalysisView: View {
    @EnvironmentObject var state: AppState
    @Binding var selectedManagerId: String?
    @State private var loadingAll = false
    @State private var sortOrder = [KeyPathComparator(\Player.marketValue, order: .reverse)]
    @State private var detailPlayer: Player? = nil

    private var transferStats: [String: ManagerTransferStats] {
        guard state.transfersLoadedAt != nil else { return [:] }
        return Dictionary(uniqueKeysWithValues: state.transferStats(period: .all).map { ($0.id, $0) })
    }

    private var summaries: [ManagerSummary] {
        state.managers.compactMap { m in
            guard let squad = state.managerSquads[m.id] else { return nil }
            return ManagerSummary(manager: m, squad: squad, isMe: m.id == state.myUserId)
        }
    }

    var body: some View {
        Page(title: "Kader-Analyse", subtitle: "Kader der Liga vergleichen und einzeln ansehen", scrolls: true) {
            Card(title: "Kader-Vergleich", padding: 14) {
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
            } content: {
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
                        Text("\(s.unavailable)").foregroundColor(s.unavailable > 0 ? .loss : .primary)
                    }
                    .width(60)
                    TableColumn("Auf Markt") { s in Text("\(s.onMarket)") }
                        .width(65)
                    TableColumn("TW-ABW-MIT-ST") { s in Text(s.positions).monospacedDigit() }
                    TableColumn("Transfersaldo") { s in
                        if let t = transferStats[s.id] {
                            HStack(spacing: 4) {
                                TrendText(value: t.balance)
                                if t.isHot {
                                    Image(systemName: "flame.fill").foregroundColor(.warn)
                                        .help("In den letzten 24 h besonders aktiv")
                                        .accessibilityLabel("In den letzten 24 h besonders aktiv")
                                }
                            }
                        } else {
                            Text("–").foregroundColor(.secondary)
                        }
                    }
                }
                .fittedTableHeight(rows: summaries.count, max: 280)
                .scrollContentBackground(.hidden)
            }
            }

            Picker("Kader von", selection: $selectedManagerId) {
                Text("Manager wählen …").tag(String?.none)
                ForEach(state.managers) { m in
                    Text(m.id == state.myUserId ? "\(m.name) (du)" : m.name).tag(Optional(m.id))
                }
            }
            .frame(width: 340)

            if let id = selectedManagerId {
                if let squad = state.managerSquads[id] {
                    transferSection(for: id)
                    ManagerInsights(squad: squad)
                    Card(title: "Kader", detail: "\(squad.count) Spieler", padding: 0) {
                        PlayerTable(players: squad, sortOrder: $sortOrder) { detailPlayer = $0 }
                            .fittedTableHeight(rows: squad.count)
                            .scrollContentBackground(.hidden)
                    }
                } else {
                    ProgressView("Lade Kader …")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
        }
        .task(id: selectedManagerId) {
            if selectedManagerId != nil, state.transfersLoadedAt == nil {
                await state.loadTransfers()
            }
            if let id = selectedManagerId, state.managerSquads[id] == nil {
                await state.loadManagerSquad(id)
            }
        }
        .sheet(item: $detailPlayer) { p in
            PlayerDetailView(player: p).environmentObject(state)
        }
    }
}

extension AnalysisView {
    @ViewBuilder
    fileprivate func transferSection(for id: String) -> some View {
        if let stats = transferStats[id] {
            ManagerTransferPanel(stats: stats, periodLabel: transferPeriodLabel)
                .task(id: id) {
                    await state.loadPlayerInfo(
                        for: state.transfers.filter { $0.buyerId == id }.map(\.playerId)
                    )
                }
        } else if state.transfersLoading {
            ProgressView("Lade Transfers …").controlSize(.small)
        }
    }

    private var transferPeriodLabel: String {
        guard let d = state.transfersOldest else { return "geladener Zeitraum" }
        return "seit \(d.formatted(.dateTime.day().month().year()))"
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
