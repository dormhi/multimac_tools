import SwiftUI
import AppKit

struct RingGauge: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let caption: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RingGauge(fraction: fraction, color: color)
                Text(Fmt.percent(fraction))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 46, height: 46)
            Text(title).font(.caption.weight(.semibold))
            VStack(spacing: 1) {
                Text(value).font(.caption2).monospacedDigit()
                Text(caption).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct Checkbox: View {
    enum State { case on, off, mixed }
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

struct AppIconView: View {
    let bundlePath: String?
    var size: CGFloat = 18

    var body: some View {
        if let bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}

/// Bellek baskısı ve swap durumuna göre okunur bir öneri cümlesi.
func memoryAdvice(_ m: MemorySnapshot, top: ProcessGroup?) -> String? {
    var parts: [String] = []
    switch m.pressure {
    case .critical: parts.append("Bellek baskısı kritik, sistem yoğun şekilde swap kullanıyor.")
    case .warning: parts.append("Bellek baskısı yüksek.")
    case .normal: break
    }
    if m.swapFraction > 0.6 {
        parts.append("Swap %\(Int(m.swapFraction * 100)) dolu (\(Fmt.bytes(m.swapUsed))). Bu SSD'ye yazma yapar ve sistemi yavaşlatır.")
    }
    guard !parts.isEmpty else { return nil }
    if let top {
        parts.append("En çok kullanan: \(top.name) (\(Fmt.bytes(top.total))). Kullanmadığın uygulamaları kapatmak swap'ı azaltır.")
    }
    return parts.joined(separator: " ")
}
