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
            if let advice = memoryAdvice(monitor.memory, top: processes.groups.first(where: { !$0.isProtected })) {
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
            IconTile(symbol: "sparkles", color: .indigo, size: 24)
            Text("MultiMac").font(.headline)
            Spacer()
            Button { open(.settings) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Ayarlar")
        }
    }

    private var gauges: some View {
        let m = monitor.memory
        let d = monitor.disk
        return HStack(spacing: 8) {
            StatTile(title: "RAM", value: "\(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))",
                     caption: "Baskı: \(m.pressure.title)", fraction: m.usedFraction, color: m.pressure.color)
                .hoverHighlight(cornerRadius: 10)
                .onTapGesture { open(.memory) }
            StatTile(title: "Swap", value: Fmt.bytes(m.swapUsed),
                     caption: "/ \(Fmt.bytes(m.swapTotal))", fraction: m.swapFraction,
                     color: m.swapFraction > 0.7 ? .red : m.swapFraction > 0.4 ? .orange : .green)
                .hoverHighlight(cornerRadius: 10)
                .onTapGesture { open(.memory) }
            StatTile(title: "Disk", value: "\(Fmt.bytes(d.available)) boş",
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(cleanup.isBusy)

            Text(quickSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quickTitle: String {
        switch cleanup.quickState {
        case .scanning: "Taranıyor…"
        case .cleaning: "Temizleniyor…"
        default: cleanup.isScanning || cleanup.isCleaning ? "Detaylı temizlik sürüyor…" : "Hızlı Temizlik"
        }
    }

    private var quickSubtitle: String {
        if case let .done(freed, items) = cleanup.quickState {
            return freed > 0 ? "✓ \(Fmt.bytes(freed)) yer açıldı (\(items) öğe)" : "✓ Temizlenecek bir şey kalmamış"
        }
        if let date = cleanup.lastAutoDate {
            return "Son temizlik \(Fmt.relative(date)) · \(Fmt.bytes(cleanup.lastAutoBytes))"
        }
        return "Önbellekleri ve güvenli build kalıntılarını siler"
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("En çok bellek kullananlar").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Tümü") { open(.memory) }.buttonStyle(.link).font(.caption)
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
            Button { open(.overview) } label: { Label("Genel Bakış", systemImage: "gauge.with.dots.needle.67percent") }
            Button { open(.cleanup) } label: { Label("Temizlik", systemImage: "list.bullet.rectangle") }
            Button { open(.storage) } label: { Label("Depolama", systemImage: "square.grid.3x3.square") }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("MultiMac'ten çık")
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
            Button(action: quit) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(group.isProtected ? Color.secondary : Color.red)
            }
            .buttonStyle(.plain)
            .opacity(hovering && !group.isProtected ? 1 : 0)
            .disabled(group.isProtected)
            .help("Kapat")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
