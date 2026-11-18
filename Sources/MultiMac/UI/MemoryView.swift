import SwiftUI
import Charts

struct MemoryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var processes: ProcessStore
    @EnvironmentObject private var servers: DevServerStore
    @State private var showAppServers = false
    @State private var search = ""
    @State private var devOnly = false
    @State private var expanded: Set<String> = []
    @State private var confirmForce: ProcessGroup?
    @State private var scrollTarget: String?

    private func handleRequest() {
        guard let r = state.memoryRequest else { return }
        state.memoryRequest = nil
        search = r.search ?? ""
        devOnly = false
        if let q = r.search, let g = processes.groups.first(where: { $0.name == q }) { expanded.insert(g.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            scrollTarget = r.servers ? "servers" : (r.search != nil ? "processes" : nil)
        }
    }

    var body: some View {
        let m = monitor.memory
        VStack(spacing: 0) {
            PageHeader(title: "Bellek", subtitle: "Baskı: \(m.pressure.title) · \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total)) kullanımda",
                       symbol: "memorychip", color: .blue) {
                Badge(text: "Baskı: \(m.pressure.title)", color: m.pressure.color, symbol: "circle.fill")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
                        HStack(alignment: .top, spacing: 16) {
                            breakdown(m).card()
                            chart.card()
                        }
                        serverList.card().id("servers")
                        processList.card().id("processes")
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
        .task { await processes.autoRefresh(every: 3) }
        .task { await servers.autoRefresh(every: 5) }
        .alert("Zorla kapatılsın mı?", isPresented: Binding(get: { confirmForce != nil },
                                                           set: { if !$0 { confirmForce = nil } }),
               presenting: confirmForce) { g in
            Button("Zorla Kapat", role: .destructive) { processes.quit(g, force: true) }
            Button("Vazgeç", role: .cancel) {}
        } message: { g in
            Text("\(g.name) kaydedilmemiş verileriyle birlikte hemen sonlandırılır.")
        }
    }

    private func breakdown(_ m: MemorySnapshot) -> some View {
        let items: [(String, UInt64, Color, String)] = [
            ("Uygulama", m.app, .blue, "Açık uygulamaların kullandığı bellek"),
            ("Sistem (wired)", m.wired, .purple, "Çekirdek ve sürücüler, boşaltılamaz"),
            ("Sıkıştırılmış", m.compressed, .orange, "RAM'e sığdırmak için sıkıştırılmış veri"),
            ("Dosya önbelleği", m.cached, .gray, "macOS gerektiğinde anında boşaltır"),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Dağılım", symbol: "chart.bar.fill", color: .blue,
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
                LegendRow(color: .red, title: "Swap", subtitle: "RAM'e sığmayıp diske taşan · toplam \(Fmt.bytes(m.swapTotal))",
                          fraction: m.swapFraction, value: Fmt.bytes(m.swapUsed))
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "Son 30 dakika", symbol: "waveform.path.ecg", color: .red,
                       subtitle: "Kullanılan RAM ve swap (GB)")
            Chart {
                ForEach(chartPoints) { p in
                    AreaMark(x: .value("Zaman", p.date), y: .value("GB", p.usedGB),
                             series: .value("Tür", "Kullanılan"))
                        .foregroundStyle(by: .value("Tür", "Kullanılan RAM"))
                        .opacity(0.5)
                    LineMark(x: .value("Zaman", p.date), y: .value("GB", p.swapGB),
                             series: .value("Tür", "Swap"))
                        .foregroundStyle(by: .value("Tür", "Swap"))
                }
            }
            .chartForegroundStyleScale(["Kullanılan RAM": Color.blue, "Swap": Color.red])
            .chartYAxisLabel("GB")
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

    private var visibleServers: [ListeningServer] {
        servers.servers.filter { showAppServers || !$0.isApp }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(title: "Dev server'lar", symbol: "server.rack", color: .teal,
                           subtitle: "Port dinleyen süreçler; unutulanları buradan kapat")
                Toggle("Uygulama ve sistem süreçlerini de göster", isOn: $showAppServers).toggleStyle(.checkbox)
            }
            VStack(spacing: 0) {
                if !servers.loaded {
                    ProgressView().controlSize(.small).padding(10)
                } else if visibleServers.isEmpty {
                    Text("Port dinleyen geliştirici süreci yok")
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
                                if s.isDeveloperTool { Badge(text: "Geliştirici", color: .purple) }
                            }
                            Text(verbatim: s.cwd.map(Fmt.displayPath) ?? "PID " + String(s.pid))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(s.ports.prefix(4), id: \.self) { port in
                                Button(":" + String(port)) { servers.openInBrowser(port) }
                                    .buttonStyle(.bordered)
                                    .help("http://localhost:" + String(port) + " adresini tarayıcıda aç")
                            }
                        }
                        Text(s.uptime).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            .help("Çalışma süresi")
                        Text(Fmt.bytes(s.footprint)).monospacedDigit().frame(width: 76, alignment: .trailing)
                        Button("Durdur") { servers.stop(s) }
                            .help("Sürece kapanmasını söyler (SIGTERM); dev server düzgünce kapanır")
                        Button(role: .destructive) { servers.stop(s, force: true) } label: {
                            Text("Zorla Durdur").foregroundStyle(.red)
                        }
                            .help("Süreci anında öldürür (SIGKILL); yanıt vermeyen sunucular için")
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
                CardHeader(title: "Uygulamalar ve süreçler", symbol: "square.stack.3d.up.fill", color: .indigo,
                           subtitle: "\(processes.groups.count) grup · sağ tık: korunanlara ekle")
                Toggle("Sadece geliştirici süreçleri", isOn: $devOnly).toggleStyle(.checkbox)
                TextField("Ara", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
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
                        .contextMenu {
                            let isUser = userProtected.contains(group.name)
                            if isUser || !group.isProtected {
                                Button(isUser ? "Korumayı kaldır" : "Korunanlara ekle (asla kapatma önerme)") {
                                    toggleProtected(group)
                                }
                            }
                        }
                    Divider()
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            if filtered.isEmpty {
                Text("Eşleşen süreç yok").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ProcessGroupRow: View {
    let group: ProcessGroup
    let isExpanded: Bool
    let toggle: () -> Void
    let quit: () -> Void
    let forceQuit: () -> Void
    let restart: () -> Void
    let isRestarting: Bool
    let killPID: (pid_t) -> Void

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
                        if group.isDeveloperTool { Badge(text: "Geliştirici", color: .purple) }
                        if group.isProtected { Badge(text: "Sistem", color: .secondary, symbol: "lock.fill") }
                    }
                    if let cwd = group.processes.first?.cwd, !group.isApp {
                        Text(Fmt.displayPath(cwd)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text("\(group.processes.count) süreç").font(.caption).foregroundStyle(.secondary)
                Text(Fmt.bytes(group.total))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                if group.isApp {
                    if isRestarting {
                        ProgressView().controlSize(.small)
                        Text("Yeniden başlıyor…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { restart() } label: { Label("Yeniden Başlat", systemImage: "arrow.clockwise") }
                            .help("Düzgünce kapatıp hemen tekrar açar; RAM'de ve swap'te tuttuğu her şeyi bırakır")
                            .disabled(group.isProtected)
                    }
                }
                Button { quit() } label: { Label("Kapat", systemImage: "xmark") }
                    .help("Uygulamaya kapanmasını söyler; kaydedilmemiş belge varsa uygulama sorar")
                    .disabled(group.isProtected)
                Button(role: .destructive) { forceQuit() } label: {
                    Label("Zorla Kapat", systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                }
                    .help("Yanıt vermeyen uygulamayı anında sonlandırır; kaydedilmemiş veriler kaybolur")
                    .disabled(group.isProtected)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
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
                        Button("Sonlandır") { killPID(p.pid) }
                            .controlSize(.mini)
                            .help("Yalnızca bu alt süreci sonlandırır (SIGTERM)")
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
            item("arrow.clockwise", "Yeniden Başlat", "kapatıp hemen açar, RAM ve swap'i bırakır", .primary)
            item("xmark", "Kapat", "düzgünce kapatır, kaydetmeyi sorar", .primary)
            item("exclamationmark.octagon", "Zorla Kapat", "donmuş uygulamayı anında öldürür, kaydedilmemiş veri gider", .red)
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
