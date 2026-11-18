import SwiftUI
import AppKit

struct MainWindow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            // GeometryReader, pencerenin min. boyut hesabını burada keser. Olmadan SwiftUI her
            // güncellemede kaydırılan içeriğin tamamını ölçüyordu (boştayken bile ~%15 CPU, takılma).
            GeometryReader { _ in
                Group {
                    switch state.tab {
                    case .overview: OverviewView()
                    case .cleanup: CleanupView()
                    case .storage: StorageView()
                    case .memory: MemoryView()
                    case .automation: AutomationView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(state.tab.title)
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Kenar çubuğu ayrı görünüm: RAM/disk her güncellendiğinde yalnızca bu kısım yeniden çizilir.
private struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var cleanup: CleanupStore

    var body: some View {
        // List(selection:) yerine düz butonlar: tıklama ve seçili vurgusu her durumda çalışır.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MainTab.allCases.filter { $0 != .settings }) { tab in
                    sidebarRow(tab)
                }
                Divider().padding(.vertical, 8).padding(.horizontal, 6)
                sidebarRow(.settings)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .top) { brand }
        .safeAreaInset(edge: .bottom) { sidebarStatus }
    }

    private func sidebarRow(_ tab: MainTab) -> some View {
        let selected = state.tab == tab
        return Button {
            state.tab = tab
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: tab.symbol, color: tab.color, size: 24)
                Text(tab.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let b = badge(for: tab) {
                    Text(b.text)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(b.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(b.color.opacity(0.15)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut(for: tab), modifiers: .command)
    }

    private func shortcut(for tab: MainTab) -> KeyEquivalent {
        KeyEquivalent(Character(String((MainTab.allCases.firstIndex(of: tab) ?? 0) + 1)))
    }

    private func badge(for tab: MainTab) -> (text: String, color: Color)? {
        switch tab {
        case .cleanup:
            return cleanup.items.isEmpty ? nil : (Fmt.bytes(cleanup.totalSize), .secondary)
        case .memory:
            let p = monitor.memory.pressure
            return p == .normal ? nil : (p.title, p.color)
        default:
            return nil
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "sparkles", color: .indigo, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("MultiMac").font(.headline)
                Text("Mac bakım merkezi").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var sidebarStatus: some View {
        let m = monitor.memory
        let d = monitor.disk
        return VStack(alignment: .leading, spacing: 8) {
            miniBar(title: "RAM", value: Fmt.percent(m.usedFraction), fraction: m.usedFraction, color: m.pressure.color)
            miniBar(title: "Swap", value: Fmt.bytes(m.swapUsed), fraction: m.swapFraction,
                    color: m.swapFraction > 0.7 ? .red : m.swapFraction > 0.4 ? .orange : .green)
            miniBar(title: "Disk", value: "\(Fmt.bytes(d.available)) boş", fraction: d.usedFraction,
                    color: d.available < 15_000_000_000 ? .red : d.available < 40_000_000_000 ? .orange : .green)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .padding(10)
        .onTapGesture { state.tab = .overview }
    }

    private func miniBar(title: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color.gradient).frame(width: max(3, g.size.width * fraction))
                    }
            }
            .frame(height: 5)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var symbol: String? = nil
    var color: Color = .accentColor
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol { IconTile(symbol: symbol, color: color, size: 36) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
