import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    /// 0: yalnızca simge (çentikli ekranlarda gizlenmez), 1: RAM yüzdesi, 2: RAM + boş disk
    @AppStorage(Prefs.menuBarStyle) private var style = 0

    var body: some View {
        let m = monitor.memory
        let icon = m.pressure == .normal ? "memorychip" : "exclamationmark.triangle.fill"
        switch style {
        case 1:
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text(Fmt.percent(m.usedFraction)).monospacedDigit()
            }
        case 2:
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text("\(Fmt.percent(m.usedFraction)) \(Fmt.bytes(monitor.disk.available))").monospacedDigit()
            }
        default:
            Image(systemName: icon)
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var processes: ProcessStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.menuTopCount) private var topCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            gauges
            quickClean
            if let insight = swapInsight(monitor.memory, history: monitor.history, groups: processes.groups),
               insight.level == .churning {
                SwapInsightCard(insight: insight, compact: true) { processes.restart($0) }
            } else if let advice = memoryAdvice(monitor.memory, top: processes.groups.first(where: { !$0.isProtected })) {
                Label(advice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            topApps
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 350)
        .task { await processes.autoRefresh(every: 3) }
    }

    private var header: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            Text("MultiMac").font(.headline)
            Spacer()
            Button { open(.settings) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help(L("Ayarlar", "Settings"))
        }
    }

    private var gauges: some View {
        let m = monitor.memory
        let d = monitor.disk
        return HStack(spacing: 8) {
            StatTile(title: "RAM", value: "\(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))",
                     caption: L("Baskı: \(m.pressure.title)", "Pressure: \(m.pressure.title)"), fraction: m.usedFraction, color: m.pressure.color)
                .hoverHighlight(cornerRadius: 10)
                .onTapGesture { open(.memory) }
            StatTile(title: "Swap", value: Fmt.bytes(m.swapUsed),
                     caption: "/ \(Fmt.bytes(m.swapTotal))", fraction: m.swapFraction,
                     color: m.swapFraction > 0.7 ? .red : m.swapFraction > 0.4 ? .orange : .green)
                .hoverHighlight(cornerRadius: 10)
                .onTapGesture { open(.memory) }
            StatTile(title: "Disk", value: L("\(Fmt.bytes(d.available)) boş", "\(Fmt.bytes(d.available)) free"),
                     caption: "/ \(Fmt.bytes(d.total))", fraction: d.usedFraction,
                     color: d.available < 15_000_000_000 ? .red : d.available < 40_000_000_000 ? .orange : .green)
                .hoverHighlight(cornerRadius: 10)
                .onTapGesture { open(.overview) }
        }
    }

    private var quickClean: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await cleanup.quickClean() }
            } label: {
                HStack {
                    if cleanup.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(quickTitle).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(cleanup.isBusy)

            Text(quickSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quickTitle: String {
        switch cleanup.quickState {
        case .scanning: L("Taranıyor…", "Scanning…")
        case .cleaning: L("Temizleniyor…", "Cleaning…")
        default: cleanup.isScanning || cleanup.isCleaning ? L("Detaylı temizlik sürüyor…", "Detailed cleanup running…") : L("Hızlı Temizlik", "Quick Clean")
        }
    }

    private var quickSubtitle: String {
        if case let .done(freed, items) = cleanup.quickState {
            return freed > 0 ? L("✓ \(Fmt.bytes(freed)) yer açıldı (\(items) öğe)", "✓ Freed \(Fmt.bytes(freed)) (\(items) items)") : L("✓ Temizlenecek bir şey kalmamış", "✓ Nothing left to clean")
        }
        if let date = cleanup.lastAutoDate {
            return L("Son temizlik \(Fmt.relative(date)) · \(Fmt.bytes(cleanup.lastAutoBytes))", "Last cleaned \(Fmt.relative(date)) · \(Fmt.bytes(cleanup.lastAutoBytes))")
        }
        return L("Önbellekleri ve güvenli build kalıntılarını siler", "Deletes caches and safe build leftovers")
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("En çok bellek kullananlar", "Using the most memory")).font(.subheadline.weight(.semibold))
                Spacer()
                Button(L("Tümü", "All")) { open(.memory) }.buttonStyle(.link).font(.caption)
            }
            if processes.groups.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            ForEach(processes.groups.prefix(max(1, topCount))) { group in
                ProcessQuickRow(group: group, fraction: Double(group.total) / Double(max(1, monitor.memory.total))) {
                    processes.quit(group)
                }
                .onTapGesture { openMemory(search: group.name) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button { open(.overview) } label: { Label(L("Genel Bakış", "Overview"), systemImage: "gauge.with.dots.needle.67percent") }
            Button { open(.cleanup) } label: { Label(L("Temizlik", "Cleanup"), systemImage: "list.bullet.rectangle") }
            Button { open(.storage) } label: { Label(L("Depolama", "Storage"), systemImage: "square.grid.3x3.square") }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Label(L("Çık", "Quit"), systemImage: "power") }
                .help(L("MultiMac'ten çık", "Quit MultiMac"))
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private func open(_ tab: MainTab) {
        state.tab = tab
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openMemory(search: String) {
        state.showMemory(search: search)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ProcessQuickRow: View {
    let group: ProcessGroup
    let fraction: Double
    let quit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundlePath: group.bundlePath, size: 18)
            Text(group.name).lineLimit(1)
            if group.processes.count > 1 {
                Text("×\(group.processes.count)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.percent(fraction)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.blue)
            Text(Fmt.bytes(group.total)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .trailing)
            Button(L("Kapat", "Quit"), action: quit)
                .controlSize(.mini)
                .opacity(hovering && !group.isProtected ? 1 : 0)
                .disabled(group.isProtected)
                .help(L("Uygulamayı düzgünce kapat", "Quit the app gracefully"))
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
