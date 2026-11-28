import SwiftUI

/// Club abbreviation + colors as a simple pattern (no logos – copyright).
/// Same table as `CLUBS` in `custom_components/kickbase/frontend/kickpilot-card.js`.
struct Club {
    enum Pattern {
        /// Two halves; `angle` like CSS linear-gradient (90 = left→right, 180 = top→bottom).
        case half(Color, Color, angle: Double)
        case tri(Color, Color, Color, angle: Double)
        case stripes(Color, Color, angle: Double)
        /// Outer color, band of the second color in the middle.
        case band(Color, Color, angle: Double)
        case ring(inner: Color, outer: Color)
        case quarters(Color, Color)
    }

    let abbr: String
    let pattern: Pattern
    let name: String

    private static let w = Color.white
    private static let k = Color(hex: 0x111111)

    private static let table: [String: (String, Pattern)] = [
        // Rot-Weiß
        "Bayern": ("FCB", .quarters(Color(hex: 0xDC052D), w)),
        "Stuttgart": ("VfB", .band(w, Color(hex: 0xE32219), angle: 180)),
        "Köln": ("KOE", .half(w, Color(hex: 0xED1C24), angle: 180)),
        "Union Berlin": ("FCU", .stripes(Color(hex: 0xD4011D), w, angle: 90)),
        "Mainz": ("M05", .half(Color(hex: 0xC3141E), w, angle: 135)),
        "Leipzig": ("RBL", .ring(inner: w, outer: Color(hex: 0xDD0741))),
        // Rot-Schwarz
        "Leverkusen": ("B04", .half(k, Color(hex: 0xE32221), angle: 90)),
        "Frankfurt": ("SGE", .half(k, Color(hex: 0xE1000F), angle: 180)),
        "Freiburg": ("SCF", .stripes(Color(hex: 0xE2001A), k, angle: 180)),
        // Blau
        "Hoffenheim": ("TSG", .half(Color(hex: 0x1C63B7), w, angle: 90)),
        "Schalke": ("S04", .half(Color(hex: 0x004D9D), w, angle: 180)),
        "Hamburg": ("HSV", .tri(Color(hex: 0x0A3F86), w, k, angle: 180)),
        "Paderborn": ("SCP", .stripes(Color(hex: 0x005CA9), k, angle: 90)),
        // Schwarz-Weiß und eindeutige Farben
        "Elversberg": ("SVE", .half(k, w, angle: 135)),
        "M'gladbach": ("BMG", .tri(k, w, Color(hex: 0x00915A), angle: 90)),
        "Dortmund": ("BVB", .half(Color(hex: 0xFDE100), k, angle: 90)),
        "Bremen": ("SVW", .half(Color(hex: 0x1D9053), w, angle: 90)),
        "Augsburg": ("FCA", .tri(Color(hex: 0xBA3733), w, Color(hex: 0x46714D), angle: 90)),
        // Mögliche Aufsteiger späterer Saisons
        "Wolfsburg": ("WOB", .ring(inner: w, outer: Color(hex: 0x65B32E))),
        "Heidenheim": ("FCH", .half(Color(hex: 0xE30613), Color(hex: 0x003B79), angle: 90)),
        "St. Pauli": ("STP", .half(Color(hex: 0x5C3A21), w, angle: 90)),
        "Bochum": ("BOC", .half(Color(hex: 0x005CA9), w, angle: 135)),
        "Kiel": ("KSV", .tri(Color(hex: 0x00438A), w, Color(hex: 0xE3001B), angle: 180)),
        "Hertha": ("BSC", .stripes(Color(hex: 0x005CA9), w, angle: 180)),
        "Darmstadt": ("SVD", .quarters(Color(hex: 0x004E9E), w)),
        "Düsseldorf": ("F95", .band(w, Color(hex: 0xE2001A), angle: 135)),
    ]

    static func named(_ name: String) -> Club {
        if let (abbr, pattern) = table[name] {
            return Club(abbr: abbr, pattern: pattern, name: name)
        }
        let letters = name.filter(\.isLetter).prefix(3).uppercased()
        return Club(
            abbr: letters.isEmpty ? "?" : letters,
            pattern: .half(Color(hex: 0x6B7280), Color(hex: 0x9CA3AF), angle: 90),
            name: name.isEmpty ? "unbekannter Verein" : name
        )
    }
}

/// Round club crest in the club colors.
struct ClubCrest: View {
    let club: Club
    var size: CGFloat = 16

    var body: some View {
        fill
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
            .help(club.name)
            .accessibilityLabel(club.name)
    }

    @ViewBuilder
    private var fill: some View {
        switch club.pattern {
        case let .half(a, b, angle):
            linear([(a, 0), (a, 0.5), (b, 0.5), (b, 1)], angle)
        case let .tri(a, b, c, angle):
            linear([(a, 0), (a, 0.333), (b, 0.333), (b, 0.666), (c, 0.666), (c, 1)], angle)
        case let .stripes(a, b, angle):
            linear([(a, 0), (a, 0.25), (b, 0.25), (b, 0.5), (a, 0.5), (a, 0.75), (b, 0.75), (b, 1)], angle)
        case let .band(a, b, angle):
            linear([(a, 0), (a, 0.38), (b, 0.38), (b, 0.62), (a, 0.62), (a, 1)], angle)
        case let .ring(inner, outer):
            RadialGradient(
                gradient: Gradient(stops: [.init(color: inner, location: 0), .init(color: inner, location: 0.5),
                                           .init(color: outer, location: 0.53), .init(color: outer, location: 1)]),
                center: .center, startRadius: 0, endRadius: size * 0.707
            )
        case let .quarters(a, b):
            AngularGradient(
                gradient: Gradient(stops: [.init(color: a, location: 0), .init(color: a, location: 0.25),
                                           .init(color: b, location: 0.25), .init(color: b, location: 0.5),
                                           .init(color: a, location: 0.5), .init(color: a, location: 0.75),
                                           .init(color: b, location: 0.75), .init(color: b, location: 1)]),
                center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
            )
        }
    }

    /// Hard-stop gradient; `angle` in CSS convention (0 = to top, 90 = to right).
    private func linear(_ stops: [(Color, Double)], _ angle: Double) -> LinearGradient {
        let r = angle * .pi / 180
        let dx = sin(r) / 2, dy = -cos(r) / 2
        return LinearGradient(
            gradient: Gradient(stops: stops.map { .init(color: $0.0, location: $0.1) }),
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }
}

/// Crest + club name for table cells.
struct ClubCell: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            ClubCrest(club: .named(name), size: 14)
            Text(name).lineLimit(1)
        }
    }
}
