import SwiftUI

/// Diskin rakamları 100 MB'a yuvarlanmış hali: kartlar yalnızca bunlar değişince yeniden çizilir.
struct DiskFigures: Equatable {
    let total: Int64
    let available: Int64
    var used: Int64 { max(0, total - available) }

    init(_ d: DiskSnapshot) {
        total = d.total
        available = d.available / 100_000_000 * 100_000_000
    }
}

/// Genel Bakış. Performans notu: bu kabuk hiçbir veri deposunu izlemez; her kart yalnızca kendi
/// verisini izler. Böylece 3 sn'de bir gelen RAM güncellemesi tüm ekranı yeniden yerleştirmez.
struct OverviewView: View {
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var processes: ProcessStore
    @EnvironmentObject private var servers: DevServerStore
    @EnvironmentObject private var overview: OverviewStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OverviewHealthCard()
                OverviewGauges()
                OverviewDiskRow()
                OverviewBottomRow()
            }
            .padding(24)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await processes.autoRefresh(every: 4) }
        .task {
            if cleanup.items.isEmpty && !cleanup.isScanning { await cleanup.scanAll() }
        }
        .task { await overview.measureIfNeeded() }
        .task { if !servers.loaded { await servers.refresh() } }
    }
}

private struct OverviewHealthCard: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var cleanup: CleanupStore

    private enum Health { case good, warning, critical }

    private var health: (Health, String, [String]) {
        let m = monitor.memory
        let d = monitor.disk
        var issues: [String] = []
        var level = Health.good
        if d.available < 10_000_000_000 {
            issues.append("Diskte yalnızca \(Fmt.bytes(d.available)) boş alan kaldı.")
            level = .critical
        } else if d.available < 25_000_000_000 {
            issues.append("Boş disk alanı azalıyor (\(Fmt.bytes(d.available))).")
            level = .warning
        }
        if m.pressure == .critical || m.swapFraction > 0.85 {
            issues.append("Bellek yetersiz: swap %\(Int(m.swapFraction * 100)) dolu.")
            level = .critical
        } else if m.pressure == .warning {
            issues.append("Bellek baskısı yüksek, sistem swap kullanıyor.")
            if level == .good { level = .warning }
        } else if m.swapFraction > 0.5 {
            issues.append("Swap kullanımı yüksek (%\(Int(m.swapFraction * 100))). Ağır uygulamaları kapatmak hızlandırır.")
            if level == .good { level = .warning }
        }
        let title: String
        switch level {
        case .good: title = "Mac'in iyi durumda"
        case .warning: title = "Biraz bakım iyi gelir"
        case .critical: title = "Mac'in zorlanıyor"
        }
        if issues.isEmpty { issues.append("Bellek ve disk alanı rahat.") }
        return (level, title, issues)
    }

    var body: some View {
        let (level, title, issues) = health
        let color: Color = level == .good ? .green : level == .warning ? .orange : .red
        let symbol = level == .good ? "checkmark.seal.fill" : level == .warning ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill"
        let safeSize = cleanup.summary.presetSizes[.safe] ?? 0
        return HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(color.gradient)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                ForEach(issues, id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    Task { await cleanup.quickClean() }
                } label: {
                    HStack {
                        if cleanup.isBusy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        Text(cleanup.isBusy ? "Çalışıyor…" : "Hızlı Temizlik")
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(cleanup.isBusy)
                Text(quickCaption(safeSize)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.14), .clear], startPoint: .leading, endPoint: .center))
                .allowsHitTesting(false)
        )
    }

    private func quickCaption(_ safeSize: Int64) -> String {
        if case let .done(freed, _) = cleanup.quickState {
            return freed > 0 ? "✓ \(Fmt.bytes(freed)) yer açıldı" : "✓ Temizlenecek bir şey kalmadı"
        }
        return safeSize > 0 ? "Güvenle silinebilecek \(Fmt.bytes(safeSize)) var" : "Önbellekleri ve güvenli kalıntıları siler"
    }

}

private struct OverviewGauges: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let m = monitor.memory
        let d = monitor.disk
        let swapColor: Color = m.swapFraction > 0.7 ? .red : m.swapFraction > 0.4 ? .orange : .green
        let diskColor: Color = d.available < 15_000_000_000 ? .red : d.available < 40_000_000_000 ? .orange : .green
        return HStack(spacing: 16) {
            GaugeCard(title: "Bellek (RAM)", symbol: "memorychip", fraction: m.usedFraction, color: m.pressure.color,
                      headline: "\(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))",
                      detail: "Baskı: \(m.pressure.title)", footnote: "Uygulamaları gör") {
                state.showMemory()
            }
            GaugeCard(title: "Swap", symbol: "arrow.left.arrow.right", fraction: m.swapFraction, color: swapColor,
                      headline: "\(Fmt.bytes(m.swapUsed)) / \(Fmt.bytes(m.swapTotal))",
                      detail: "RAM'e sığmayıp diske taşan", footnote: "Bellek ayrıntıları") {
                state.showMemory()
            }
            GaugeCard(title: "Disk", symbol: "internaldrive", fraction: d.usedFraction, color: diskColor,
                      headline: "\(Fmt.bytes(d.available)) boş",
                      detail: "\(Fmt.bytes(d.used)) / \(Fmt.bytes(d.total)) dolu", footnote: "Depolama haritası") {
                state.showStorage()
            }
        }
    }

}

private struct OverviewDiskRow: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let figs = DiskFigures(monitor.disk)
        HStack(alignment: .top, spacing: 16) {
            OverviewDiskCard(disk: figs).equatable()
            OverviewCleanableCard(disk: figs)
        }
    }
}

private struct OverviewBottomRow: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let figs = DiskFigures(monitor.disk)
        HStack(alignment: .top, spacing: 16) {
            OverviewMemoryCard()
            VStack(spacing: 16) {
                OverviewProjectsCard(disk: figs)
                OverviewServersCard()
            }
        }
    }
}

private struct OverviewDiskCard: View, Equatable {
    let disk: DiskFigures
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var overview: OverviewStore

    static func == (a: Self, b: Self) -> Bool { a.disk == b.disk }

    var body: some View {
        let total = Double(max(1, disk.total))
        let free = BarSegment(id: "free", title: "Boş alan", value: Double(disk.available), color: Color.primary.opacity(0.15))
        let bars = overview.segments.map { BarSegment(id: $0.id, title: $0.title, value: Double($0.bytes), color: $0.color) } + [free]
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Disk nereye gidiyor?", symbol: "chart.pie.fill", color: .orange,
                       subtitle: overview.isMeasuring ? "Ölçülüyor… %\(Int(overview.progress * 100))"
                           : overview.measuredAt.map { "Ölçüm: \(Fmt.relative($0))" } ?? "",
                       actionTitle: "Yenile") {
                Task { await overview.measure() }
            }
            StackedBar(segments: bars, total: total, height: 18) { id in open(segmentID: id) }
            if overview.segments.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Klasörler ölçülüyor…").foregroundStyle(.secondary) }
            }
            VStack(spacing: 0) {
                ForEach(overview.segments) { s in
                    LegendRow(color: s.color, title: s.title, subtitle: s.subtitle,
                              fraction: Double(s.bytes) / total, value: Fmt.bytes(s.bytes), symbol: s.symbol) {
                        open(segmentID: s.id)
                    }
                }
                LegendRow(color: .secondary, title: "Boş alan", fraction: Double(disk.available) / total,
                          value: Fmt.bytes(disk.available), symbol: "circle.dashed")
            }
        }
        .card()
    }

    private func open(segmentID: String) {
        guard segmentID != "free" else { return }
        let path = overview.segments.first { $0.id == segmentID }?.path
        state.showStorage(path: path)
        if path == nil && state.storage.root != nil { state.storage.focus = state.storage.root }
    }

}

private struct OverviewCleanableCard: View, Equatable {
    let disk: DiskFigures
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var cleanup: CleanupStore

    static func == (a: Self, b: Self) -> Bool { a.disk == b.disk }

    var body: some View {
        let used = Double(max(1, disk.used))
        let categories = cleanup.summary.categories
        let total = cleanup.summary.total
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Temizlenebilir alan", symbol: "sparkles", color: .green,
                       subtitle: cleanup.isScanning ? "Taranıyor…" : "\(Fmt.bytes(total)) · dolu alanın \(Fmt.percent(Double(total) / used))'i",
                       actionTitle: "Tümünü gör") {
                state.showCleanup()
            }
            HStack(spacing: 8) {
                ForEach([CleanupPreset.safe, .balanced, .aggressive]) { p in
                    let size = cleanup.summary.presetSizes[p] ?? 0
                    PillButton(title: p.title, value: Fmt.bytes(size),
                               color: p == .safe ? .green : p == .balanced ? .blue : .orange,
                               active: cleanup.preset == p) {
                        state.showCleanup(preset: p)
                    }
                }
            }
            StackedBar(segments: categories.map { BarSegment(id: $0.0.rawValue, title: $0.0.title, value: Double($0.1), color: $0.0.color) },
                       total: Double(max(1, total)), height: 12) { id in
                state.showCleanup(category: CleanupCategory(rawValue: id))
            }
            if cleanup.items.isEmpty && cleanup.isScanning {
                HStack { ProgressView().controlSize(.small); Text("Önbellekler ve kalıntılar aranıyor…").foregroundStyle(.secondary) }
            }
            VStack(spacing: 0) {
                ForEach(categories, id: \.0) { c, size in
                    LegendRow(color: c.color, title: c.title,
                              subtitle: "\(cleanup.summary.categoryCounts[c] ?? 0) öğe",
                              fraction: Double(size) / used, value: Fmt.bytes(size), symbol: c.symbol) {
                        state.showCleanup(category: c)
                    }
                }
            }
            Text("Yüzdeler dolu disk alanına göredir.").font(.caption2).foregroundStyle(.tertiary)
        }
        .card()
    }

}

private struct OverviewMemoryCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var processes: ProcessStore

    var body: some View {
        let m = monitor.memory
        let total = Double(max(1, m.total))
        let parts: [(String, String, UInt64, Color)] = [
            ("app", "Uygulamalar", m.app, .blue),
            ("wired", "Sistem (wired)", m.wired, .purple),
            ("compressed", "Sıkıştırılmış", m.compressed, .orange),
            ("cached", "Dosya önbelleği", m.cached, .gray),
        ]
        let apps = processes.groups.prefix(6)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Bellek dağılımı", symbol: "memorychip.fill", color: .blue,
                       subtitle: "\(Fmt.bytes(m.used)) kullanımda · swap \(Fmt.bytes(m.swapUsed))",
                       actionTitle: "Bellek") {
                state.showMemory()
            }
            StackedBar(segments: parts.map { BarSegment(id: $0.0, title: $0.1, value: Double($0.2), color: $0.3) },
                       total: total, height: 14) { _ in state.showMemory() }
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 4) {
                        Circle().fill(p.3).frame(width: 7, height: 7)
                        Text(p.1).font(.caption2).foregroundStyle(.secondary)
                        Text(Fmt.percent(Double(p.2) / total)).font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
            }
            Divider()
            Text("En çok bellek kullananlar").font(.subheadline.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(apps) { g in
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: g.bundlePath, size: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(g.name).lineLimit(1)
                                Spacer()
                                Text(Fmt.percent(Double(g.total) / total))
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.blue)
                                Text(Fmt.bytes(g.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Color.primary.opacity(0.07))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.blue.gradient)
                                            .frame(width: max(3, geo.size.width * CGFloat(Double(g.total) / total)))
                                    }
                            }
                            .frame(height: 4)
                        }
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .hoverHighlight()
                    .onTapGesture { state.showMemory(search: g.name) }
                }
            }
        }
        .card()
    }

}

private struct OverviewProjectsCard: View, Equatable {
    let disk: DiskFigures
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var cleanup: CleanupStore

    static func == (a: Self, b: Self) -> Bool { a.disk == b.disk }

    var body: some View {
        let projects = Array(cleanup.summary.projects.prefix(5))
        let used = Double(max(1, disk.used))
        return VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Yer kaplayan projeler", symbol: "hammer.fill", color: .orange,
                       subtitle: "node_modules, .next, .venv… kalıntıları",
                       actionTitle: "Projeler") {
                state.showCleanup(projects: true)
            }
            if projects.isEmpty {
                Text(cleanup.isScanning ? "Taranıyor…" : "Build kalıntısı bulunamadı").foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(projects) { p in
                    LegendRow(color: .orange, title: p.name,
                              subtitle: Fmt.days(since: p.lastUsed).map { "\($0) gündür dokunulmadı" },
                              fraction: Double(p.size) / used, value: Fmt.bytes(p.size)) {
                        state.showCleanup(projects: true, search: p.name)
                    }
                }
            }
        }
        .card()
    }

}

private struct OverviewServersCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var servers: DevServerStore

    var body: some View {
        let devs = servers.servers.filter { !$0.isApp }
        return VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Çalışan dev server'lar", symbol: "server.rack", color: .teal,
                       subtitle: devs.isEmpty ? "Port dinleyen geliştirici süreci yok" : "\(devs.count) süreç port dinliyor",
                       actionTitle: "Yönet") {
                state.showMemory(servers: true)
            }
            ForEach(devs.prefix(4)) { s in
                HStack {
                    Text(s.name).lineLimit(1)
                    Text(verbatim: s.ports.map { ":" + String($0) }.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.teal)
                    Spacer()
                    Text(s.uptime).font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.bytes(s.footprint)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .hoverHighlight()
                .onTapGesture { state.showMemory(servers: true) }
            }
        }
        .card()
    }
}
