import SwiftUI
import Charts

/// Bellek sayfası. Her kart kendi verisini ayrı izler: RAM her 3 sn'de, süreç listesi her 3 sn'de ve
/// dev server'lar her 5 sn'de değişiyor. Hepsi tek görünümdeyken her değişiklik 190 satırlık listeyi ve
/// grafiği birlikte yeniden çizdiriyordu (yenileme başına ~0,5 sn ana thread).
struct MemoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""
    @State private var devOnly = false
    @State private var expanded: Set<String> = []
    @State private var scrollTarget: String?

    private func handleRequest() {
        guard let r = state.memoryRequest else { return }
        state.memoryRequest = nil
        search = r.search ?? ""
        devOnly = false
        if let q = r.search, let g = state.processes.groups.first(where: { $0.name == q }) { expanded.insert(g.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            scrollTarget = r.servers ? "servers" : (r.search != nil ? "processes" : nil)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MemoryHeader()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MemoryInsightSection()
                        HStack(alignment: .top, spacing: 16) {
                            MemoryBreakdownCard().card()
                            MemoryChartCard().card()
                        }
                        MemoryServersCard().card().id("servers")
                        MemoryProcessesCard(search: $search, devOnly: $devOnly, expanded: $expanded)
                            .card().id("processes")
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: scrollTarget) { _, t in
                    guard let t else { return }
                    withAnimation { proxy.scrollTo(t, anchor: .top) }
                    scrollTarget = nil
                }
            }
        }
        .onAppear(perform: handleRequest)
        .onChange(of: state.memoryRequest) { _, _ in handleRequest() }
        .task { await state.processes.autoRefresh(every: 3) }
        .task { await state.servers.autoRefresh(every: 5) }
    }
}

private struct MemoryHeader: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let m = monitor.memory
        PageHeader(title: L("Bellek", "Memory", "Память"), subtitle: L("Baskı: \(m.pressure.title) · \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total)) kullanımda", "Pressure: \(m.pressure.title) · \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total)) in use", "Нагрузка: \(m.pressure.title) · используется \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))"),
                   symbol: "memorychip", color: .blue) {
            Badge(text: L("Baskı: \(m.pressure.title)", "Pressure: \(m.pressure.title)", "Нагрузка: \(m.pressure.title)"), color: m.pressure.color, symbol: "circle.fill")
        }
    }
}

private struct MemoryInsightSection: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var processes: ProcessStore

    var body: some View {
        let m = monitor.memory
        if let insight = swapInsight(m, history: monitor.history, groups: processes.groups) {
            SwapInsightCard(insight: insight) { processes.restart($0) }
        } else if let advice = memoryAdvice(m, top: processes.groups.first(where: { !$0.isProtected })) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
                Text(advice).font(.callout)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct MemoryBreakdownCard: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View { breakdown(monitor.memory) }

    private func breakdown(_ m: MemorySnapshot) -> some View {
        let items: [(String, UInt64, Color, String)] = [
            (L("Uygulama", "Apps", "Приложения"), m.app, .blue, L("Açık uygulamaların kullandığı bellek", "Memory used by open apps", "Память открытых приложений")),
            (L("Sistem (wired)", "System (wired)", "Система (wired)"), m.wired, .purple, L("Çekirdek ve sürücüler, boşaltılamaz", "Kernel and drivers, can't be freed", "Ядро и драйверы, освободить нельзя")),
            (L("Sıkıştırılmış", "Compressed", "Сжатая"), m.compressed, .orange, L("RAM'e sığdırmak için sıkıştırılmış veri", "Data compressed to fit in RAM", "Данные, сжатые, чтобы поместиться в RAM")),
            (L("Dosya önbelleği", "File cache", "Файловый кэш"), m.cached, .gray, L("macOS gerektiğinde anında boşaltır", "macOS frees it instantly when needed", "macOS мгновенно освобождает его при необходимости")),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L("Dağılım", "Breakdown", "Распределение"), symbol: "chart.bar.fill", color: .blue,
                       subtitle: "\(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total)) · \(Fmt.percent(m.usedFraction))")
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(items, id: \.0) { item in
                        Rectangle().fill(item.2)
                            .frame(width: max(0, g.size.width * CGFloat(Double(item.1) / Double(max(1, m.total)))))
                    }
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(spacing: 0) {
                ForEach(items, id: \.0) { item in
                    LegendRow(color: item.2, title: item.0, subtitle: item.3,
                              fraction: Double(item.1) / Double(max(1, m.total)), value: Fmt.bytes(item.1))
                }
                LegendRow(color: .red, title: L("Swap", "Swap", "Своп"), subtitle: L("RAM'e sığmayıp diske taşan · toplam \(Fmt.bytes(m.swapTotal))", "Didn't fit in RAM, moved to disk · total \(Fmt.bytes(m.swapTotal))", "Не поместилось в RAM, вытеснено на диск · всего \(Fmt.bytes(m.swapTotal))"),
                          fraction: m.swapFraction, value: Fmt.bytes(m.swapUsed))
            }
        }
    }

}

private struct MemoryChartCard: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View { chart }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: L("Son 30 dakika", "Last 30 minutes", "Последние 30 минут"), symbol: "waveform.path.ecg", color: .red,
                       subtitle: L("Kullanılan RAM ve swap (GB)", "Used RAM and swap (GB)", "Используемая RAM и своп (ГБ)"))
            Chart {
                ForEach(chartPoints) { p in
                    AreaMark(x: .value(L("Zaman", "Time", "Время"), p.date), y: .value(L("GB", "GB", "ГБ"), p.usedGB),
                             series: .value(L("Tür", "Type", "Тип"), L("Kullanılan", "Used", "Используется")))
                        .foregroundStyle(by: .value(L("Tür", "Type", "Тип"), L("Kullanılan RAM", "Used RAM", "Используемая RAM")))
                        .opacity(0.5)
                    LineMark(x: .value(L("Zaman", "Time", "Время"), p.date), y: .value(L("GB", "GB", "ГБ"), p.swapGB),
                             series: .value(L("Tür", "Type", "Тип"), L("Swap", "Swap", "Своп")))
                        .foregroundStyle(by: .value(L("Tür", "Type", "Тип"), L("Swap", "Swap", "Своп")))
                }
            }
            .chartForegroundStyleScale([L("Kullanılan RAM", "Used RAM", "Используемая RAM"): Color.blue, L("Swap", "Swap", "Своп"): Color.red])
            .chartYAxisLabel(L("GB", "GB", "ГБ"))
            .frame(height: 190)
        }
    }

    /// Grafikte en fazla ~150 nokta: 600 noktayı (×2 seri) her 3 sn'de çizmek pahalıydı.
    private var chartPoints: [HistoryPoint] {
        let h = monitor.history
        guard h.count > 150 else { return h }
        let step = Int((Double(h.count) / 150).rounded(.up))
        return stride(from: 0, to: h.count, by: step).map { h[$0] } + [h[h.count - 1]]
    }

}

private struct MemoryServersCard: View {
    @EnvironmentObject private var servers: DevServerStore
    @State private var showAppServers = false

    var body: some View { serverList }

    private var visibleServers: [ListeningServer] {
        servers.servers.filter { showAppServers || !$0.isApp }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(title: L("Dev server'lar", "Dev servers", "Dev-серверы"), symbol: "server.rack", color: .teal,
                           subtitle: L("Port dinleyen süreçler; unutulanları buradan kapat", "Processes listening on a port; stop forgotten ones here", "Процессы, слушающие порт; забытые можно остановить здесь"))
                Toggle(L("Uygulama ve sistem süreçlerini de göster", "Also show app and system processes", "Показывать также процессы приложений и системы"), isOn: $showAppServers).toggleStyle(.checkbox)
            }
            VStack(spacing: 0) {
                if !servers.loaded {
                    ProgressView().controlSize(.small).padding(10)
                } else if visibleServers.isEmpty {
                    Text(L("Port dinleyen geliştirici süreci yok", "No developer processes listening on a port", "Нет процессов разработчика, слушающих порт"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                }
                ForEach(visibleServers) { s in
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: s.bundlePath, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(s.name).lineLimit(1)
                                if s.isDeveloperTool { Badge(text: L("Geliştirici", "Developer", "Разработка"), color: .purple) }
                            }
                            Text(verbatim: s.cwd.map(Fmt.displayPath) ?? "PID " + String(s.pid))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(s.ports.prefix(4), id: \.self) { port in
                                Button(":" + String(port)) { servers.openInBrowser(port) }
                                    .buttonStyle(.glass)
                                    .help(L("http://localhost:\(String(port)) adresini tarayıcıda aç", "Open http://localhost:\(String(port)) in the browser", "Открыть http://localhost:\(String(port)) в браузере"))
                            }
                        }
                        Text(s.uptime).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            .help(L("Çalışma süresi", "Uptime", "Время работы"))
                        Text(Fmt.bytes(s.footprint)).monospacedDigit().frame(width: 76, alignment: .trailing)
                        Button(L("Durdur", "Stop", "Остановить")) { servers.stop(s) }
                            .help(L("Sürece kapanmasını söyler (SIGTERM); dev server düzgünce kapanır", "Asks the process to exit (SIGTERM); the dev server shuts down cleanly", "Просит процесс завершиться (SIGTERM); dev-сервер корректно остановится"))
                        Button(role: .destructive) { servers.stop(s, force: true) } label: {
                            Text(L("Zorla Durdur", "Force Stop", "Остановить принудительно")).foregroundStyle(.red)
                        }
                            .help(L("Süreci anında öldürür (SIGKILL); yanıt vermeyen sunucular için", "Kills the process immediately (SIGKILL); for unresponsive servers", "Немедленно завершает процесс (SIGKILL); для зависших серверов"))
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

}

private struct MemoryProcessesCard: View {
    @EnvironmentObject private var processes: ProcessStore
    @Binding var search: String
    @Binding var devOnly: Bool
    @Binding var expanded: Set<String>
    @State private var confirmForce: ProcessGroup?

    var body: some View {
        processList
            .alert(L("Zorla kapatılsın mı?", "Force quit?", "Завершить принудительно?"), isPresented: Binding(get: { confirmForce != nil },
                                                           set: { if !$0 { confirmForce = nil } }),
               presenting: confirmForce) { g in
            Button(L("Zorla Kapat", "Force Quit", "Завершить принудительно"), role: .destructive) { processes.quit(g, force: true) }
            Button(L("Vazgeç", "Cancel", "Отмена"), role: .cancel) {}
        } message: { g in
            Text(L("\(g.name) kaydedilmemiş verileriyle birlikte hemen sonlandırılır.", "\(g.name) will be terminated immediately, along with any unsaved data.", "\(g.name) будет немедленно завершено вместе с несохранёнными данными."))
        }
    }

    private func toggleProtected(_ g: ProcessGroup) {
        var list = Prefs.list(Prefs.protectedApps)
        if list.contains(g.name) {
            list.removeAll { $0 == g.name }
        } else {
            list.append(g.name)
        }
        Prefs.setList(Prefs.protectedApps, list)
        Task { await processes.refresh() }
    }

    private var filtered: [ProcessGroup] {
        processes.groups.filter { g in
            (!devOnly || g.isDeveloperTool)
                && (search.isEmpty || g.name.localizedCaseInsensitiveContains(search)
                    || g.processes.contains { $0.cwd?.localizedCaseInsensitiveContains(search) ?? false })
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(title: L("Uygulamalar ve süreçler", "Apps and processes", "Приложения и процессы"), symbol: "square.stack.3d.up.fill", color: .indigo,
                           subtitle: L("\(processes.groups.count) grup · sağ tık: korunanlara ekle", "\(processes.groups.count) groups · right-click: add to protected", "Групп: \(processes.groups.count) · правый щелчок: добавить в защищённые"))
                Toggle(L("Sadece geliştirici süreçleri", "Developer processes only", "Только процессы разработки"), isOn: $devOnly).toggleStyle(.checkbox)
                TextField(L("Ara", "Search", "Поиск"), text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            ButtonLegend()
            let userProtected = Set(Prefs.list(Prefs.protectedApps))
            LazyVStack(spacing: 0) {
                ForEach(filtered) { group in
                    ProcessGroupRow(group: group, isExpanded: expanded.contains(group.id),
                                    toggle: {
                                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                                    },
                                    quit: { processes.quit(group) },
                                    forceQuit: { confirmForce = group },
                                    restart: { processes.restart(group) },
                                    isRestarting: processes.restarting.contains(group.id),
                                    killPID: { processes.kill($0) })
                        .equatable()
                        .contextMenu {
                            let isUser = userProtected.contains(group.name)
                            if isUser || !group.isProtected {
                                Button(isUser ? L("Korumayı kaldır", "Remove protection", "Снять защиту") : L("Korunanlara ekle (asla kapatma önerme)", "Add to protected (never suggest quitting)", "Добавить в защищённые (никогда не предлагать закрыть)")) {
                                    toggleProtected(group)
                                }
                            }
                        }
                    Divider()
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            if filtered.isEmpty {
                Text(L("Eşleşen süreç yok", "No matching processes", "Подходящих процессов нет")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }
}

/// Satır yalnızca kendi ekranda görünen değerleri değişince yeniden çizilir (bkz. `.equatable()`).
/// Kapanışlar karşılaştırılamadığı için SwiftUI bunu kendisi yapamıyor, her yenilemede 190 satırı da çiziyordu.
private struct ProcessGroupRow: View, Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.isExpanded == b.isExpanded && a.isRestarting == b.isRestarting
            && a.group.displayKey(expanded: a.isExpanded) == b.group.displayKey(expanded: b.isExpanded)
    }

    let group: ProcessGroup
    let isExpanded: Bool
    let toggle: () -> Void
    let quit: () -> Void
    let forceQuit: () -> Void
    let restart: () -> Void
    let isRestarting: Bool
    let killPID: (pid_t) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .opacity(group.processes.count > 1 || group.processes.first?.cwd != nil ? 1 : 0)
                AppIconView(bundlePath: group.bundlePath, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.name).lineLimit(1)
                        if group.isDeveloperTool { Badge(text: L("Geliştirici", "Developer", "Разработка"), color: .purple) }
                        if group.isProtected { Badge(text: L("Sistem", "System", "Система"), color: .secondary, symbol: "lock.fill") }
                    }
                    if let cwd = group.processes.first?.cwd, !group.isApp {
                        Text(Fmt.displayPath(cwd)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                // Butonlar yalnızca fare satırın üzerindeyken çizilir: 190 satırda 570 buton (her biri fare takibi
                // ve araç ipucuyla) her yenilemede yeniden hesaplanıyordu. Boyut sütunu yerinde kalır.
                if hovering || isRestarting {
                    if group.isApp {
                        if isRestarting {
                            ProgressView().controlSize(.small)
                            Text(L("Yeniden başlıyor…", "Restarting…", "Перезапуск…")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button { restart() } label: { Label(L("Yeniden Başlat", "Restart", "Перезапустить"), systemImage: "arrow.clockwise") }
                                .help(L("Düzgünce kapatıp hemen tekrar açar; RAM'de ve swap'te tuttuğu her şeyi bırakır", "Quits cleanly and reopens right away, releasing everything it held in RAM and swap", "Корректно закрывает и сразу открывает снова, освобождая всё, что приложение держало в RAM и свопе"))
                                .disabled(group.isProtected)
                        }
                    }
                    Button { quit() } label: { Label(L("Kapat", "Quit", "Закрыть"), systemImage: "xmark") }
                        .help(L("Uygulamaya kapanmasını söyler; kaydedilmemiş belge varsa uygulama sorar", "Asks the app to quit; it will ask about unsaved documents", "Просит приложение завершиться; оно спросит о несохранённых документах"))
                        .disabled(group.isProtected)
                    Button(role: .destructive) { forceQuit() } label: {
                        Label(L("Zorla Kapat", "Force Quit", "Завершить принудительно"), systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                    }
                        .help(L("Yanıt vermeyen uygulamayı anında sonlandırır; kaydedilmemiş veriler kaybolur", "Ends an unresponsive app immediately; unsaved data is lost", "Немедленно завершает зависшее приложение; несохранённые данные будут потеряны"))
                        .disabled(group.isProtected)
                } else {
                    Text(L("\(group.processes.count) süreç", "\(group.processes.count) processes", "Процессов: \(group.processes.count)")).font(.caption).foregroundStyle(.secondary)
                }
                Text(Fmt.bytes(group.total))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(hovering ? 0.045 : 0))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: toggle)

            if isExpanded {
                ForEach(group.processes) { p in
                    HStack(spacing: 8) {
                        Text(verbatim: String(p.pid)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        Text(p.name).font(.caption).lineLimit(1)
                        if let cwd = p.cwd {
                            Text(Fmt.displayPath(cwd)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Fmt.bytes(p.footprint)).font(.caption).monospacedDigit()
                        Button(L("Sonlandır", "Terminate", "Завершить")) { killPID(p.pid) }
                            .controlSize(.mini)
                            .help(L("Yalnızca bu alt süreci sonlandırır (SIGTERM)", "Terminates only this helper process (SIGTERM)", "Завершает только этот вспомогательный процесс (SIGTERM)"))
                            .disabled(group.isProtected)
                    }
                    .padding(.leading, 64)
                    .padding(.trailing, 12)
                    .padding(.vertical, 3)
                }
                .padding(.bottom, 4)
            }
        }
    }
}

/// Süreç butonlarının ne yaptığını tek satırda anlatır.
private struct ButtonLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            Label(L("Satırın üzerine gel:", "Hover a row:", "Наведите на строку:"), systemImage: "cursorarrow")
                .foregroundStyle(.secondary)
            item("arrow.clockwise", L("Yeniden Başlat", "Restart", "Перезапустить"), L("kapatıp hemen açar, RAM ve swap'i bırakır", "quits and reopens, releasing RAM and swap", "закрывает и открывает снова, освобождая RAM и своп"), .primary)
            item("xmark", L("Kapat", "Quit", "Закрыть"), L("düzgünce kapatır, kaydetmeyi sorar", "quits cleanly, asks to save", "закрывает корректно, предлагает сохранить"), .primary)
            item("exclamationmark.octagon", L("Zorla Kapat", "Force Quit", "Завершить принудительно"), L("donmuş uygulamayı anında öldürür, kaydedilmemiş veri gider", "kills a frozen app instantly, unsaved data is lost", "мгновенно завершает зависшее приложение, несохранённое теряется"), .red)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func item(_ symbol: String, _ title: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).fontWeight(.semibold).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}
