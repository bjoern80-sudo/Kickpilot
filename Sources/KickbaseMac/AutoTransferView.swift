import SwiftUI

/// Transfer automation: buy proposals from bidder profiles + Friday balance sales.
/// Nothing is executed without the confirmation dialog.
struct AutoTransferView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedBuys: Set<String> = []
    @State private var selectedSales: Set<String> = []
    @State private var confirmBuys = false
    @State private var confirmSales = false
    @State private var executing = false
    @State private var log: [String] = []
    @State private var detailPlayer: Player? = nil
    @State private var withdrawPlayer: Player? = nil

    private var plan: AutoPlan? { state.autoPlan }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                DeadlineBanner(budget: state.budget, plan: plan)
                if let plan {
                    openBidSection(plan)
                    buySection(plan)
                    saleSection(plan)
                    profileSection
                } else if state.autoLoading {
                    ProgressView(state.autoStatus).frame(maxWidth: .infinity)
                } else {
                    Text("Berechne den Plan, um Gebots- und Verkaufsvorschläge zu sehen.")
                        .foregroundColor(.secondary)
                }
                if !log.isEmpty {
                    InsightBox(title: "Protokoll", lines: log)
                }
            }
            .padding()
        }
        .task {
            if state.autoPlan == nil { await state.buildAutoPlan() }
        }
        .onChange(of: plan?.buys.map(\.id) ?? []) { ids in selectedBuys = Set(ids) }
        .onChange(of: plan?.sales.map(\.id) ?? []) { ids in selectedSales = Set(ids) }
        .onAppear {
            selectedBuys = Set(plan?.buys.map(\.id) ?? [])
            selectedSales = Set(plan?.sales.map(\.id) ?? [])
        }
        .sheet(item: $detailPlayer) { p in
            PlayerDetailView(player: p).environmentObject(state)
        }
        .confirmationDialog(confirmBuysTitle, isPresented: $confirmBuys) {
            Button("Verbindlich bieten", role: .destructive) {
                run { await state.executeBuys(chosenBuys) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(chosenBuys.map { "\($0.player.fullName): \(Fmt.eur($0.bid))" }.joined(separator: "\n")
                 + "\n\nDas sind echte Transaktionen in deiner Kickbase-Liga.")
        }
        .confirmationDialog(
            "Gebot über \(Fmt.eur(withdrawPlayer?.myOfferPrice ?? 0)) auf \(withdrawPlayer?.fullName ?? "") zurückziehen?",
            isPresented: Binding(get: { withdrawPlayer != nil }, set: { if !$0 { withdrawPlayer = nil } }),
            presenting: withdrawPlayer
        ) { p in
            Button("Gebot zurückziehen", role: .destructive) {
                run { [await state.withdrawMyBid(p)] }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Das ist eine echte Aktion in deiner Kickbase-Liga.")
        }
        .confirmationDialog(confirmSalesTitle, isPresented: $confirmSales) {
            Button("Verbindlich verkaufen", role: .destructive) {
                run { await state.executeSales(chosenSales) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(chosenSales.map { "\($0.player.fullName): ca. \(Fmt.eur($0.expectedProceeds))" }.joined(separator: "\n")
                 + "\n\nDie Spieler werden sofort an Kickbase verkauft – das ist nicht rückgängig zu machen.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transfer-Automatik").font(.headline)
                Text("Stichtag \(Fmt.deadline(plan?.deadline ?? AutoRules.nextDeadline()))")
                    .foregroundColor(.secondary)
                Spacer()
                if state.autoLoading {
                    ProgressView().controlSize(.small)
                    Text(state.autoStatus).font(.caption).foregroundColor(.secondary)
                }
                Toggle("Alle 15 min neu berechnen", isOn: $state.autoRefreshEnabled)
                    .help("Rechnet den Plan im Hintergrund neu, solange die App läuft. Ausgeführt wird nichts ohne deine Bestätigung.")
                Button {
                    Task { await state.buildAutoPlan() }
                } label: {
                    Label("Plan berechnen", systemImage: "wand.and.stars")
                }
                .disabled(state.autoLoading || executing)
            }
            HStack(spacing: 10) {
                StatCard(title: "Budget", value: Fmt.eur(state.budget), color: state.budget < 0 ? .red : nil)
                StatCard(title: "Freitags verkaufbar (ohne Top-\(AutoRules.keepCore))",
                         value: Fmt.eur(plan?.reserve ?? 0))
                StatCard(title: "Offene Gebote", value: Fmt.eur(plan?.openBids ?? 0))
                StatCard(title: "Rahmen bis Freitag 19 Uhr", value: Fmt.eur(plan?.bidLimit ?? 0))
                StatCard(title: "Gesamtrahmen (bis −\(Int(AutoRules.maxDebtShareOfTeamValue * 100)) % Teamwert)",
                         value: Fmt.eur(plan?.globalLimit ?? 0))
                StatCard(title: "Kader", value: "\(state.squad.count) / \(AutoRules.maxSquadSize)",
                         color: state.squad.count >= AutoRules.maxSquadSize ? .orange : nil)
            }
        }
    }

    // MARK: Buys

    private var chosenBuys: [BuyProposal] { plan?.buys.filter { selectedBuys.contains($0.id) } ?? [] }
    private var chosenSales: [SaleProposal] { plan?.sales.filter { selectedSales.contains($0.id) } ?? [] }

    private var confirmBuysTitle: String {
        "\(chosenBuys.count) Gebote über insgesamt \(Fmt.eur(chosenBuys.reduce(0) { $0 + $1.bid })) abgeben?"
    }

    private var confirmSalesTitle: String {
        "\(chosenSales.count) Spieler an Kickbase verkaufen (ca. \(Fmt.eur(chosenSales.reduce(0) { $0 + $1.expectedProceeds })))?"
    }

    @ViewBuilder
    private func buySection(_ plan: AutoPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Gebotsvorschläge").font(.headline)
                Text("stabil steigend oder Trendumkehr nach Boden, noch unter dem letzten Hochpunkt, Gewinn ≥ \(Fmt.eur(AutoRules.minProfit)) bzw. \(Int(AutoRules.minProfitPct)) % · Gebot knapp über \(plan.competitorName) (\(Fmt.pct(plan.competitorPct, signed: true)))")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Ausgewählte Gebote abgeben …") { confirmBuys = true }
                    .disabled(chosenBuys.isEmpty || executing)
            }
            BacktestBox(result: plan.backtest)
            if plan.buys.isEmpty {
                Text("Aktuell kein Spieler, bei dem sich ein Gebot lohnt.").foregroundColor(.secondary)
            } else {
                Table(plan.buys) {
                    TableColumn("") { b in
                        Toggle("", isOn: binding(b.id, in: $selectedBuys)).labelsHidden()
                    }
                    .width(24)
                    TableColumn("Spieler") { b in
                        HStack(spacing: 4) {
                            PlayerNameCell(player: b.player)
                            Text(b.trend.pattern.rawValue).font(.caption2)
                                .padding(.horizontal, 4)
                                .background((b.trend.pattern == .reversal ? Color.purple : Color.green).opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .help(b.trend.pattern == .reversal
                                      ? "Boden bei \(b.trend.trough.map(Fmt.eur) ?? "–") nach \(b.trend.dropBeforeTroughPct.map { Fmt.pct($0) } ?? "–") Rückgang"
                                      : "\(b.trend.risingDays) von 5 Tagen gestiegen")
                        }
                    }
                    TableColumn("Marktwert") { b in Text(Fmt.eur(b.player.marketValue)).monospacedDigit() }
                    TableColumn("Zuwachs \(Int(AutoRules.momentumDays)) T") { b in
                        Text(Fmt.pct(b.momentumPct, signed: true)).monospacedDigit().foregroundColor(.green)
                    }
                    TableColumn("Gebot") { b in Text(Fmt.eur(b.bid)).monospacedDigit().fontWeight(.semibold) }
                    TableColumn("über MW") { b in Text(Fmt.pct(b.bidOverMVPct, signed: true)).monospacedDigit() }
                    TableColumn("Letzter Hochpunkt") { b in
                        HStack(spacing: 4) {
                            Text(b.trend.peak.map(Fmt.eur) ?? "–").monospacedDigit()
                            if let h = b.trend.headroomPct {
                                Text(Fmt.pct(h, signed: true)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .help(b.trend.peakDate.map { "Hochpunkt vom \($0.formatted(date: .numeric, time: .omitted))" } ?? "")
                    }
                    TableColumn("Erw. Verkauf (\(Int(AutoRules.holdDays)) T)") { b in
                        Text(Fmt.eur(b.trend.expectedSale)).monospacedDigit()
                    }
                    TableColumn("Endet") { b in
                        HStack(spacing: 4) {
                            Text(Fmt.remaining(b.player.expiresAt))
                            if b.afterDeadline {
                                Text("nach Stichtag").font(.caption2)
                                    .padding(.horizontal, 4)
                                    .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    .help("Endet ab Freitag 20 Uhr – zählt erst für die nächste Woche")
                            }
                        }
                    }
                    TableColumn("Erw. Gewinn") { b in TrendText(value: b.expectedGain) }
                }
                .frame(height: CGFloat(plan.buys.count) * 26 + 34)
                Text("Summe ausgewählt: \(Fmt.eur(chosenBuys.reduce(0) { $0 + $1.bid })) · bis Freitag: \(Fmt.eur(plan.bidLimit)) · gesamt: \(Fmt.eur(plan.globalLimit))")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !plan.skipped.isEmpty {
                DisclosureGroup("Nicht berücksichtigt (\(plan.skipped.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(plan.skipped) { s in
                            Text("\(s.player.fullName) – \(s.reason)").font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }

    // MARK: Sales

    @ViewBuilder
    private func saleSection(_ plan: AutoPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Freitags-Ausgleich").font(.headline)
                Text("schwächste Spieler mit dem besten Wertzuwachs, sofort an Kickbase · bleibt immer: mind. 1 TW, 3 ABW, 1 ST")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Ausgewählte an Kickbase verkaufen …") { confirmSales = true }
                    .disabled(chosenSales.isEmpty || executing)
            }
            if plan.sales.isEmpty {
                Label("Budget ist ausgeglichen – kein Verkauf nötig.", systemImage: "checkmark.circle")
                    .foregroundColor(.green)
            } else {
                Table(plan.sales) {
                    TableColumn("") { s in
                        Toggle("", isOn: binding(s.id, in: $selectedSales)).labelsHidden()
                    }
                    .width(24)
                    TableColumn("Spieler") { s in PlayerNameCell(player: s.player) }
                    TableColumn("Ø Punkte") { s in Text(Fmt.int(s.player.averagePoints)).monospacedDigit() }
                    TableColumn("Wertzuwachs") { s in
                        HStack(spacing: 4) {
                            Text(Fmt.pct(s.gainPct, signed: true)).monospacedDigit()
                                .foregroundColor(s.gainPct >= 0 ? .green : .red)
                            Text(s.gainBasis).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    TableColumn("Marktwert") { s in Text(Fmt.eur(s.player.marketValue)).monospacedDigit() }
                    TableColumn("Erlös ca.") { s in Text(Fmt.eur(s.expectedProceeds)).monospacedDigit() }
                }
                .frame(height: CGFloat(plan.sales.count) * 26 + 34)
                saleImpact(plan)
                if plan.budgetAfterSales < 0 {
                    Label("Selbst mit allen erlaubten Verkäufen bleibt das Budget bei ca. \(Fmt.eur(plan.budgetAfterSales)). Mindestbesetzung (1 TW, 3 ABW, 1 ST) wird nicht unterschritten.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                Text("Budget danach ca. \(Fmt.eur(plan.budgetAfterSales))\(plan.openBids > 0 ? ", falls deine offenen Gebote (\(Fmt.eur(plan.openBids))) gewinnen" : "") (Verkauf an Kickbase zum vollen Marktwert)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// Live budget for the current selection; unchecked players show what keeping them costs.
    @ViewBuilder
    private func saleImpact(_ plan: AutoPlan) -> some View {
        let withSelection = plan.committedBudget + chosenSales.reduce(0) { $0 + $1.expectedProceeds }
        let kept = plan.sales.filter { !selectedSales.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: withSelection >= 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Text("Budget am Stichtag mit deiner Auswahl: \(Fmt.eur(withSelection))")
                    .fontWeight(.semibold).monospacedDigit()
                if withSelection < 0 {
                    Text("– es fehlen noch \(Fmt.eur(-withSelection))")
                }
            }
            .foregroundColor(withSelection >= 0 ? .green : .red)
            ForEach(kept) { s in
                Text("Ohne Verkauf von \(s.player.fullName): \(Fmt.signedEur(-s.expectedProceeds)) Budget")
                    .font(.callout).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Open bids

    @ViewBuilder
    private func openBidSection(_ plan: AutoPlan) -> some View {
        let bids = state.market.filter { $0.myOfferPrice != nil }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Deine offenen Gebote").font(.headline)
                Text("Einschätzung gegen das erwartete Höchstgebot von \(plan.competitorName) (\(Fmt.pct(plan.competitorPct, signed: true)) über MW)")
                    .font(.caption).foregroundColor(.secondary)
            }
            if bids.isEmpty {
                Text("Du hast aktuell keine offenen Gebote.").foregroundColor(.secondary)
            } else {
                Table(bids) {
                    TableColumn("") { p in
                        Button("Zurückziehen …") { withdrawPlayer = p }
                            .controlSize(.small)
                            .disabled(executing)
                    }
                    .width(110)
                    TableColumn("Spieler") { p in PlayerNameCell(player: p) }
                    TableColumn("Marktwert") { p in Text(Fmt.eur(p.marketValue)).monospacedDigit() }
                    TableColumn("Angebotspreis") { p in Text(Fmt.eur(p.effectivePrice)).monospacedDigit() }
                    TableColumn("Dein Gebot") { p in
                        Text(Fmt.eur(p.myOfferPrice ?? 0)).monospacedDigit().fontWeight(.semibold)
                    }
                    TableColumn("über MW") { p in
                        let pct = p.marketValue > 0 ? ((p.myOfferPrice ?? 0) / p.marketValue - 1) * 100 : 0
                        Text(Fmt.pct(pct, signed: true)).monospacedDigit()
                    }
                    TableColumn("Einschätzung") { p in
                        let mine = p.myOfferPrice ?? 0
                        let rec = plan.recommendedBid(for: p)
                        if mine >= rec {
                            Label("reicht vermutlich", systemImage: "checkmark.circle").foregroundColor(.green)
                        } else {
                            Text("zu niedrig, empf. \(Fmt.mio(rec))").foregroundColor(.orange).help("Empfohlenes Gebot: \(Fmt.eur(rec))")
                        }
                    }
                    TableColumn("Endet") { p in
                        HStack(spacing: 4) {
                            Text(Fmt.remaining(p.expiresAt))
                            if (p.expiresAt ?? .distantFuture) >= plan.freeFrom {
                                Text("nach Stichtag").font(.caption2)
                                    .padding(.horizontal, 4)
                                    .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
                .frame(height: CGFloat(bids.count) * 26 + 34)
                Text("Summe: \(Fmt.eur(plan.allOpenBids)) · davon vor dem Stichtag fällig: \(Fmt.eur(plan.openBids))")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Profiles

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bieterprofile").font(.headline)
            Text("Aufpreis gegenüber dem Marktwert am Kauftag, aus den geladenen Transfers")
                .font(.caption).foregroundColor(.secondary)
            Table(state.bidderProfiles) {
                TableColumn("Manager") { p in
                    Text(p.id == state.myUserId ? "\(p.name) (du)" : p.name)
                }
                TableColumn("Käufe ausgewertet") { p in
                    Text("\(p.samples)").foregroundColor(p.isReliable ? .primary : .secondary)
                }
                TableColumn("Median") { p in OverpayText(value: p.medianOverpay) }
                TableColumn("Typisch hoch (75 %)") { p in OverpayText(value: p.typicalHighOverpay) }
                TableColumn("Maximum") { p in OverpayText(value: p.maxOverpay) }
                TableColumn("Käufe/Woche") { p in Text(Fmt.dec(p.buysPerWeek)).monospacedDigit() }
            }
            .frame(height: CGFloat(state.bidderProfiles.count) * 26 + 34)
        }
    }

    // MARK: Helpers

    private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { on in
                if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            }
        )
    }

    private func run(_ action: @escaping () async -> [String]) {
        Task {
            executing = true
            log = await action()
            executing = false
            await state.buildAutoPlan()
        }
    }
}

/// How the buy rule performed on past market values.
struct BacktestBox: View {
    let result: BacktestResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundColor(.secondary)
            if result.all.signals == 0 {
                Text("Backtest: In den letzten \(AutoRules.backtestDays) Tagen hätte die Regel kein Gebot ausgelöst.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backtest der letzten \(AutoRules.backtestDays) Tage: \(result.all.signals) Gebote nach dieser Regel, Verkauf nach \(Int(AutoRules.holdDays)) Tagen")
                        .font(.callout.weight(.semibold))
                    line("Stabiler Anstieg", result.steady)
                    line("Trendumkehr", result.reversal)
                    Text("Annahme: jedes Gebot gewinnt zum heute üblichen Aufpreis; Verkauf zum vollen Marktwert.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension BacktestBox {
    @ViewBuilder
    fileprivate func line(_ title: String, _ s: BacktestStats) -> some View {
        if s.signals > 0 {
            Text("\(title): \(s.signals) × · mit Gewinn \(Fmt.pct(s.hitRate)) · Ø \(Fmt.pct(s.avgProfitPct, signed: true)) · Ziel erreicht \(Fmt.pct(s.targetRate))")
                .font(.callout).monospacedDigit()
                .foregroundColor(s.avgProfitPct > 0 ? .green : .red)
        } else {
            Text("\(title): keine Signale").font(.callout).foregroundColor(.secondary)
        }
    }
}

/// Warning before the Friday 19:00 budget deadline.
struct DeadlineBanner: View {
    let budget: Double
    let plan: AutoPlan?

    var body: some View {
        let deadline = plan?.deadline ?? AutoRules.nextDeadline()
        let hours = deadline.timeIntervalSinceNow / 3600
        if budget < 0 {
            let urgent = hours <= AutoRules.deadlineWarningHours
            Label {
                Text(urgent
                     ? "Budget negativ (\(Fmt.eur(budget))) – Stichtag in \(Fmt.remaining(deadline))! Jetzt Verkäufe bestätigen."
                     : "Budget negativ (\(Fmt.eur(budget))). Bis \(Fmt.deadline(deadline)) muss es ausgeglichen sein.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundColor(urgent ? .white : .primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((urgent ? Color.red : Color.orange.opacity(0.18)), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
