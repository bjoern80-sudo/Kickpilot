import SwiftUI

/// Starting eleven as a formation on a pitch, bench below. Read-only – the lineup is
/// changed in the Kickbase app. Problems from the lineup guard are marked on the player.
struct PitchCard: View {
    @EnvironmentObject var state: AppState
    let squad: [Player]
    let check: LineupCheck?
    var onOpen: (Player) -> Void

    private var starters: [Player] { squad.filter { $0.lineupSlot != nil } }
    private var bench: [Player] {
        squad.filter { $0.lineupSlot == nil }.sorted {
            ($0.position, -$0.averagePoints) < ($1.position, -$1.averagePoints)
        }
    }

    /// "3-4-3": defenders-midfielders-strikers of the starting eleven.
    private var formation: String {
        (2...4).map { pos in "\(starters.filter { $0.position == pos }.count)" }.joined(separator: "-")
    }

    private var problemIds: Set<String> { Set(check?.problems.compactMap { $0.player?.id } ?? []) }
    private var tipIds: Set<String> { Set(check?.tips.compactMap { $0.player?.id } ?? []) }

    var body: some View {
        Card(title: "Startelf", detail: starters.isEmpty ? nil : formation, info: Self.info) {
            status
        } content: {
            Pitch(rows: rows, problemIds: problemIds, tipIds: tipIds, teamName: state.teamName, onOpen: onOpen)
                .aspectRatio(0.78, contentMode: .fit)
            if !bench.isEmpty {
                Text("Bank").font(.subheadline.weight(.semibold)).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(bench) { p in
                        BenchRow(player: p, club: state.teamName(p.teamId))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onOpen(p) }
                        if p.id != bench.last?.id { Divider() }
                    }
                }
            }
        }
    }

    /// Strikers at the top, goalkeeper at the bottom; within a row sorted by lineup slot.
    private var rows: [[Player]] {
        [4, 3, 2, 1].map { pos in
            starters.filter { $0.position == pos }.sorted { ($0.lineupSlot ?? 0) < ($1.lineupSlot ?? 0) }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let check {
            if check.lockAt == nil {
                Label("gesperrt", systemImage: "lock.fill").foregroundColor(.secondary)
                    .help("Spieltag \(check.matchday ?? 0) läuft – die Aufstellung gilt bis zum Ende des Spieltags")
            } else if check.problems.isEmpty {
                Label("ok", systemImage: "checkmark.circle.fill").foregroundColor(.gain)
            } else {
                Label("\(check.problems.count) prüfen", systemImage: "exclamationmark.triangle.fill").foregroundColor(.loss)
            }
        }
    }

    static let info = "Deine aktuelle Startelf aus Kickbase. Rot markiert: nicht fit oder Verein ohne Spiel. Gold markiert: auf der Bank sitzt ein deutlich stärkerer Spieler (≥ 20 Ø-Punkte mehr). Die Aufstellung muss vor dem ersten Anpfiff des Spieltags stehen und wird in der Kickbase-App geändert – Kickpilot ändert sie nie selbst. Doppelklick öffnet die Spielerdetails."
}

/// The drawn pitch with player tokens.
private struct Pitch: View {
    let rows: [[Player]]
    let problemIds: Set<String>
    let tipIds: Set<String>
    let teamName: (String) -> String
    var onOpen: (Player) -> Void

    private static let grassA = Color(hex: 0x2E6B3D)
    private static let grassB = Color(hex: 0x337544)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Mown stripes
                VStack(spacing: 0) {
                    ForEach(0..<8) { i in
                        (i.isMultiple(of: 2) ? Self.grassA : Self.grassB)
                    }
                }
                PitchLines().stroke(Color.white.opacity(0.55), lineWidth: 1.2)
                    .padding(10)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(row) { p in
                                PlayerToken(
                                    player: p,
                                    club: teamName(p.teamId),
                                    mark: problemIds.contains(p.id) ? .problem : (tipIds.contains(p.id) ? .tip : nil)
                                )
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onOpen(p) }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 6)
                if rows.allSatisfy(\.isEmpty) {
                    Text("Keine Startelf gesetzt").font(.callout.weight(.semibold)).foregroundColor(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// Outline, halfway line, centre circle and both penalty areas.
private struct PitchLines: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRect(r)
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        let c = r.width * 0.14
        p.addEllipse(in: CGRect(x: r.midX - c, y: r.midY - c, width: 2 * c, height: 2 * c))
        let bw = r.width * 0.56, bh = r.height * 0.14
        let sw = r.width * 0.26, sh = r.height * 0.05
        p.addRect(CGRect(x: r.midX - bw / 2, y: r.minY, width: bw, height: bh))
        p.addRect(CGRect(x: r.midX - sw / 2, y: r.minY, width: sw, height: sh))
        p.addRect(CGRect(x: r.midX - bw / 2, y: r.maxY - bh, width: bw, height: bh))
        p.addRect(CGRect(x: r.midX - sw / 2, y: r.maxY - sh, width: sw, height: sh))
        return p
    }
}

private struct PlayerToken: View {
    enum Mark { case problem, tip }
    let player: Player
    let club: String
    let mark: Mark?

    private var ring: Color {
        switch mark {
        case .problem: return Color(hex: 0xFF5A4E)
        case .tip: return Color(hex: 0xFFC03D)
        case nil: return .white
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                ClubCrest(club: .named(club), size: 30)
                    .overlay(Circle().strokeBorder(ring, lineWidth: mark == nil ? 1.5 : 2.5))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                if mark == .problem {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white, Color(hex: 0xD93025))
                        .offset(x: 5, y: -4)
                }
            }
            Text(player.lastName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.35), in: Capsule())
            Text("Ø \(Int(player.averagePoints.rounded()))")
                .font(Theme.number(10, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        var s = "\(player.fullName), \(player.positionName), \(club), Ø \(Int(player.averagePoints.rounded())) Punkte"
        if !player.isFit { s += ", \(player.statusText)" }
        switch mark {
        case .problem: s += " – Aufstellung prüfen"
        case .tip: s += " – stärkerer Spieler auf der Bank"
        case nil: break
        }
        return s
    }
}

private struct BenchRow: View {
    let player: Player
    let club: String

    var body: some View {
        HStack(spacing: 8) {
            PositionChip(position: player.position)
            ClubCrest(club: .named(club), size: 14)
            Text(player.lastName).lineLimit(1)
            if !player.isFit {
                Badge(text: player.statusShort, color: .loss, help: player.statusText)
            }
            Spacer(minLength: 4)
            Text("Ø \(Int(player.averagePoints.rounded()))")
                .font(Theme.number(12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 5)
    }
}
