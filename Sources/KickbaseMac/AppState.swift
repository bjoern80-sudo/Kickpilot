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
    }

    // MARK: - Loading

    func refreshAll() async {
        guard let api, let league = currentLeague else { return }
        isLoading = true
        errorMessage = nil
        UserDefaults.standard.set(league.id, forKey: leagueKey)
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

    func sellerName(_ p: Player) -> String {
        guard let id = p.sellerUserId else { return "Kickbase" }
        return managers.first(where: { $0.id == id })?.name ?? "Manager"
    }
}
