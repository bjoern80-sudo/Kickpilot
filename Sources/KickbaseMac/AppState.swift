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
    @Published var squad: [Player] = []
    @Published var market: [Player] = []
    @Published var managers: [Manager] = []
    @Published var teams: [String: Team] = [:]
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
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
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
            budget = try await b
            squad = try await s
            market = try await m
            managers = try await r
            if let table = try? await t { teams = table }
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
