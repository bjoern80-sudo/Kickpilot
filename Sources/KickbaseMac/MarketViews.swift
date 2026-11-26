import SwiftUI

struct MarketView: View {
    @EnvironmentObject var state: AppState
    @State private var sortOrder = [KeyPathComparator(\Player.pointsPerMillion, order: .reverse)]
    @State private var selection: Player.ID? = nil
    @State private var search = ""
    @State private var positionFilter = 0
    @State private var onlyKickbase = false
    @State private var bidPlayer: Player? = nil
    @State private var detailPlayer: Player? = nil

    private var filtered: [Player] {
        state.market.filter { p in
            (positionFilter == 0 || p.position == positionFilter)
                && (!onlyKickbase || p.sellerUserId == nil)
                && (search.isEmpty
                    || p.fullName.localizedCaseInsensitiveContains(search)
                    || state.teamName(p.teamId).localizedCaseInsensitiveContains(search))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("Position", selection: $positionFilter) {
                    Text("Alle").tag(0)
                    Text("TW").tag(1)
                    Text("ABW").tag(2)
                    Text("MIT").tag(3)
                    Text("ST").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Toggle("Nur Kickbase-Angebote", isOn: $onlyKickbase)
                Spacer()
                Text("\(filtered.count) Spieler · Doppelklick = Gebot")
                    .foregroundColor(.secondary)
            }

            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.lastName) { p in PlayerNameCell(player: p) }
                TableColumn("Pos.", value: \.position) { p in Text(p.positionName) }
                    .width(45)
                TableColumn("Verein", value: \.teamId) { p in Text(state.teamName(p.teamId)) }
                TableColumn("Preis", value: \.effectivePrice) { p in
                    Text(Fmt.eur(p.effectivePrice)).monospacedDigit()
                }
                TableColumn("Marktwert", value: \.marketValue) { p in
                    Text(Fmt.eur(p.marketValue)).monospacedDigit()
                }
                TableColumn("24h", value: \.trend24h) { p in TrendText(value: p.trend24h) }
                TableColumn("Ø Pkt.", value: \.averagePoints) { p in
                    Text(Fmt.int(p.averagePoints)).monospacedDigit()
                }
                TableColumn("Pkt./Mio.", value: \.pointsPerMillion) { p in
                    Text(Fmt.dec(p.pointsPerMillion)).monospacedDigit()
                }
                TableColumn("Läuft ab", value: \.expiresIn) { p in
                    Text(Fmt.remaining(p.expiresAt))
                        .foregroundColor(p.expiresIn < 6 * 3600 ? .orange : .primary)
                }
                TableColumn("Anbieter", value: \.sellerSortKey) { p in Text(state.sellerName(p)) }
            }
            .contextMenu(forSelectionType: Player.ID.self) { ids in
                if let p = player(for: ids) {
                    Button("Gebot abgeben …") { bidPlayer = p }
                    Button("Details & Marktwertverlauf") { detailPlayer = p }
                }
            } primaryAction: { ids in
                if let p = player(for: ids) { bidPlayer = p }
            }
            .sheet(item: $detailPlayer) { p in
                PlayerDetailView(player: p).environmentObject(state)
            }
        }
        .padding()
        .searchable(text: $search, prompt: "Spieler oder Verein")
        .sheet(item: $bidPlayer) { p in
            BidView(player: p).environmentObject(state)
        }
    }

    private func player(for ids: Set<Player.ID>) -> Player? {
        guard let id = ids.first else { return nil }
        return state.market.first { $0.id == id }
    }
}

struct BidView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let player: Player

    @State private var amount: Double = 0
    @State private var showConfirm = false
    @State private var sending = false
    @State private var errorText: String? = nil
    @State private var offers: [Offer] = []

    private var budgetAfter: Double { state.budget - amount }
    private var myOffers: [Offer] {
        offers.filter { !state.myUserId.isEmpty && $0.userId == state.myUserId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gebot für \(player.fullName)").font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Angebotspreis").foregroundColor(.secondary)
                    Text(Fmt.eur(player.effectivePrice)).monospacedDigit()
                }
                GridRow {
                    Text("Marktwert").foregroundColor(.secondary)
                    Text(Fmt.eur(player.marketValue)).monospacedDigit()
                }
                GridRow {
                    Text("Anbieter").foregroundColor(.secondary)
                    Text(state.sellerName(player))
                }
                GridRow {
                    Text("Läuft ab in").foregroundColor(.secondary)
                    Text(Fmt.remaining(player.expiresAt))
                }
                GridRow {
                    Text("Gebote bisher").foregroundColor(.secondary)
                    Text("\(player.offerCount)")
                }
                if let mine = player.myOfferPrice {
                    GridRow {
                        Text("Dein Gebot").foregroundColor(.secondary)
                        Text(Fmt.eur(mine)).monospacedDigit().fontWeight(.semibold)
                    }
                }
                GridRow {
                    Text("Dein Budget").foregroundColor(.secondary)
                    Text(Fmt.eur(state.budget)).monospacedDigit()
                }
            }

            Divider()

            HStack {
                Text("Dein Gebot:")
                TextField("Betrag in €", value: $amount, format: .number.precision(.fractionLength(0)))
                    .frame(width: 160)
                    .multilineTextAlignment(.trailing)
                Text("€")
            }
            HStack {
                Button("= Preis") { amount = player.effectivePrice.rounded() }
                Button("+2 %") { amount = (player.effectivePrice * 1.02).rounded() }
                Button("+5 %") { amount = (player.effectivePrice * 1.05).rounded() }
                Button("+10 %") { amount = (player.effectivePrice * 1.10).rounded() }
            }
            .controlSize(.small)

            Text("Budget danach: \(Fmt.eur(budgetAfter))")
                .foregroundColor(budgetAfter < 0 ? .red : .secondary)
            if amount < player.effectivePrice {
                Text("Achtung: Gebot liegt unter dem Angebotspreis.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if !myOffers.isEmpty {
                Divider()
                Text("Deine offenen Gebote").font(.headline)
                ForEach(myOffers) { offer in
                    HStack {
                        Text(Fmt.eur(offer.price)).monospacedDigit()
                        Spacer()
                        Button("Zurückziehen") {
                            Task {
                                errorText = await state.withdrawOffer(player, offer: offer)
                                offers = await state.offers(for: player)
                            }
                        }
                    }
                }
            }

            if let errorText {
                Text(errorText).foregroundColor(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    showConfirm = true
                } label: {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Gebot abgeben …")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(amount <= 0 || sending)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { amount = player.effectivePrice.rounded() }
        .task { offers = await state.offers(for: player) }
        .confirmationDialog(
            "Gebot über \(Fmt.eur(amount)) für \(player.fullName) abgeben?",
            isPresented: $showConfirm
        ) {
            Button("Verbindlich bieten", role: .destructive) {
                Task { await send() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Das ist eine echte Transaktion in deiner Kickbase-Liga.")
        }
    }

    @MainActor
    private func send() async {
        sending = true
        errorText = await state.placeOffer(player, price: Int(amount.rounded()))
        sending = false
        if errorText == nil { dismiss() }
    }
}
