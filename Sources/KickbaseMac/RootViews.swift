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
            Emblem(size: 96)
            VStack(spacing: 4) {
                Wordmark(size: 34)
                Text("Dein Kickbase-Begleiter für den Mac")
                    .foregroundColor(.secondary)
            }

            Form {
                TextField("E-Mail", text: $email)
                SecureField("Passwort", text: $password)
                Toggle("Im Schlüsselbund merken", isOn: $remember)
            }
            .formStyle(.grouped)
            .frame(width: 380, height: 170)

            if let error = state.errorMessage {
                Text(error)
                    .foregroundColor(.loss)
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

            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("„Mit Apple anmelden“ funktioniert hier nicht – nutze dein Kickbase-Passwort.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pageBackground)
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

    private func badge(for item: SidebarItem) -> Text? {
        switch item {
        case .auto where state.deadlineAlert: return Text("Frist")
        case .team where !(state.lineupCheck?.problems.isEmpty ?? true):
            return Text("\(state.lineupCheck?.problems.count ?? 0)")
        default: return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Emblem(size: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Wordmark(size: 17)
                        if let league = state.currentLeague?.name {
                            Text(league).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Text(String(state.userName.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.brandNavy))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.userName.isEmpty ? "Angemeldet" : state.userName)
                            .font(.callout.weight(.medium)).lineLimit(1)
                        if let date = state.lastUpdate {
                            Text("Stand \(date.formatted(date: .omitted, time: .shortened)) Uhr")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        state.logout()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Abmelden")
                    .accessibilityLabel("Abmelden")
                }
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
        .navigationTitle("")
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
                Label(Fmt.eur(state.budget), systemImage: "eurosign.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundColor(state.budget < 0 ? .loss : .primary)
                    .help("Budget")
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

/// "Kickpilot" wordmark: "Kick" in the text color, "pilot" in brand gold (as in the logo).
struct Wordmark: View {
    var size: CGFloat = 17

    var body: some View {
        (Text("Kick").foregroundColor(.primary) + Text("pilot").foregroundColor(.brandText))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .accessibilityLabel("Kickpilot")
    }
}
