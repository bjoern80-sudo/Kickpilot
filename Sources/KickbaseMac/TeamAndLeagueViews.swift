import Charts
import SwiftUI

struct TeamView: View {
    @EnvironmentObject var state: AppState
    @State private var sortOrder = [KeyPathComparator(\Player.marketValue, order: .reverse)]
    @State private var detailPlayer: Player? = nil
    @State private var sellAlert: InjuryAlert? = nil
    @State private var sellResult: String? = nil

    private var teamValue: Double { state.squad.reduce(0.0) { $0 + $1.marketValue } }
    private var trend: Double { state.squad.reduce(0.0) { $0 + $1.trend24h } }
    private var points: Double { state.squad.reduce(0.0) { $0 + $1.totalPoints } }

    private var subtitle: String {
        var parts = [state.currentLeague?.name ?? "Kickbase"]
        if let check = state.lineupCheck, let day = check.matchday {
            parts.append(check.lockAt.map { "\(day). Spieltag – Aufstellung bis \(Fmt.deadline($0))" }
                         ?? "\(day). Spieltag läuft")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Page(title: "Mein Team", subtitle: subtitle) {
            HStack(spacing: Theme.gap) {
                StatCard(title: "Budget", value: Fmt.eur(state.budget),
                         color: state.budget < 0 ? .loss : nil, icon: "eurosign.circle")
                StatCard(title: "Teamwert", value: Fmt.eur(teamValue), icon: "chart.line.uptrend.xyaxis")
                StatCard(title: "Marktwert 24 h", value: Fmt.signedEur(trend),
                         color: trend == 0 ? nil : Theme.signColor(trend), icon: "clock.arrow.circlepath")
                StatCard(title: "Punkte (Kader)", value: Fmt.int(points), icon: "star")
            }
            ForEach(state.injuryAlerts) { a in
                InjuryBanner(alert: a, onSell: { sellAlert = a }, onDismiss: { state.dismissInjury(a) })
            }
            if let check = state.lineupCheck, !check.issues.isEmpty { LineupBanner(check: check) }
            HStack(alignment: .top, spacing: Theme.gap) {
                ScrollView {
                    PitchCard(squad: state.squad, check: state.lineupCheck) { detailPlayer = $0 }
                }
                .frame(width: 340)
                Card(title: "Kader", detail: "\(state.squad.count) / \(AutoRules.maxSquadSize) Spieler", padding: 0) {
                    PlayerTable(players: state.squad, sortOrder: $sortOrder) { detailPlayer = $0 }
                        .scrollContentBackground(.hidden)
                        .fittedTableHeight(rows: state.squad.count, max: 560)
                }
            }
        }
        .sheet(item: $detailPlayer) { p in
            PlayerDetailView(player: p).environmentObject(state)
        }
        .confirmationDialog(
            sellAlert.map { "\($0.player.fullName) an Kickbase verkaufen?" } ?? "",
            isPresented: Binding(get: { sellAlert != nil }, set: { if !$0 { sellAlert = nil } }),
            presenting: sellAlert
        ) { a in
            Button("Für ca. \(Fmt.eur(a.proceeds)) verkaufen", role: .destructive) {
                Task { sellResult = await state.sellInjured(a) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Echte Transaktion: Der Spieler wird gelistet und sofort an Kickbase verkauft (100 % des Marktwerts). Das lässt sich nicht rückgängig machen.")
        }
        .alert("Verkauf", isPresented: Binding(get: { sellResult != nil }, set: { if !$0 { sellResult = nil } })) {
            Button("OK") {}
        } message: {
            Text(sellResult ?? "")
        }
    }
}

/// Newly injured own player: sell before the 22:00 market value update?
struct InjuryBanner: View {
    let alert: InjuryAlert
    var onSell: () -> Void
    var onDismiss: () -> Void

    private var day: String {
        AutoRules.berlin.component(.hour, from: Date()) < AutoRules.marketValueUpdateHour ? "heute" : "morgen"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cross.case.fill").foregroundColor(.loss)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(alert.player.fullName) (\(alert.player.positionName)) ist als verletzt gemeldet")
                    .font(.callout.weight(.semibold))
                Text("Verletzte Spieler verlieren meist an Wert. Bis \(day) 22:00 Uhr bringt ein Verkauf an Kickbase noch ca. \(Fmt.eur(alert.proceeds)).")
                    .font(.caption).foregroundColor(.secondary)
                if alert.inCore {
                    Text("Gehört zu deinen Top 11 (Ø-Punkte).").font(.caption).foregroundColor(.warn)
                }
                if !alert.sellable {
                    Text("Verkauf nicht möglich: \(alert.reason).").font(.caption).foregroundColor(.loss)
                }
            }
            Spacer()
            if alert.sellable {
                Button("Verkaufen …", action: onSell)
            }
            Button("Behalten", action: onDismiss)
        }
        .bannerSurface(.loss)
    }
}

/// Lineup guard: hints only – the lineup has to be changed in the Kickbase app.
struct LineupBanner: View {
    let check: LineupCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if check.lockAt == nil {
                    Label("Spieltag \(check.matchday ?? 0) läuft – Aufstellung gesperrt", systemImage: "lock.fill")
                        .foregroundColor(.secondary)
                } else if check.problems.isEmpty {
                    Label("Aufstellung ok", systemImage: "checkmark.circle.fill").foregroundColor(.gain)
                } else {
                    Label("Aufstellung prüfen", systemImage: "exclamationmark.triangle.fill").foregroundColor(.loss)
                }
                if let lock = check.lockAt {
                    Text("· Spieltag \(check.matchday ?? 0), muss stehen bis \(Fmt.deadline(lock))")
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
                        .foregroundColor(i.isProblem ? .loss : .warn)
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
        .bannerSurface(check.problems.isEmpty ? .brandText : .loss)
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
        Page(title: "Liga", subtitle: "\(state.managers.count) Manager · Doppelklick öffnet die Kader-Analyse") {
            Card(title: "Tabelle", padding: 0) {
            Table(state.managers, selection: $selection) {
                TableColumn("Platz") { m in PlacementBadge(placement: m.placement) }
                    .width(50)
                TableColumn("Manager") { m in
                    Text(m.id == state.myUserId ? "\(m.name) (du)" : m.name)
                        .fontWeight(m.id == state.myUserId ? .bold : .regular)
                }
                TableColumn("Punkte") { m in Text(Fmt.int(m.seasonPoints)).monospacedDigit() }
                TableColumn("Abstand") { m in
                    let gap = (state.managers.map(\.seasonPoints).max() ?? m.seasonPoints) - m.seasonPoints
                    Text(gap > 0 ? "−\(Fmt.int(gap))" : "Spitze").monospacedDigit()
                }
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
            .scrollContentBackground(.hidden)
            .fittedTableHeight(rows: state.managers.count)
            }
            Spacer(minLength: 0)
        }
    }
}

/// League placement; top three in gold, silver, bronze.
struct PlacementBadge: View {
    let placement: Int

    private var medal: Color? {
        switch placement {
        case 1: return Color(hex: 0xD4A017)
        case 2: return Color(hex: 0x9AA4B2)
        case 3: return Color(hex: 0xB0703C)
        default: return nil
        }
    }

    var body: some View {
        Text("\(placement)")
            .font(Theme.number(12, weight: .bold))
            .foregroundColor(medal == nil ? .secondary : .white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(medal ?? Color.clear))
            .accessibilityLabel("Platz \(placement)")
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
                HStack(spacing: 12) {
                    ClubCrest(club: .named(state.teamName(player.teamId)), size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.fullName).font(.title2.bold())
                        HStack(spacing: 6) {
                            PositionChip(position: player.position)
                            Text(state.teamName(player.teamId)).foregroundColor(.secondary)
                            if player.isFit {
                                Badge(text: "fit", color: .gain)
                            } else {
                                Badge(text: player.statusText, color: .loss)
                            }
                        }
                    }
                }
                Spacer()
                Button("Schließen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                StatCard(title: "Marktwert", value: Fmt.eur(player.marketValue))
                StatCard(title: "24h", value: Fmt.signedEur(player.trend24h),
                         color: player.trend24h > 0 ? .gain : (player.trend24h < 0 ? .loss : nil))
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
                        .foregroundStyle(Color.brand)
                        AreaMark(
                            x: .value("Datum", point.date),
                            y: .value("Mio. €", point.value / 1_000_000)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Color.brand.opacity(0.25), Color.brand.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
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
