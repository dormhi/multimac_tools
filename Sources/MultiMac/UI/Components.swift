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
    case .critical: parts.append(L("Bellek baskısı kritik, sistem yoğun şekilde swap kullanıyor.", "Memory pressure is critical and the system is swapping heavily.", "Нагрузка на память критическая, система активно использует своп."))
    case .warning: parts.append(L("Bellek baskısı yüksek.", "Memory pressure is high.", "Нагрузка на память высокая."))
    case .normal: break
    }
    guard !parts.isEmpty else { return nil }
    if let top {
        parts.append(L("En çok kullanan: \(top.name) (\(Fmt.memory(top.total))). Kullanmadığın uygulamaları kapatmak swap'ı azaltır.", "Top user: \(top.name) (\(Fmt.memory(top.total))). Quitting apps you don't use reduces swap.", "Больше всех: \(top.name) (\(Fmt.memory(top.total))). Закрытие неиспользуемых приложений уменьшит своп."))
    }
    return parts.joined(separator: " ")
}

// MARK: - Swap yorumu

struct SwapInsight {
    enum Level { case calm, churning }
    let level: Level
    let title: String
    let text: String
    /// Yeniden başlatılması en çok fayda sağlayacak uygulama
    let suggestion: ProcessGroup?
}

/// Swap'in "durgun" (zararsız, soğuk veri) mi yoksa "çalkantılı" (RAM ile disk arasında sürekli taşınıyor,
/// takılmanın asıl nedeni) mı olduğunu son 5 dakikadaki değişime ve bellek baskısına bakarak yorumlar.
func swapInsight(_ m: MemorySnapshot, history: [HistoryPoint], groups: [ProcessGroup]) -> SwapInsight? {
    guard m.swapUsed > 200_000_000 else { return nil }
    let recent = Array(history.suffix(100))   // 3 sn aralıkla ~5 dk
    var movedGB = 0.0
    for i in recent.indices.dropFirst() { movedGB += abs(recent[i].swapGB - recent[i - 1].swapGB) }

    // Öneri: uzun süredir açık (3+ saat) ve en çok bellek tutan uygulama; yoksa en büyük uygulama.
    let apps = groups.filter { $0.isApp && !$0.isProtected }
    let longRunning = apps.filter { ($0.uptime ?? 0) > 3 * 3600 }
    let suggestion = (longRunning.isEmpty ? apps : longRunning).max { $0.total < $1.total }
    let restartHint = suggestion.map { g in
        let hours = Int((g.uptime ?? 0) / 3600)
        let age = hours >= 1 ? L(", \(hours) saattir açık", ", open for \(hours) hours", ", открыто \(hours) ч") : ""
        return L(" En çok fayda: \(g.name) (\(Fmt.memory(g.total))\(age)) uygulamasını yeniden başlatmak.", " Biggest win: restart \(g.name) (\(Fmt.memory(g.total))\(age)).", " Больше всего даст перезапуск \(g.name) (\(Fmt.memory(g.total))\(age)).")
    } ?? ""

    if movedGB > 0.75 {
        return SwapInsight(
            level: .churning,
            title: L("Swap çalkantılı", "Swap is churning", "Своп активно работает"),
            text: L("Sistem RAM'e sığmayan veriyi sürekli diske yazıp geri okuyor; takılmanın asıl nedeni bu. Son 5 dakikada ~\(String(format: "%.1f", movedGB)) GB veri RAM ile disk arasında taşındı.\(restartHint)", "The system keeps writing data that doesn't fit in RAM to disk and reading it back; this is what causes the stutter. ~\(String(format: "%.1f", movedGB)) GB moved between RAM and disk in the last 5 minutes.\(restartHint)", "Система постоянно записывает на диск данные, которые не помещаются в RAM, и читает их обратно — именно это вызывает подтормаживания. За последние 5 минут между RAM и диском перемещено ~\(String(format: "%.1f", movedGB)) ГБ.\(restartHint)"),
            suggestion: suggestion)
    }
    if m.pressure != .normal {
        return SwapInsight(
            level: .churning,
            title: L("Bellek sıkışık", "Memory is tight", "Памяти мало"),
            text: L("RAM dolu: macOS verinin \(Fmt.memory(m.compressed))'ını sıkıştırarak sığdırıyor, swap'te de \(Fmt.memory(m.swapUsed)) var. Swap şu an sabit, yani diske gidip gelme yok; ama yeni bir şey açınca takılma başlayabilir. Kullanmadığın uygulamaları kapatmak ya da uzun süredir açık olanı yeniden başlatmak yer açar.\(restartHint)", "RAM is full: macOS is compressing \(Fmt.memory(m.compressed)) of data to make it fit, and \(Fmt.memory(m.swapUsed)) is in swap. Swap is steady right now, so nothing is moving to disk, but opening something new may cause stutters. Quitting apps you don't use or restarting one that has been open for a long time frees memory.\(restartHint)", "RAM заполнена: macOS сжимает \(Fmt.memory(m.compressed)) данных, чтобы всё поместилось, а в свопе \(Fmt.memory(m.swapUsed)). Сейчас своп не меняется, так что обмена с диском нет, но при открытии чего-то нового возможны подтормаживания. Освободить память поможет закрытие неиспользуемых приложений или перезапуск давно открытого.\(restartHint)"),
            suggestion: suggestion)
    }
    return SwapInsight(
        level: .calm,
        title: L("Swap durgun, endişelenme", "Swap is calm, don't worry", "Своп спокоен, не волнуйтесь"),
        text: L("Swap'te \(Fmt.memory(m.swapUsed)) var ama değişmiyor ve bellek baskısı normal. Bu, uzun süredir kimsenin kullanmadığı veri: yalnızca diskte yer tutar, bir uygulama ona dokunduğu an kendiliğinden RAM'e döner. macOS'ta bunu zorla RAM'e geri almanın güvenli bir yolu yok; boşaltmak istersen uygulamayı yeniden başlatman yeterli.\(restartHint)", "There is \(Fmt.memory(m.swapUsed)) in swap, but it isn't changing and memory pressure is normal. This is data nobody has used for a while: it only takes disk space and moves back to RAM by itself the moment an app touches it. macOS has no safe way to force it back into RAM; restarting the app is enough if you want it gone.\(restartHint)", "В свопе \(Fmt.memory(m.swapUsed)), но объём не меняется и нагрузка на память нормальная. Это данные, которые давно никто не использовал: они только занимают место на диске и сами вернутся в RAM, как только приложение к ним обратится. Безопасного способа принудительно вернуть их в RAM в macOS нет; если хотите от них избавиться, достаточно перезапустить приложение.\(restartHint)"),
        suggestion: suggestion)
}

/// Swap yorumu kartı (Bellek ekranı ve menü paneli).
struct SwapInsightCard: View {
    let insight: SwapInsight
    var compact = false
    let restart: (ProcessGroup) -> Void

    var body: some View {
        let color: Color = insight.level == .calm ? .green : .orange
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: insight.level == .calm ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(compact ? .callout : .title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                Text(insight.text)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let g = insight.suggestion {
                    Button {
                        restart(g)
                    } label: {
                        Label(L("\(g.name) uygulamasını yeniden başlat", "Restart \(g.name)", "Перезапустить \(g.name)"), systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
