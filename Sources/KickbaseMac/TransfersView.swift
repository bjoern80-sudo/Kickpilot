import SwiftUI

/// Table row: a transfer plus resolved names and the current market value.
struct TransferRow: Identifiable {
    let transfer: Transfer
    let buyer: String
    let seller: String
    let team: String
    let marketValue: Double?

    var id: String { transfer.id }
    var date: Date { transfer.date }
    var playerName: String { transfer.playerName }
    var price: Double { transfer.price }
    var marketValueSortKey: Double { marketValue ?? 0 }
    /// Price as percent of the current market value.
    var ratio: Double? {
        guard let mv = marketValue, mv > 0 else { return nil }
        return transfer.price / mv * 100
    }
    var ratioSortKey: Double { ratio ?? -Double.greatestFiniteMagnitude }
}

/// "Mitspieler beobachten": all league transfers with filters and per-manager figures.
struct TransfersView: View {
    @EnvironmentObject var state: AppState
    @State private var managerFilter: String? = nil
    @State private var period: TransferPeriod = .week
    @State private var sortOrder = [KeyPathComparator(\TransferRow.date, order: .reverse)]
    @State private var selection: TransferRow.ID? = nil
    @State private var statsSelection: ManagerTransferStats.ID? = nil
    @State private var detailPlayer: Player? = nil

    private var filteredTransfers: [Transfer] {
        state.transfers.filter { t in
            period.contains(t.date) && (managerFilter.map { t.involves($0) } ?? true)
        }
    }

    private var rows: [TransferRow] {
        filteredTransfers.map { t in
            TransferRow(
                transfer: t,
                buyer: state.partyName(t.buyerId),
                seller: state.partyName(t.sellerId),
                team: state.teamName(t.teamId),
                marketValue: state.currentMarketValue(t.playerId)
            )
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        let stats = state.transferStats(period: period)
        Page(title: "Transfers", subtitle: "Alle Transfers der Liga – \(periodLabel)") {
            filterBar

            ActivityHints(stats: stats)

            if state.transfers.isEmpty {
                if state.transfersLoading {
                    ProgressView("Lade Transfers …").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Keine Transfers geladen.").foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                if let id = managerFilter, let s = stats.first(where: { $0.id == id }) {
                    ManagerTransferPanel(stats: s, periodLabel: periodLabel)
                } else {
                    Card(title: "Manager", detail: "Doppelklick filtert die Transfers", padding: 0) {
                        statsTable(stats).scrollContentBackground(.hidden)
                    }
                }
                Card(title: "Transfers", padding: 0) {
                    transferTable.scrollContentBackground(.hidden)
                }
            }
        }
        .task(id: state.currentLeague?.id) {
            if state.transfersLoadedAt == nil { await state.loadTransfers() }
        }
        .task(id: filteredTransfers.map(\.playerId)) {
            await state.loadPlayerInfo(for: filteredTransfers.map(\.playerId))
        }
        .sheet(item: $detailPlayer) { p in
            PlayerDetailView(player: p).environmentObject(state)
        }
    }

    private var periodLabel: String {
        switch period {
        case .day: return "letzte 24 h"
        case .week: return "letzte 7 Tage"
        case .all:
            if let d = state.transfersOldest {
                return "seit \(d.formatted(.dateTime.day().month().year()))"
            }
            return "alle geladenen"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 16) {
            Picker("Manager", selection: $managerFilter) {
                Text("Alle Manager").tag(String?.none)
                ForEach(state.managers) { m in
                    Text(m.id == state.myUserId ? "\(m.name) (du)" : m.name).tag(Optional(m.id))
                }
            }
            .frame(width: 260)
            Picker("Zeitraum", selection: $period) {
                ForEach(TransferPeriod.allCases) { p in Text(p.rawValue).tag(p) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            Spacer()
            if state.transfersLoading { ProgressView().controlSize(.small) }
            Text("\(filteredTransfers.count) Transfers")
                .foregroundColor(.secondary)
            if period == .all && state.transfersHaveMore {
                Button("Ältere laden") { Task { await state.loadOlderTransfers() } }
                    .disabled(state.transfersLoading)
                    .help("Lädt pro Manager 50 weitere Transfers")
            }
            Button {
                Task { await state.loadTransfers() }
            } label: {
                Label("Transfers neu laden", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(state.transfersLoading)
        }
    }

    private func statsTable(_ stats: [ManagerTransferStats]) -> some View {
        Table(stats, selection: $statsSelection) {
            TableColumn("Manager") { s in
                HStack(spacing: 4) {
                    Text(s.isMe ? "\(s.name) (du)" : s.name).fontWeight(s.isMe ? .bold : .regular)
                    if s.isHot {
                        Image(systemName: "flame.fill").foregroundColor(.warn)
                            .help("In den letzten 24 h besonders aktiv")
                            .accessibilityLabel("In den letzten 24 h besonders aktiv")
                    }
                }
            }
            TableColumn("Käufe") { s in Text("\(s.buys)").monospacedDigit() }.width(50)
            TableColumn("Verkäufe") { s in Text("\(s.sales)").monospacedDigit() }.width(60)
            TableColumn("Ausgegeben") { s in Text(Fmt.eur(s.spent)).monospacedDigit() }
            TableColumn("Eingenommen") { s in Text(Fmt.eur(s.earned)).monospacedDigit() }
            TableColumn("Saldo") { s in TrendText(value: s.balance) }
            TableColumn("Ø Überzahlung") { s in OverpayText(value: s.avgOverpay) }
            TableColumn("24 h") { s in Text("\(s.count24h)").monospacedDigit() }.width(40)
        }
        .contextMenu(forSelectionType: ManagerTransferStats.ID.self) { ids in
            if let id = ids.first {
                Button("Nur Transfers dieses Managers") { managerFilter = id }
            }
        } primaryAction: { ids in
            if let id = ids.first { managerFilter = id }
        }
        .fittedTableHeight(rows: stats.count, max: 240)
    }

    private var transferTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Datum", value: \.date) { r in
                Text(Fmt.shortDateTime(r.date)).monospacedDigit()
            }
            .width(min: 110, ideal: 120)
            TableColumn("Spieler", value: \.playerName) { r in
                HStack(spacing: 4) {
                    ClubCrest(club: .named(r.team), size: 14)
                    Text(r.playerName)
                }
            }
            TableColumn("Käufer", value: \.buyer) { r in PartyText(name: r.buyer) }
            TableColumn("Verkäufer", value: \.seller) { r in PartyText(name: r.seller) }
            TableColumn("Preis", value: \.price) { r in Text(Fmt.eur(r.price)).monospacedDigit() }
            TableColumn("Akt. Marktwert", value: \.marketValueSortKey) { r in
                Text(r.marketValue.map(Fmt.eur) ?? "…").monospacedDigit()
                    .foregroundColor(r.marketValue == nil ? .secondary : .primary)
            }
            TableColumn("Preis/MW", value: \.ratioSortKey) { r in
                if let ratio = r.ratio {
                    Text(Fmt.pct(ratio)).monospacedDigit()
                        .foregroundColor(ratio > 100 ? .warn : (ratio < 100 ? .gain : .primary))
                } else {
                    Text("–").foregroundColor(.secondary)
                }
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: TransferRow.ID.self) { ids in
            if let r = row(for: ids) {
                Button("Spielerdetails & Marktwertverlauf") { open(r) }
                if let id = r.transfer.buyerId {
                    Button("Nur Transfers von \(state.partyName(id))") { managerFilter = id }
                }
                if let id = r.transfer.sellerId {
                    Button("Nur Transfers von \(state.partyName(id))") { managerFilter = id }
                }
            }
        } primaryAction: { ids in
            if let r = row(for: ids) { open(r) }
        }
    }

    private func row(for ids: Set<TransferRow.ID>) -> TransferRow? {
        guard let id = ids.first else { return nil }
        return rows.first { $0.id == id }
    }

    private func open(_ r: TransferRow) {
        Task {
            if let p = await state.player(forId: r.transfer.playerId) { detailPlayer = p }
        }
    }
}

private struct PartyText: View {
    let name: String

    var body: some View {
        Text(name).foregroundColor(name == "Kickbase" ? .secondary : .primary)
    }
}

struct OverpayText: View {
    let value: Double?

    var body: some View {
        if let value {
            Text(Fmt.pct(value, signed: true)).monospacedDigit()
                .foregroundColor(value > 0 ? .warn : (value < 0 ? .gain : .primary))
        } else {
            Text("–").foregroundColor(.secondary)
        }
    }
}

/// Orange hints for managers who were particularly active in the last 24 h.
struct ActivityHints: View {
    let stats: [ManagerTransferStats]

    var body: some View {
        let hot = stats.filter { $0.isHot && !$0.isMe }
        if !hot.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hot) { s in
                    Label {
                        Text("\(s.name) war in den letzten 24 h besonders aktiv: \(s.count24h) Transfers, \(Fmt.eur(s.spent24h)) ausgegeben.")
                    } icon: {
                        Image(systemName: "flame.fill").foregroundColor(.warn)
                    }
                }
            }
                .bannerSurface(.warn)
        }
    }
}

/// Transfer figures of one manager (Transfers view and Kader-Analyse).
struct ManagerTransferPanel: View {
    let stats: ManagerTransferStats
    let periodLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers von \(stats.name)").font(.headline)
                Text("(\(periodLabel))").foregroundColor(.secondary)
                if stats.isHot {
                    Label("In den letzten 24 h besonders aktiv", systemImage: "flame.fill")
                        .foregroundColor(.warn)
                        .font(.callout)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                StatCard(title: "Käufe / Verkäufe", value: "\(stats.buys) / \(stats.sales)")
                StatCard(title: "Ausgegeben", value: Fmt.eur(stats.spent))
                StatCard(title: "Eingenommen", value: Fmt.eur(stats.earned))
                StatCard(title: "Saldo", value: Fmt.signedEur(stats.balance),
                         color: stats.balance > 0 ? .gain : (stats.balance < 0 ? .loss : nil))
                StatCard(title: "Ø Überzahlung ggü. akt. MW",
                         value: stats.avgOverpay.map { Fmt.pct($0, signed: true) } ?? "–",
                         color: (stats.avgOverpay ?? 0) > 0 ? .warn : nil)
                StatCard(title: "Transfers 24 h", value: "\(stats.count24h)",
                         color: stats.isHot ? .warn : nil)
            }
            InsightBox(
                title: "Zuletzt gekauft",
                lines: stats.recentBuys.map {
                    "\($0.playerName) – \(Fmt.eur($0.price)) – \(Fmt.shortDateTime($0.date))"
                }
            )
        }
    }
}
