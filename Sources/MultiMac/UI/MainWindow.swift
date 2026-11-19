import SwiftUI
import AppKit

struct MainWindow: View {
    @EnvironmentObject private var state: AppState
    /// Kenar çubuğu düğmesi kenar çubuğunu gizlemek yerine yalnızca simgelerin kaldığı dar görünüme geçirir.
    /// Dar genişlik (84) pencere düğmelerinin (trafik ışıkları) kenar çubuğuna sığması için seçildi.
    @AppStorage("sidebarCompact") private var compact = false
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView(compact: compact)
                .navigationSplitViewColumnWidth(min: compact ? 84 : 205, ideal: compact ? 84 : 220, max: compact ? 84 : 280)
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
                    case .smart: SmartCleanupView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(state.tab.title)
        }
        .frame(minWidth: 980, minHeight: 640)
        // Sistemin kenar çubuğu düğmesi kenar çubuğunu tamamen gizliyor ve bu isteği güvenilir biçimde
        // bildirmiyor; yerine aynı yerde kendi düğmemiz: dar (yalnızca simge) ↔ geniş.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { compact.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.automatic)
                .help(compact ? L("Kenar çubuğunu genişlet", "Expand sidebar", "Развернуть боковую панель")
                              : L("Kenar çubuğunu daralt", "Collapse sidebar", "Свернуть боковую панель"))
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        .onChange(of: visibility) { _, new in
            // Kenar çubuğu hiçbir yoldan (menü, kısayol) tamamen gizlenmesin: dar görünüme geçsin.
            guard new != .all else { return }
            visibility = .all
            compact = true
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Kenar çubuğu ayrı görünüm: RAM/disk her güncellendiğinde yalnızca bu kısım yeniden çizilir.
private struct SidebarView: View {
    let compact: Bool
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var smart: SmartStore

    var body: some View {
        // List(selection:) yerine düz butonlar: tıklama ve seçili vurgusu her durumda çalışır.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MainTab.allCases.filter { $0 != .settings }) { tab in
                    sidebarRow(tab)
                }
                Divider().padding(.vertical, 8).padding(.horizontal, compact ? 4 : 6)
                sidebarRow(.settings)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .top) { brand }
        .safeAreaInset(edge: .bottom) { if !compact { sidebarStatus } }
    }

    /// Dar görünüm: yalnızca simge; rozet küçük renkli noktaya dönüşür, ad ipucu olarak çıkar.
    private func compactRow(_ tab: MainTab) -> some View {
        let selected = state.tab == tab
        return Button {
            state.tab = tab
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 38, height: 32)
                .overlay(alignment: .topTrailing) {
                    if let b = badge(for: tab) {
                        Circle().fill(b.color == .secondary ? Color.accentColor : b.color)
                            .frame(width: 7, height: 7)
                            .offset(x: -4, y: 5)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.09 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .frame(maxWidth: .infinity)
        .help(badge(for: tab).map { "\(tab.title) · \($0.text)" } ?? tab.title)
        .keyboardShortcut(shortcut(for: tab), modifiers: .command)
    }

    @ViewBuilder private func sidebarRow(_ tab: MainTab) -> some View {
        if compact { compactRow(tab) } else { fullRow(tab) }
    }

    private func fullRow(_ tab: MainTab) -> some View {
        let selected = state.tab == tab
        return Button {
            state.tab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                Text(tab.title)
                    .fontWeight(selected ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if let b = badge(for: tab) {
                    Text(b.text)
                        .lineLimit(1)
                        .fixedSize()
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(b.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(b.color.opacity(0.15)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
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
        case .smart:
            let n = smart.suggestions.count
            return n == 0 ? nil : ("\(n)", .indigo)
        default:
            return nil
        }
    }

    @ViewBuilder private var brand: some View {
        if compact {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .help("MultiMac")
        } else {
            fullBrand
        }
    }

    private var fullBrand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("MultiMac").font(.headline)
                Text(L("Mac bakım merkezi", "Mac care center", "Центр ухода за Mac")).font(.caption).foregroundStyle(.secondary)
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
            miniBar(title: L("Swap", "Swap", "Своп"), value: Fmt.bytes(m.swapUsed), fraction: m.swapFraction,
                    color: m.swapFraction > 0.7 ? .red : m.swapFraction > 0.4 ? .orange : .green)
            miniBar(title: L("Disk", "Disk", "Диск"), value: L("\(Fmt.bytes(d.available)) boş", "\(Fmt.bytes(d.available)) free", "Свободно \(Fmt.bytes(d.available))"), fraction: d.usedFraction,
                    color: d.available < 15_000_000_000 ? .red : d.available < 40_000_000_000 ? .orange : .green)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Surface.inset))
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
                        Capsule().fill(color).frame(width: max(3, g.size.width * fraction))
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
        // Sade başlık: Apple'ın Ayarlar/Müzik başlıkları gibi büyük yazı, renkli ikon yok.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

/// Kenar çubuğu satırı: üzerine gelince hafif gri vurgu, basınca biraz koyulaşır.
private struct SidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(configuration: configuration)
    }
}

private struct SidebarRowBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.045 : 0))
            )
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}
