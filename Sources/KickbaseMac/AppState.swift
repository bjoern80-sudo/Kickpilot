import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var userName = ""
    @Published var myUserId = ""

    @Published var leagues: [League] = []
    @Published var selectedLeagueId: String? {
        didSet {
            if oldValue != selectedLeagueId, isLoggedIn {
                Task { await refreshAll() }
            }
        }
    }

    @Published var budget: Double = 0
    @Published var squad: [Player] = [] { didSet { updateInjuries() } }
    /// Own players newly reported injured – shown in the team view until sold or dismissed.
    @Published var injuryAlerts: [InjuryAlert] = []
    @Published var market: [Player] = []
    @Published var managers: [Manager] = []
    @Published var teams: [String: Team] = [:]
    /// Season schedule (kick-off times) for the lineup guard.
    @Published var matchdays: [Matchday] = []
    @Published var managerSquads: [String: [Player]] = [:]
    @Published var lastUpdate: Date?

    // Transfers of all managers (see loadTransfers)
    @Published var transfers: [Transfer] = []
    @Published var transfersLoading = false
    @Published var transfersLoadedAt: Date?
    @Published var transfersHaveMore = false
    /// Player details fetched for transfer rows (current market value, detail view).
    @Published var playerInfo: [String: Player] = [:]
    private var transferEntries: [String: [ManagerTransferEntry]] = [:]
    private var transferNextStart: [String: Int] = [:]
    private var playerInfoFailed: Set<String> = []
    private static let transferPageSize = 25

    // Transfer automation (proposals only – execution needs confirmation in the UI)
    @Published var autoPlan: AutoPlan?
    @Published var bidderProfiles: [BidderProfile] = []
    @Published var autoLoading = false
    @Published var autoStatus = ""
    private var mvHistory: [String: [MVPoint]] = [:]
    /// Budget negative and Friday 20:30 deadline close.
    @Published var deadlineAlert = false
    @Published var autoRefreshEnabled = false {
        didSet { if autoRefreshEnabled != oldValue { restartAutoLoop() } }
    }
    private var autoLoop: Task<Void, Never>?
    private var deadlineWatch: Task<Void, Never>?

    private var api: KickbaseAPI?
    private let emailKey = "kickbaseEmail"
    private let leagueKey = "selectedLeague"

    var currentLeague: League? { leagues.first { $0.id == selectedLeagueId } }
    var savedEmail: String { UserDefaults.standard.string(forKey: emailKey) ?? "" }

    // MARK: - Login

    func tryAutoLogin() async {
        guard !isLoggedIn else { return }
        let email = savedEmail
        guard !email.isEmpty, let pw = Keychain.load(account: email) else { return }
        await login(email: email, password: pw, remember: true)
    }

    func login(email: String, password: String, remember: Bool) async {
        isLoading = true
        errorMessage = nil
        let client = KickbaseAPI(email: email, password: password)
        do {
            try await client.login()
            userName = await client.userName
            myUserId = await client.userId
            let ls = try await client.leagues()
            api = client
            leagues = ls
            let saved = UserDefaults.standard.string(forKey: leagueKey)
            selectedLeagueId = ls.first(where: { $0.id == saved })?.id ?? ls.first?.id
            UserDefaults.standard.set(email, forKey: emailKey)
            if remember {
                Keychain.save(account: email, password: password)
            } else {
                Keychain.delete(account: email)
            }
            isLoggedIn = true
            isLoading = false
            await refreshAll()
            startDeadlineWatch()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        autoRefreshEnabled = false
        deadlineWatch?.cancel()
        deadlineAlert = false
        let email = savedEmail
        if !email.isEmpty { Keychain.delete(account: email) }
        isLoggedIn = false
        api = nil
        leagues = []
        selectedLeagueId = nil
        squad = []
        market = []
        managers = []
        managerSquads = [:]
        budget = 0
        resetTransfers()
    }

    /// Lineup guard for the current matchday (read-only hints, never changes the lineup).
    var lineupCheck: LineupCheck? {
        matchdays.isEmpty ? nil : LineupCheck.check(squad: squad, matchday: Matchday.current(matchdays))
    }

    /// Compares the squad with the injured players seen last time (stored per league).
    /// First run: remembers current injuries without warning.
    private func updateInjuries() {
        guard !squad.isEmpty, let league = currentLeague else { return }
        let key = "knownInjured.\(league.id)"
        let current = InjuryAlert.injuredIds(squad)
        guard let stored = UserDefaults.standard.array(forKey: key) as? [String] else {
            UserDefaults.standard.set(Array(current), forKey: key)
            return
        }
        let fresh = InjuryAlert.alerts(squad: squad, knownInjured: Set(stored))
        if Set(stored) != current { UserDefaults.standard.set(Array(current), forKey: key) }
        // Refresh open alerts; drop players no longer injured or no longer in the squad.
        let all = InjuryAlert.alerts(squad: squad, knownInjured: [])
        injuryAlerts = injuryAlerts.compactMap { old in all.first { $0.player.id == old.player.id } }
        if !fresh.isEmpty {
            injuryAlerts += fresh.filter { f in !injuryAlerts.contains { $0.player.id == f.player.id } }
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    func dismissInjury(_ alert: InjuryAlert) {
        injuryAlerts.removeAll { $0.player.id == alert.player.id }
    }

    /// REAL transaction: sells a newly injured player to Kickbase (after confirmation in the UI).
    func sellInjured(_ alert: InjuryAlert) async -> String {
        let check = InjuryAlert.alerts(squad: squad, knownInjured: []).first { $0.player.id == alert.player.id }
        guard let check, check.sellable else {
            return "– \(alert.player.fullName): \(check?.reason ?? "nicht mehr als verletzt gemeldet"), nicht verkauft"
        }
        let log = await executeSales([SaleProposal(
            player: check.player, expectedProceeds: check.proceeds, gainPct: 0, gainBasis: ""
        )])
        dismissInjury(alert)
        return log.joined(separator: "\n")
    }

    // MARK: - Loading

    func refreshAll() async {
        guard let api, let league = currentLeague else { return }
        isLoading = true
        errorMessage = nil
        UserDefaults.standard.set(league.id, forKey: leagueKey)
        let reloadTransfers = transfersLoadedAt != nil
        resetTransfers()
        do {
            async let b = api.budget(league: league.id)
            async let s = api.squad(league: league.id)
            async let m = api.market(league: league.id)
            async let r = api.ranking(league: league.id)
            async let t = api.competitionTable(competitionId: league.competitionId)
            async let md = api.matchdays(competitionId: league.competitionId)
            budget = try await b
            squad = try await s
            market = try await m
            managers = try await r
            if let table = try? await t { teams = table }
            if let days = try? await md { matchdays = days }
            managerSquads = [:]
            lastUpdate = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        if reloadTransfers { await loadTransfers() }
    }

    func refreshMarketAndBudget() async {
        guard let api, let league = currentLeague else { return }
        do {
            async let b = api.budget(league: league.id)
            async let m = api.market(league: league.id)
            budget = try await b
            market = try await m
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadManagerSquad(_ id: String) async {
        guard let api, let league = currentLeague else { return }
        do {
            managerSquads[id] = try await api.managerSquad(league: league.id, userId: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadAllManagerSquads() async {
        for m in managers {
            await loadManagerSquad(m.id)
        }
    }

    func offers(for player: Player) async -> [Offer] {
        guard let api, let league = currentLeague else { return [] }
        return (try? await api.offers(league: league.id, playerId: player.id)) ?? []
    }

    func marketValueHistory(for player: Player) async -> [MVPoint] {
        guard let api, let league = currentLeague else { return [] }
        return (try? await api.marketValueHistory(league: league.id, playerId: player.id)) ?? []
    }

    // MARK: - Transfers (read only)

    private func resetTransfers() {
        transfers = []
        transferEntries = [:]
        transferNextStart = [:]
        transfersLoadedAt = nil
        transfersHaveMore = false
        playerInfo = [:]
        playerInfoFailed = []
        autoPlan = nil
        bidderProfiles = []
        mvHistory = [:]
    }

    /// Loads the newest `pages` pages (25 entries each) of every manager's transfers.
    func loadTransfers(pages: Int = 2) async {
        guard !transfersLoading else { return }
        transferEntries = [:]
        transferNextStart = Dictionary(uniqueKeysWithValues: managers.map { ($0.id, 0) })
        await fetchTransferPages(pages)
    }

    /// Loads further, older pages for managers that have more.
    func loadOlderTransfers(pages: Int = 2) async {
        guard !transfersLoading else { return }
        await fetchTransferPages(pages)
    }

    private func fetchTransferPages(_ pages: Int) async {
        guard let api, let league = currentLeague else { return }
        transfersLoading = true
        let pageSize = Self.transferPageSize
        let pending = transferNextStart
        var failure: String? = nil

        await withTaskGroup(of: (String, [ManagerTransferEntry], Int?, String?).self) { group in
            for (uid, start) in pending {
                group.addTask {
                    var got: [ManagerTransferEntry] = []
                    var next: Int? = start
                    do {
                        for _ in 0..<pages {
                            guard let s = next else { break }
                            let page = try await api.managerTransfers(league: league.id, userId: uid, start: s)
                            got += page
                            next = page.count < pageSize ? nil : s + pageSize
                        }
                        return (uid, got, next, nil)
                    } catch {
                        return (uid, got, next, error.localizedDescription)
                    }
                }
            }
            for await (uid, got, next, err) in group {
                transferEntries[uid, default: []] += got
                transferNextStart[uid] = next
                if let err { failure = err }
            }
        }

        // League switched meanwhile: discard the result.
        guard currentLeague?.id == league.id else {
            transfersLoading = false
            return
        }
        transfers = Transfer.merge(transferEntries.values.flatMap { $0 })
        transfersHaveMore = !transferNextStart.isEmpty
        transfersLoadedAt = Date()
        transfersLoading = false
        if let failure { errorMessage = failure }
    }

    /// Oldest loaded transfer date (for "seit …" hints).
    var transfersOldest: Date? { transfers.last?.date }

    /// Current market value from the freshest source available.
    func currentMarketValue(_ playerId: String) -> Double? {
        if let p = playerInfo[playerId] { return p.marketValue }
        if let p = market.first(where: { $0.id == playerId }) { return p.marketValue }
        if let p = squad.first(where: { $0.id == playerId }) { return p.marketValue }
        for players in managerSquads.values {
            if let p = players.first(where: { $0.id == playerId }) { return p.marketValue }
        }
        return nil
    }

    /// Fetches details for players without a known market value (max. 4 parallel requests).
    func loadPlayerInfo(for ids: [String]) async {
        guard let api, let league = currentLeague else { return }
        let missing = Array(Set(ids)).filter {
            currentMarketValue($0) == nil && !playerInfoFailed.contains($0)
        }
        guard !missing.isEmpty else { return }
        var index = 0
        while index < missing.count {
            let batch = missing[index..<min(index + 4, missing.count)]
            index += 4
            await withTaskGroup(of: (String, Player?).self) { group in
                for id in batch {
                    group.addTask { (id, try? await api.playerDetail(league: league.id, playerId: id)) }
                }
                for await (id, player) in group {
                    if let player { playerInfo[id] = player } else { playerInfoFailed.insert(id) }
                }
            }
            if currentLeague?.id != league.id { return }
        }
    }

    /// Player for the detail sheet: cached data or a fresh detail request.
    func player(forId id: String) async -> Player? {
        if let p = playerInfo[id] { return p }
        if let p = market.first(where: { $0.id == id }) ?? squad.first(where: { $0.id == id }) { return p }
        for players in managerSquads.values {
            if let p = players.first(where: { $0.id == id }) { return p }
        }
        guard let api, let league = currentLeague else { return nil }
        do {
            let p = try await api.playerDetail(league: league.id, playerId: id)
            playerInfo[id] = p
            return p
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func transferStats(period: TransferPeriod) -> [ManagerTransferStats] {
        let inPeriod = transfers.filter { period.contains($0.date) }
        return managers.map { m in
            ManagerTransferStats(
                manager: m,
                isMe: m.id == myUserId,
                transfers: inPeriod,
                all: transfers,
                marketValue: { self.currentMarketValue($0) }
            )
        }
    }

    // MARK: - Transfer automation

    /// Market value histories (365 days), max. 4 parallel requests, cached per session.
    private func loadHistories(_ ids: [String]) async {
        guard let api, let league = currentLeague else { return }
        let missing = Array(Set(ids)).filter { mvHistory[$0] == nil }
        var index = 0
        while index < missing.count {
            let batch = missing[index..<min(index + 4, missing.count)]
            index += 4
            autoStatus = "Marktwertverläufe \(min(index, missing.count))/\(missing.count) …"
            await withTaskGroup(of: (String, [MVPoint]).self) { group in
                for id in batch {
                    group.addTask {
                        let h = (try? await api.marketValueHistory(league: league.id, playerId: id)) ?? []
                        return (id, h.sorted { $0.date < $1.date })
                    }
                }
                for await (id, h) in group { mvHistory[id] = h }
            }
        }
    }

    /// Players on the market that I already bid on (`uop` in the market list).
    private var myOpenBidIds: Set<String> {
        Set(market.filter { $0.myOfferPrice != nil }.map(\.id))
    }

    /// Computes bidder profiles and the current buy/sale plan. Read-only.
    func buildAutoPlan() async {
        guard !autoLoading else { return }
        autoLoading = true
        defer { autoLoading = false; autoStatus = "" }

        autoStatus = "Lade Markt und Kader …"
        await refreshMarketAndBudget()
        if let api, let league = currentLeague, let s = try? await api.squad(league: league.id) { squad = s }
        if transfersLoadedAt == nil {
            autoStatus = "Lade Transfers …"
            await loadTransfers(pages: 4)
        }
        let boughtIds = transfers.filter { $0.buyerId != nil }.map(\.playerId)
        await loadHistories(boughtIds + market.map(\.id) + squad.map(\.id))

        let openBids = myOpenBidIds

        bidderProfiles = managers.map { BidderProfile(manager: $0, transfers: transfers, history: mvHistory) }
        autoPlan = AutoPlanner.plan(
            budget: budget,
            squad: squad,
            market: market,
            myUserId: myUserId,
            transfers: transfers,
            profiles: bidderProfiles,
            history: mvHistory,
            openBidPlayerIds: openBids
        )
    }

    /// REAL transactions: places the given bids one after another. Returns a log.
    func executeBuys(_ buys: [BuyProposal]) async -> [String] {
        var log: [String] = []
        for b in buys {
            if let err = await placeOffer(b.player, price: Int(b.bid.rounded())) {
                log.append("✗ \(b.player.fullName): \(err)")
            } else {
                log.append("✓ Gebot \(Fmt.eur(b.bid)) für \(b.player.fullName)")
            }
        }
        return log
    }

    /// REAL transaction: withdraws my bid on a market player.
    /// Kickbase exposes no offer id; the market list only carries my user id (`uoid`) in
    /// the offer, so the user id is used as offer id (confirmed working, see CLAUDE.md).
    func withdrawMyBid(_ player: Player) async -> String {
        guard let api, let league = currentLeague, !myUserId.isEmpty else { return "Nicht angemeldet." }
        do {
            try await api.withdrawOffer(league: league.id, playerId: player.id, offerId: myUserId)
            await refreshMarketAndBudget()
            if market.first(where: { $0.id == player.id })?.myOfferPrice != nil {
                return "⚠︎ Kickbase hat geantwortet, dein Gebot auf \(player.fullName) steht aber noch auf dem Markt."
            }
            return "✓ Gebot auf \(player.fullName) zurückgezogen"
        } catch {
            return "✗ Zurückziehen bei \(player.fullName) fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// REAL transactions: lists each player and accepts Kickbase's instant offer.
    func executeSales(_ sales: [SaleProposal]) async -> [String] {
        guard let api, let league = currentLeague else { return ["Nicht angemeldet."] }
        var log: [String] = []
        for s in sales {
            do {
                if !s.player.onMarket {
                    try await api.listForSale(
                        league: league.id, playerId: s.player.id, price: Int(s.player.marketValue.rounded())
                    )
                }
                try await api.sellToKickbase(league: league.id, playerId: s.player.id)
                log.append("✓ \(s.player.fullName) an Kickbase verkauft")
            } catch {
                log.append("✗ \(s.player.fullName): \(error.localizedDescription)")
            }
        }
        do {
            async let b = api.budget(league: league.id)
            async let q = api.squad(league: league.id)
            budget = try await b
            squad = try await q
        } catch {
            log.append("Budget/Kader konnten nicht neu geladen werden: \(error.localizedDescription)")
        }
        return log
    }

    /// Recomputes the plan every 15 minutes while enabled. Never executes anything.
    private func restartAutoLoop() {
        autoLoop?.cancel()
        guard autoRefreshEnabled else { return }
        autoLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self, self.isLoggedIn else { continue }
                await self.buildAutoPlan()
                self.checkDeadline()
            }
        }
    }

    /// Checks every 5 minutes whether the budget must be balanced soon.
    func startDeadlineWatch() {
        deadlineWatch?.cancel()
        deadlineWatch = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkDeadline()
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            }
        }
    }

    private func checkDeadline() {
        let hours = AutoRules.nextDeadline().timeIntervalSinceNow / 3600
        let alert = isLoggedIn && budget < 0 && hours <= AutoRules.deadlineWarningHours
        if alert && !deadlineAlert {
            NSApp.requestUserAttention(.criticalRequest)
        }
        deadlineAlert = alert
    }

    // MARK: - Transactions (REAL)

    /// Returns nil on success, otherwise an error message.
    func placeOffer(_ player: Player, price: Int) async -> String? {
        guard let api, let league = currentLeague else { return "Nicht angemeldet." }
        do {
            try await api.placeOffer(league: league.id, playerId: player.id, price: price)
            await refreshMarketAndBudget()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func withdrawOffer(_ player: Player, offer: Offer) async -> String? {
        guard let api, let league = currentLeague else { return "Nicht angemeldet." }
        do {
            try await api.withdrawOffer(league: league.id, playerId: player.id, offerId: offer.id)
            await refreshMarketAndBudget()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Lookups

    func teamName(_ id: String) -> String {
        if let t = teams[id] { return t.name }
        return id.isEmpty ? "–" : "#\(id)"
    }

    /// Manager name for a transfer party; nil = Kickbase.
    func partyName(_ id: String?) -> String {
        guard let id else { return "Kickbase" }
        guard let m = managers.first(where: { $0.id == id }) else { return "Manager" }
        return m.id == myUserId ? "\(m.name) (du)" : m.name
    }

    func sellerName(_ p: Player) -> String {
        guard let id = p.sellerUserId else { return "Kickbase" }
        return managers.first(where: { $0.id == id })?.name ?? "Manager"
    }
}
