import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .task { await state.tryAutoLogin() }
    }
}

struct LoginView: View {
    @EnvironmentObject var state: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "soccerball")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("Kickbase").font(.largeTitle.bold())

            Form {
                TextField("E-Mail", text: $email)
                SecureField("Passwort", text: $password)
                Toggle("Im Schlüsselbund merken", isOn: $remember)
            }
            .formStyle(.grouped)
            .frame(width: 380, height: 170)

            if let error = state.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 380)
            }

            Button {
                Task { await state.login(email: email, password: password, remember: remember) }
            } label: {
                if state.isLoading {
                    ProgressView().controlSize(.small).frame(width: 120)
                } else {
                    Text("Anmelden").frame(width: 120)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(email.isEmpty || password.isEmpty || state.isLoading)

            Text("„Mit Apple anmelden“ funktioniert hier nicht – nutze dein Kickbase-Passwort.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if email.isEmpty { email = state.savedEmail } }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case team = "Mein Team"
    case market = "Transfermarkt"
    case league = "Liga"
    case transfers = "Transfers"
    case auto = "Automatik"
    case analysis = "Kader-Analyse"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .team: return "person.3.fill"
        case .market: return "cart.fill"
        case .league: return "list.number"
        case .transfers: return "arrow.left.arrow.right"
        case .auto: return "wand.and.stars"
        case .analysis: return "chart.bar.xaxis"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: SidebarItem? = .team
    @State private var analysisManagerId: String? = nil

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .badge(item == .auto && state.deadlineAlert ? "!" : nil)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if !state.userName.isEmpty {
                        Label(state.userName, systemImage: "person.crop.circle")
                            .font(.callout)
                    }
                    if let date = state.lastUpdate {
                        Text("Stand: \(date.formatted(date: .omitted, time: .shortened)) Uhr")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button("Abmelden") { state.logout() }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            switch selection ?? .team {
            case .team:
                TeamView()
            case .market:
                MarketView()
            case .league:
                LeagueView { id in
                    analysisManagerId = id
                    selection = .analysis
                }
            case .transfers:
                TransfersView()
            case .auto:
                AutoTransferView()
            case .analysis:
                AnalysisView(selectedManagerId: $analysisManagerId)
            }
        }
        .navigationTitle(state.currentLeague?.name ?? "Kickbase")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if state.leagues.count > 1 {
                    Picker("Liga", selection: $state.selectedLeagueId) {
                        ForEach(state.leagues) { league in
                            Text(league.name).tag(Optional(league.id))
                        }
                    }
                    .frame(width: 200)
                }
                Text("Budget: \(Fmt.eur(state.budget))")
                    .monospacedDigit()
                    .foregroundColor(state.budget < 0 ? .red : .primary)
                if state.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await state.refreshAll() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(state.isLoading)
            }
        }
        .alert(
            "Fehler",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}
