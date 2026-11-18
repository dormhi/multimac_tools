import SwiftUI
import AppKit

// MARK: - Renkler

extension CleanupCategory {
    var color: Color {
        switch self {
        case .appCaches: .blue
        case .devCaches: .purple
        case .buildArtifacts: .orange
        case .xcode: .cyan
        case .logs: .gray
        case .downloads: .green
        case .largeFiles: .pink
        case .trash: .brown
        }
    }
}

extension MainTab {
    var color: Color {
        switch self {
        case .overview: .indigo
        case .cleanup: .green
        case .storage: .orange
        case .memory: .blue
        case .automation: .purple
        case .settings: .gray
        }
    }
}

// MARK: - Tema

/// Açık / koyu / sistem görünümü. Menü çubuğu paneli dahil tüm pencerelere uygulanır.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("Sistem", "System")
        case .light: L("Açık", "Light")
        case .dark: L("Koyu", "Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: Prefs.appearance) ?? "") ?? .system
    }

    @MainActor static func apply(_ value: AppAppearance = current) {
        switch value {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Kart

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Gölge yok: kaydırırken her karede yeniden hesaplanması akıcılığı düşürüyordu.
            // Cam hissi: düz yüzey + üstten alta sönen ince parlak kenar.
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Surface.edge, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }

    /// Tıklanabilir alanlar için: üzerine gelince hafif vurgu ve el imleci.
    func hoverHighlight(cornerRadius: CGFloat = 8) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius)) }
}

struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
    }
}

/// Ortak yüzey renkleri: açık ve koyu temada Apple'ın sistem tonları.
enum Surface {
    /// Kart zemini: açıkta beyaz, koyuda pencereden bir ton açık.
    static let card = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 1, alpha: 0.82)
    })
    /// Kartın camsı kenarı: üstte daha parlak, altta söner.
    static var edge: LinearGradient {
        LinearGradient(colors: [Color.primary.opacity(0.13), Color.primary.opacity(0.04)],
                       startPoint: .top, endPoint: .bottom)
    }
    /// İç gruplar (liste satırları, önizleme kutuları) için hafif dolgu.
    static let inset = Color.primary.opacity(0.045)
}

/// Yumuşak renkli zemin üzerinde SF Symbol (Apple'ın "tinted" ikon stili).
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(color.opacity(0.15))
            )
    }
}

// MARK: - Butonlar

/// Apple tonlarında, üzerine gelince yumuşakça belirginleşen buton.
/// Varsayılan: nötr gri zemin. prominent: rengi `.tint(...)`ten gelen dolu buton. role: .destructive kırmızı.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    private var compact: Bool { controlSize == .small || controlSize == .mini }
    private var destructive: Bool { configuration.role == .destructive }

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(compact ? .callout : .body)
            .fontWeight(.medium)
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 13)
            .padding(.vertical, compact ? 3 : 6)
            .foregroundStyle(foreground)
            .background(Capsule(style: .continuous).fill(fill(pressed: pressed)))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(prominent ? 0.35 : 0.14), .white.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            )
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .onHover { hovering = $0 && isEnabled }
    }

    private var foreground: AnyShapeStyle {
        if prominent { return AnyShapeStyle(Color.white) }
        if destructive { return AnyShapeStyle(Color.red) }
        return AnyShapeStyle(Color.primary)
    }

    private func fill(pressed: Bool) -> AnyShapeStyle {
        let boost = pressed ? 0.1 : hovering ? 0.05 : 0
        if prominent {
            return AnyShapeStyle(TintShapeStyle.tint.opacity(pressed ? 0.8 : hovering ? 1 : 0.88))
        }
        if destructive { return AnyShapeStyle(Color.red.opacity(0.12 + boost * 1.5)) }
        return AnyShapeStyle(Color.primary.opacity(0.07 + boost))
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
    static var glassProminent: GlassButtonStyle { GlassButtonStyle(prominent: true) }
}

struct CardHeader: View {
    let title: String
    let symbol: String
    let color: Color
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
    }
}

// MARK: - Yığılmış çubuk

struct BarSegment: Identifiable {
    let id: String
    let title: String
    let value: Double
    let color: Color
}

/// Toplama göre oranlı, tıklanabilir yatay çubuk.
struct StackedBar: View {
    let segments: [BarSegment]
    let total: Double
    var height: CGFloat = 16
    var onTap: ((String) -> Void)? = nil
    @State private var hovered: String?

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(segments.filter { $0.value > 0 }) { s in
                    let w = max(2, g.size.width * CGFloat(s.value / max(total, 1)))
                    Rectangle()
                        .fill(s.color)
                        .opacity(hovered == nil || hovered == s.id ? 1 : 0.45)
                        .frame(width: w)
                        .onHover { hovered = $0 ? s.id : nil }
                        .onTapGesture { onTap?(s.id) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: height / 2.5, style: .continuous))
    }
}

/// Renk noktası + başlık + yüzde + boyut; tıklanınca ilgili ekrana gider.
struct LegendRow: View {
    let color: Color
    let title: String
    var subtitle: String? = nil
    let fraction: Double
    let value: String
    var symbol: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        let row = HStack(spacing: 10) {
            if let symbol {
                IconTile(symbol: symbol, color: color, size: 22)
            } else {
                Circle().fill(color).frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(Fmt.percent(fraction))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .frame(minWidth: 40, alignment: .trailing)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .opacity(action == nil ? 0 : 1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)

        if let action {
            row.hoverHighlight().onTapGesture(perform: action)
        } else {
            row
        }
    }
}

/// Büyük halka gösterge kartı (Genel Bakış'taki RAM/Swap/Disk).
struct GaugeCard: View {
    let title: String
    let symbol: String
    let fraction: Double
    let color: Color
    let headline: String
    let detail: String
    let footnote: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RingGauge(fraction: fraction, color: color, lineWidth: 9)
                VStack(spacing: 0) {
                    Text(Fmt.percent(fraction))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 86, height: 86)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(headline).font(.callout.monospacedDigit())
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 2)
                HStack(spacing: 3) {
                    Text(footnote)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 96)
        .card()
        .hoverHighlight(cornerRadius: 14)
        .onTapGesture(perform: action)
    }
}

/// Kip seçici hap. Button yerine dokunma hareketi: macOS'ta Button etiketi bazen ilk çizimde takılı kalıyor
/// (değer güncellenmiyordu), düz görünüm her güncellemede yeniden çiziliyor.
struct PillButton: View {
    let title: String
    let value: String
    let color: Color
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption.weight(.medium))
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .foregroundStyle(color)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(active ? 0.2 : hovering ? 0.12 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(active ? 0.55 : 0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityAddTraits(.isButton)
    }
}
