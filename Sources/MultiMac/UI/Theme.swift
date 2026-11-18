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

// MARK: - Kart

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Gölge yok: kaydırırken her karede yeniden hesaplanması akıcılığı düşürüyordu.
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
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

/// Renkli kare içinde SF Symbol
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(color.gradient)
            )
    }
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
                        .fill(s.color.gradient)
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

struct PillButton: View {
    let title: String
    let value: String
    let color: Color
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(value).font(.callout.weight(.bold).monospacedDigit())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(active ? .white : color)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.12)))
            )
        }
        .buttonStyle(.plain)
    }
}
