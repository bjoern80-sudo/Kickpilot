import Foundation

/// Client for the unofficial Kickbase API v4 (endpoints as in behretv/kickbase-mcp).
/// Talks only to api.kickbase.com. Auth: POST /v4/user/login returns a token
/// that is sent as the `kkstrauth` cookie.
actor KickbaseAPI {
    enum APIError: LocalizedError {
        case invalidCredentials
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Anmeldung fehlgeschlagen – E-Mail oder Passwort falsch."
            case .http(let code, let msg):
                return "Kickbase-Fehler (HTTP \(code)): \(msg)"
            case .invalidResponse:
                return "Unerwartete Antwort von Kickbase."
            }
        }
    }

    private let baseURL = "https://api.kickbase.com"
    private let session: URLSession
    private let email: String
    private let password: String
    private var token: String?
    private var tokenExpiry: Date?

    private(set) var userId = ""
    private(set) var userName = ""

    init(email: String, password: String) {
        self.email = email
        self.password = password
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Auth

    func login() async throws {
        guard let url = URL(string: baseURL + "/v4/user/login") else { throw APIError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: JSONObject = ["em": email, "loy": false, "pass": password, "rep": JSONObject()]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.invalidCredentials }
        guard code == 200 else { throw APIError.http(code, Self.snippet(data)) }
        guard let j = try JSONSerialization.jsonObject(with: data) as? JSONObject,
              let tkn = J.str(j["tkn"]) else {
            throw APIError.invalidResponse
        }
        token = tkn
        tokenExpiry = Self.parseDate(J.str(j["tknex"]))
        let u = J.obj(j["u"]) ?? [:]
        userId = J.str(u["id"]) ?? J.str(u["i"]) ?? ""
        userName = J.str(u["name"]) ?? J.str(u["n"]) ?? ""
    }

    private var tokenValid: Bool {
        guard token != nil else { return false }
        guard let tokenExpiry else { return true }
        return tokenExpiry > Date().addingTimeInterval(3600)
    }

    // MARK: - Request core

    private func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: JSONObject? = nil,
        retry: Bool = true
    ) async throws -> Any? {
        if !tokenValid { try await login() }

        guard var comps = URLComponents(string: baseURL + path) else { throw APIError.invalidResponse }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.invalidResponse }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("kkstrauth=\(token ?? "")", forHTTPHeaderField: "Cookie")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && retry {
            token = nil
            return try await request(method, path, query: query, body: body, retry: false)
        }
        guard code == 200 || code == 201 else { throw APIError.http(code, Self.snippet(data)) }
        if data.isEmpty { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func getObject(_ path: String, query: [String: String] = [:]) async throws -> JSONObject {
        (try await request("GET", path, query: query) as? JSONObject) ?? [:]
    }

    // MARK: - Read

    func leagues() async throws -> [League] {
        let j = try await getObject("/v4/leagues/selection")
        return J.arr(j["it"]).map { League(json: $0) }
    }

    func budget(league: String) async throws -> Double {
        let j = try await getObject("/v4/leagues/\(league)/me/budget")
        return J.dbl(j["b"]) ?? 0
    }

    func squad(league: String) async throws -> [Player] {
        let j = try await getObject("/v4/leagues/\(league)/squad")
        let now = Date()
        return J.arr(j["it"]).map { Player(json: $0, fetchedAt: now) }
    }

    func market(league: String) async throws -> [Player] {
        let j = try await getObject("/v4/leagues/\(league)/market")
        let now = Date()
        return J.arr(j["it"]).map { Player(json: $0, fetchedAt: now) }
    }

    func ranking(league: String) async throws -> [Manager] {
        let j = try await getObject("/v4/leagues/\(league)/ranking")
        return J.arr(j["us"]).map { Manager(json: $0) }.sorted { $0.placement < $1.placement }
    }

    func managerSquad(league: String, userId: String) async throws -> [Player] {
        let j = try await getObject("/v4/leagues/\(league)/managers/\(userId)/squad")
        let now = Date()
        return J.arr(j["it"]).map { Player(json: $0, fetchedAt: now) }
    }

    func offers(league: String, playerId: String) async throws -> [Offer] {
        let j = try await getObject("/v4/leagues/\(league)/market/\(playerId)")
        var raw = J.arr(j["ofs"])
        if raw.isEmpty { raw = J.arr(j["it"]) }
        return raw.map { Offer(json: $0) }
    }

    func competitionTable(competitionId: String) async throws -> [String: Team] {
        let j = try await getObject("/v4/competitions/\(competitionId)/table")
        let v = J.obj(j["value"]) ?? j
        var out: [String: Team] = [:]
        for row in J.arr(v["it"]) {
            guard let tid = J.str(row["tid"]) else { continue }
            out[tid] = Team(id: tid, name: J.str(row["tn"]) ?? tid, placement: J.int(row["cp"]) ?? 0)
        }
        return out
    }

    /// Only timeframe 365 returns data. Entries: {dt: days since epoch, mv}.
    func marketValueHistory(league: String, playerId: String) async throws -> [MVPoint] {
        let j = try await getObject("/v4/leagues/\(league)/players/\(playerId)/marketvalue/365")
        return J.arr(j["it"]).compactMap { e in
            guard let dt = J.dbl(e["dt"]), let mv = J.dbl(e["mv"]), mv > 0 else { return nil }
            return MVPoint(date: Date(timeIntervalSince1970: dt * 86_400), value: mv)
        }
    }

    /// Detail data of a single player (current market value etc.).
    func playerDetail(league: String, playerId: String) async throws -> Player {
        let j = try await getObject("/v4/leagues/\(league)/players/\(playerId)")
        return Player(json: j)
    }

    /// One page (25 entries) of a manager's transfers, newest first.
    /// Entries: {dt, pi, pn, tid, trp, tty} – tty 1 = buy, 2 = sale.
    func managerTransfers(league: String, userId: String, start: Int) async throws -> [ManagerTransferEntry] {
        let j = try await getObject(
            "/v4/leagues/\(league)/managers/\(userId)/transfer",
            query: ["start": String(start)]
        )
        return J.arr(j["it"]).compactMap { ManagerTransferEntry(json: $0, userId: userId) }
    }

    // MARK: - Write (REAL transactions)

    func placeOffer(league: String, playerId: String, price: Int) async throws {
        _ = try await request("POST", "/v4/leagues/\(league)/market/\(playerId)/offers", body: ["price": price])
    }

    func withdrawOffer(league: String, playerId: String, offerId: String) async throws {
        _ = try await request("DELETE", "/v4/leagues/\(league)/market/\(playerId)/offers/\(offerId)")
    }

    // MARK: - Helpers

    private static func snippet(_ data: Data) -> String {
        String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
