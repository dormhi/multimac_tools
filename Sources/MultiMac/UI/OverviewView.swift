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
                VStack(alignment: .leading, spacing: 3) {
                    Text(MainTab.overview.title).font(.system(size: 26, weight: .bold))
                    Text(L("Mac'in şu an nasıl, tek bakışta", "How your Mac is doing, at a glance", "Как дела у вашего Mac — с одного взгляда"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, -6)
                OverviewHealthCard()
                OverviewGauges()
                OverviewDiskRow()
                OverviewBottomRow()
            }
            .padding(24)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
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
            issues.append(L("Diskte yalnızca \(Fmt.bytes(d.available)) boş alan kaldı.", "Only \(Fmt.bytes(d.available)) of free disk space left.", "На диске осталось всего \(Fmt.bytes(d.available))."))
            level = .critical
        } else if d.available < 25_000_000_000 {
            issues.append(L("Boş disk alanı azalıyor (\(Fmt.bytes(d.available))).", "Free disk space is running low (\(Fmt.bytes(d.available))).", "Свободного места на диске становится мало (\(Fmt.bytes(d.available)))."))
            level = .warning
        }
        if m.pressure == .critical || m.swapFraction > 0.85 {
            issues.append(L("Bellek yetersiz: swap %\(Int(m.swapFraction * 100)) dolu.", "Not enough memory: swap is \(Int(m.swapFraction * 100))% full.", "Не хватает памяти: своп заполнен на \(Int(m.swapFraction * 100))%."))
            level = .critical
        } else if m.pressure == .warning {
            issues.append(L("Bellek baskısı yüksek, sistem swap kullanıyor.", "Memory pressure is high and the system is using swap.", "Нагрузка на память высокая, система использует своп."))
            if level == .good { level = .warning }
        } else if m.swapFraction > 0.5 {
            issues.append(L("Swap kullanımı yüksek (%\(Int(m.swapFraction * 100))). Ağır uygulamaları kapatmak hızlandırır.", "Swap usage is high (\(Int(m.swapFraction * 100))%). Quitting heavy apps will speed things up.", "Своп сильно занят (\(Int(m.swapFraction * 100))%). Закрытие тяжёлых приложений ускорит работу."))
            if level == .good { level = .warning }
        }
        let title: String
        switch level {
        case .good: title = L("Mac'in iyi durumda", "Your Mac is in good shape", "Ваш Mac в хорошем состоянии")
        case .warning: title = L("Biraz bakım iyi gelir", "A little care would help", "Немного ухода не помешает")
        case .critical: title = L("Mac'in zorlanıyor", "Your Mac is struggling", "Вашему Mac тяжело")
        }
        if issues.isEmpty { issues.append(L("Bellek ve disk alanı rahat.", "Memory and disk space are fine.", "С памятью и местом на диске всё в порядке.")) }
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
                .foregroundStyle(color)
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
                        Text(cleanup.isBusy ? L("Çalışıyor…", "Working…", "Работаю…") : L("Hızlı Temizlik", "Quick Clean", "Быстрая очистка"))
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(cleanup.isBusy)
                Text(quickCaption(safeSize)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.07))
                .allowsHitTesting(false)
        )
    }

    private func quickCaption(_ safeSize: Int64) -> String {
        if case let .done(freed, _) = cleanup.quickState {
            return freed > 0 ? L("✓ \(Fmt.bytes(freed)) yer açıldı", "✓ Freed \(Fmt.bytes(freed))", "✓ Освобождено \(Fmt.bytes(freed))") : L("✓ Temizlenecek bir şey kalmadı", "✓ Nothing left to clean", "✓ Больше нечего очищать")
        }
        return safeSize > 0 ? L("Güvenle silinebilecek \(Fmt.bytes(safeSize)) var", "\(Fmt.bytes(safeSize)) can be safely deleted", "Можно безопасно удалить \(Fmt.bytes(safeSize))") : L("Önbellekleri ve güvenli kalıntıları siler", "Deletes caches and safe leftovers", "Удаляет кэши и безопасные остатки")
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
            GaugeCard(title: L("Bellek (RAM)", "Memory (RAM)", "Память (RAM)"), symbol: "memorychip", fraction: m.usedFraction, color: m.pressure.color,
                      headline: "\(Fmt.memory(m.used)) / \(Fmt.memory(m.total))",
                      detail: L("Baskı: \(m.pressure.title)", "Pressure: \(m.pressure.title)", "Нагрузка: \(m.pressure.title)"), footnote: L("Uygulamaları gör", "See apps", "Приложения")) {
                state.showMemory()
            }
            GaugeCard(title: L("Swap", "Swap", "Своп"), symbol: "arrow.left.arrow.right", fraction: m.swapFraction, color: swapColor,
                      headline: "\(Fmt.memory(m.swapUsed)) / \(Fmt.memory(m.swapTotal))",
                      detail: L("RAM'e sığmayıp diske taşan", "What didn't fit in RAM, on disk", "Что не поместилось в RAM, на диске"), footnote: L("Bellek ayrıntıları", "Memory details", "Подробнее о памяти")) {
                state.showMemory()
            }
            GaugeCard(title: L("Disk", "Disk", "Диск"), symbol: "internaldrive", fraction: d.usedFraction, color: diskColor,
                      headline: L("\(Fmt.bytes(d.available)) boş", "\(Fmt.bytes(d.available)) free", "Свободно \(Fmt.bytes(d.available))"),
                      detail: L("\(Fmt.bytes(d.used)) / \(Fmt.bytes(d.total)) dolu", "\(Fmt.bytes(d.used)) / \(Fmt.bytes(d.total)) used", "Занято \(Fmt.bytes(d.used)) / \(Fmt.bytes(d.total))"), footnote: L("Depolama haritası", "Storage map", "Карта хранилища")) {
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
        let free = BarSegment(id: "free", title: L("Boş alan", "Free space", "Свободное место"), value: Double(disk.available), color: Color.primary.opacity(0.15))
        let bars = overview.segments.map { BarSegment(id: $0.id, title: $0.title, value: Double($0.bytes), color: $0.color) } + [free]
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L("Disk nereye gidiyor?", "Where is the disk going?", "Чем занят диск?"), symbol: "chart.pie.fill", color: .orange,
                       subtitle: overview.isMeasuring ? L("Ölçülüyor… %\(Int(overview.progress * 100))", "Measuring… \(Int(overview.progress * 100))%", "Измерение… \(Int(overview.progress * 100))%")
                           : overview.measuredAt.map { L("Ölçüm: \(Fmt.relative($0))", "Measured \(Fmt.relative($0))", "Измерено \(Fmt.relative($0))") } ?? "",
                       actionTitle: L("Yenile", "Refresh", "Обновить")) {
                Task { await overview.measure() }
            }
            StackedBar(segments: bars, total: total, height: 18) { id in open(segmentID: id) }
            if overview.segments.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(L("Klasörler ölçülüyor…", "Measuring folders…", "Измерение папок…")).foregroundStyle(.secondary) }
            }
            VStack(spacing: 0) {
                ForEach(overview.segments) { s in
                    LegendRow(color: s.color, title: s.title, subtitle: s.subtitle,
                              fraction: Double(s.bytes) / total, value: Fmt.bytes(s.bytes), symbol: s.symbol) {
                        open(segmentID: s.id)
                    }
                }
                LegendRow(color: .secondary, title: L("Boş alan", "Free space", "Свободное место"), fraction: Double(disk.available) / total,
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
            CardHeader(title: L("Temizlenebilir alan", "Cleanable space", "Можно очистить"), symbol: "sparkles", color: .green,
                       subtitle: cleanup.isScanning ? L("Taranıyor…", "Scanning…", "Сканирование…") : L("\(Fmt.bytes(total)) · dolu alanın \(Fmt.percent(Double(total) / used))'i", "\(Fmt.bytes(total)) · \(Fmt.percent(Double(total) / used)) of used space", "\(Fmt.bytes(total)) · \(Fmt.percent(Double(total) / used)) занятого места"),
                       actionTitle: L("Tümünü gör", "See all", "Все")) {
                state.showCleanup()
            }
            HStack(spacing: 8) {
                // Boyutlar verinin parçası: sabit bir kip listesiyle ForEach ilk çizimde takılı kalıyordu ("Sıfır KB").
                let rows = [CleanupPreset.safe, .balanced, .aggressive].map { ($0, cleanup.summary.presetSizes[$0] ?? 0) }
                ForEach(rows, id: \.0) { p, size in
                    PillButton(title: p.title, value: Fmt.bytes(size),
                               color: p == .safe ? .green : p == .balanced ? .blue : .orange,
                               active: cleanup.preset == p) {
                        state.showCleanup(preset: p)
                    }
                    .id("\(p.rawValue)-\(size)")
                }
            }
            StackedBar(segments: categories.map { BarSegment(id: $0.0.rawValue, title: $0.0.title, value: Double($0.1), color: $0.0.color) },
                       total: Double(max(1, total)), height: 12) { id in
                state.showCleanup(category: CleanupCategory(rawValue: id))
            }
            if cleanup.items.isEmpty && cleanup.isScanning {
                HStack { ProgressView().controlSize(.small); Text(L("Önbellekler ve kalıntılar aranıyor…", "Looking for caches and leftovers…", "Поиск кэшей и остатков…")).foregroundStyle(.secondary) }
            }
            VStack(spacing: 0) {
                ForEach(categories, id: \.0) { c, size in
                    LegendRow(color: c.color, title: c.title,
                              subtitle: L("\(cleanup.summary.categoryCounts[c] ?? 0) öğe", "\(cleanup.summary.categoryCounts[c] ?? 0) items", "Объектов: \(cleanup.summary.categoryCounts[c] ?? 0)"),
                              fraction: Double(size) / used, value: Fmt.bytes(size), symbol: c.symbol) {
                        state.showCleanup(category: c)
                    }
                }
            }
            Text(L("Yüzdeler dolu disk alanına göredir.", "Percentages are of used disk space.", "Проценты указаны от занятого места на диске.")).font(.caption2).foregroundStyle(.tertiary)
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
            ("app", L("Uygulamalar", "Apps", "Приложения"), m.app, .blue),
            ("wired", L("Sistem (wired)", "System (wired)", "Система (wired)"), m.wired, .purple),
            ("compressed", L("Sıkıştırılmış", "Compressed", "Сжатая"), m.compressed, .orange),
            ("cached", L("Dosya önbelleği", "File cache", "Файловый кэш"), m.cached, .gray),
        ]
        let apps = processes.groups.prefix(6)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L("Bellek dağılımı", "Memory breakdown", "Распределение памяти"), symbol: "memorychip.fill", color: .blue,
                       subtitle: L("\(Fmt.memory(m.used)) kullanımda · swap \(Fmt.memory(m.swapUsed))", "\(Fmt.memory(m.used)) in use · swap \(Fmt.memory(m.swapUsed))", "Используется \(Fmt.memory(m.used)) · своп \(Fmt.memory(m.swapUsed))"),
                       actionTitle: L("Bellek", "Memory", "Память")) {
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
            Text(L("En çok bellek kullananlar", "Using the most memory", "Больше всего памяти")).font(.subheadline.weight(.semibold))
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
                                Text(Fmt.memory(g.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Color.primary.opacity(0.07))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.blue)
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
            CardHeader(title: L("Yer kaplayan projeler", "Projects taking up space", "Проекты, занимающие место"), symbol: "hammer.fill", color: .orange,
                       subtitle: L("node_modules, .next, .venv… kalıntıları", "node_modules, .next, .venv… leftovers", "Остатки node_modules, .next, .venv…"),
                       actionTitle: L("Projeler", "Projects", "Проекты")) {
                state.showCleanup(projects: true)
            }
            if projects.isEmpty {
                Text(cleanup.isScanning ? L("Taranıyor…", "Scanning…", "Сканирование…") : L("Build kalıntısı bulunamadı", "No build leftovers found", "Остатков сборок не найдено")).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(projects) { p in
                    LegendRow(color: .orange, title: p.name,
                              subtitle: Fmt.days(since: p.lastUsed).map { L("\($0) gündür dokunulmadı", "Untouched for \($0) days", "Не трогали дней: \($0)") },
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
            CardHeader(title: L("Çalışan dev server'lar", "Running dev servers", "Запущенные dev-серверы"), symbol: "server.rack", color: .teal,
                       subtitle: devs.isEmpty ? L("Port dinleyen geliştirici süreci yok", "No developer processes listening on a port", "Нет процессов разработчика, слушающих порт") : L("\(devs.count) süreç port dinliyor", "\(devs.count) processes listening on ports", "Процессов, слушающих порты: \(devs.count)"),
                       actionTitle: L("Yönet", "Manage", "Управлять")) {
                state.showMemory(servers: true)
            }
            ForEach(devs.prefix(4)) { s in
                HStack {
                    Text(s.name).lineLimit(1)
                    Text(verbatim: s.ports.map { ":" + String($0) }.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.teal)
                    Spacer()
                    Text(s.uptime).font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.memory(s.footprint)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
