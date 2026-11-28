import AppKit
import SwiftUI

// Kickpilot design system: native macOS surfaces, brand navy/gold from the logo,
// semantic colors with ≥ 4.5:1 text contrast, club colors as the only loud element.

extension Color {
    // MARK: Brand (logo: branding/generate_logo.py)

    /// Logo navy – headings on light surfaces, pitch frame.
    static let brandNavy = Color(hex: 0x13203B)
    /// Gold for fills and controls (white text on it ≥ 4.5:1).
    static let brand = Color(hex: 0xB35C0B)
    /// Gold for text and icons (readable in light and dark mode).
    static let brandText = adaptive(light: 0x9A4F09, dark: 0xFFC03D)

    // MARK: Semantic

    /// Gain, rising value, everything ok.
    static let gain = adaptive(light: 0x1A7F37, dark: 0x30D158)
    /// Loss, error, not fit.
    static let loss = adaptive(light: 0xC4281C, dark: 0xFF6961)
    /// Warning, overpay, expiring soon.
    static let warn = adaptive(light: 0x9A5B00, dark: 0xFFB340)
    /// Neutral hint (e.g. "nach Stichtag").
    static let info = adaptive(light: 0x0A5FC2, dark: 0x64A8FF)
    /// Trend reversal pattern.
    static let reversal = adaptive(light: 0x7B3FC4, dark: 0xC38BFF)

    // MARK: Surfaces

    /// Page background behind cards.
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    /// Card surface.
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Theme {
    /// Background tint for banners and badges.
    static let subtleFill = 0.10
    static let strongFill = 0.16
    /// Spacing scale.
    static let gap: CGFloat = 12
    static let pagePadding: CGFloat = 20
    static let cardRadius: CGFloat = 12
    /// Table metrics for tables that are sized to their content.
    static let tableRowHeight: CGFloat = 30
    static let tableHeaderHeight: CGFloat = 44

    /// Green / red / secondary by sign.
    static func signColor(_ v: Double) -> Color {
        v > 0 ? .gain : (v < 0 ? .loss : .secondary)
    }

    /// Position colors (same hues as the HA card), darker in light mode for contrast.
    static func positionColor(_ pos: Int) -> Color {
        switch pos {
        case 1: return .adaptive(light: 0xB45309, dark: 0xF59E0B) // TW
        case 2: return .adaptive(light: 0x1D4ED8, dark: 0x60A5FA) // ABW
        case 3: return .adaptive(light: 0x6D28D9, dark: 0xA78BFA) // MIT
        case 4: return .adaptive(light: 0xB91C1C, dark: 0xF87171) // ST
        default: return .secondary
        }
    }

    /// Big numbers: SF Pro Rounded, tabular digits.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

extension View {
    /// Height that shows all rows of a Table without clipping (optionally capped).
    func fittedTableHeight(rows: Int, max cap: CGFloat? = nil) -> some View {
        let h = CGFloat(Swift.max(rows, 1)) * Theme.tableRowHeight + Theme.tableHeaderHeight
        return frame(height: cap.map { Swift.min(h, $0) } ?? h)
    }

    /// Card surface: hairline border, no shadow.
    func cardSurface(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            )
    }

    /// Tinted banner surface (warnings, hints).
    func bannerSurface(_ tint: Color) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(Theme.subtleFill), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
            )
    }
}

/// Page frame: title, subtitle, trailing controls, content on the page background.
struct Page<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var scrolls = false
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 12)
                trailing()
            }
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content() }
                        .padding(.bottom, Theme.pagePadding)
                }
            } else {
                content()
            }
        }
        .padding([.horizontal, .top], Theme.pagePadding)
        .padding(.bottom, scrolls ? 0 : Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.pageBackground)
    }
}

extension Page where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, scrolls: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, trailing: { EmptyView() }, content: content)
    }
}

/// Section card with title, optional explanation (info popover) and trailing actions.
struct Card<Actions: View, Content: View>: View {
    let title: String
    var detail: String? = nil
    var info: String? = nil
    var padding: CGFloat = 14
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.callout).foregroundColor(.secondary).lineLimit(1)
                }
                if let info { InfoButton(text: info) }
                Spacer(minLength: 8)
                actions()
            }
            // Edge-to-edge content (tables): keep the header inset anyway.
            .padding(.horizontal, padding == 0 ? 14 : 0)
            .padding(.top, padding == 0 ? 12 : 0)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: padding)
    }
}

extension Card where Actions == EmptyView {
    init(title: String, detail: String? = nil, info: String? = nil, padding: CGFloat = 14,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, detail: detail, info: info, padding: padding, actions: { EmptyView() }, content: content)
    }
}

/// ⓘ button with an explanation popover (replaces long caption lines).
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundColor(.secondary)
        .help(text)
        .accessibilityLabel("Erklärung")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(14)
        }
    }
}

/// Small capsule label that never truncates; the long text goes into tooltip and VoiceOver.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var help: String? = nil

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(Theme.strongFill), in: Capsule())
            .help(help ?? text)
            .accessibilityLabel(help ?? text)
    }
}

/// TW / ABW / MIT / ST in the position color.
struct PositionChip: View {
    let position: Int

    private var label: String {
        switch position {
        case 1: return "TW"
        case 2: return "ABW"
        case 3: return "MIT"
        case 4: return "ST"
        default: return "?"
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(Theme.positionColor(position))
            .frame(width: 32, height: 16)
            .background(Theme.positionColor(position).opacity(Theme.strongFill), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(["", "Torwart", "Abwehr", "Mittelfeld", "Sturm"][min(max(position, 0), 4)])
    }
}

/// App emblem (football with wings) from the app bundle; SF Symbol when run via `swift run`.
struct Emblem: View {
    var size: CGFloat = 28

    var body: some View {
        if let url = Bundle.main.url(forResource: "Emblem", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "soccerball").font(.system(size: size * 0.8)).foregroundColor(.brandText)
                .frame(width: size, height: size)
        }
    }
}
