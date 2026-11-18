import SwiftUI
import AppKit

enum MainTab: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, storage, memory, automation, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L("Genel Bakış", "Overview", "Обзор")
        case .cleanup: L("Temizlik", "Cleanup", "Очистка")
        case .storage: L("Depolama", "Storage", "Хранилище")
        case .memory: L("Bellek", "Memory", "Память")
        case .automation: L("Otomasyon", "Automation", "Автоматизация")
        case .settings: L("Ayarlar", "Settings", "Настройки")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cleanup: "sparkles"
        case .storage: "square.grid.3x3.square"
        case .memory: "memorychip"
        case .automation: "wand.and.stars"
        case .settings: "gearshape"
        }
    }
}

/// Bir ekrandan diğerine "şurayı aç" isteği (ör. Genel Bakış'ta yüzdeye tıklanınca).
struct CleanupRequest: Equatable {
    let id = UUID()
    var category: CleanupCategory?
    var projects = false
    var preset: CleanupPreset?
    var search: String?
}

struct MemoryRequest: Equatable {
    let id = UUID()
    var search: String?
    var servers = false
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var tab: MainTab = .overview
    @Published var cleanupRequest: CleanupRequest?
    @Published var memoryRequest: MemoryRequest?
    let monitor = SystemMonitor()
    let cleanup = CleanupStore()
    let processes = ProcessStore()
    let storage = StorageStore()
    let servers = DevServerStore()
    let overview = OverviewStore()
    let alerts = MemoryAlerts()
    let relief = MemoryRelief()

    private var appliedLanguage = Lang.current

    /// Dil değişince tarama sonuçlarındaki metinleri (öğe adları, notlar, klasör grupları) yeni dille üretir.
    /// Menü paneli ve ana pencere ayrı ayrı haber verir; yalnızca ilki işlenir.
    func languageDidChange() {
        guard Lang.current != appliedLanguage else { return }
        appliedLanguage = Lang.current
        Task {
            await cleanup.refreshForLanguage()
            if overview.measuredAt != nil { await overview.measure() }
        }
    }

    private init() {
        cleanup.onDiskChanged = { [weak self] in
            self?.monitor.refreshDisk()
            self?.overview.invalidate()
        }
    }

    func showCleanup(category: CleanupCategory? = nil, projects: Bool = false,
                     preset: CleanupPreset? = nil, search: String? = nil) {
        cleanupRequest = CleanupRequest(category: category, projects: projects, preset: preset, search: search)
        tab = .cleanup
    }

    func showMemory(search: String? = nil, servers: Bool = false) {
        memoryRequest = MemoryRequest(search: search, servers: servers)
        tab = .memory
    }

    /// path nil ise tüm diski tarar (daha önce taranmadıysa).
    func showStorage(path: String? = nil) {
        if let path {
            storage.scan(path: path)
        } else if storage.root == nil && !storage.isScanning {
            storage.scope = .disk
            storage.startScan()
        }
        tab = .storage
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        if SelfTest.isRequested {
            Task { @MainActor in await SelfTest.run() }
            return
        }
        MainActor.assumeIsolated {
            AppAppearance.apply()
            let state = AppState.shared
            state.monitor.start()
            state.cleanup.startAutoSchedule()
            state.alerts.start(monitor: state.monitor)
            state.relief.start(monitor: state.monitor)
            if let dir = Snapshot.directory {
                Task { await Snapshot.run(to: dir) }
            }
            // Hata ayıklama: --tab memory → ana pencere o sekmede açılır (performans ölçümü için).
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let tab = MainTab(rawValue: args[i + 1]) {
                state.tab = tab
            }
        }
        Notifier.requestAuthorization()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension View {
    func withStores(_ state: AppState) -> some View {
        environmentObject(state)
            .environmentObject(state.monitor)
            .environmentObject(state.cleanup)
            .environmentObject(state.processes)
            .environmentObject(state.storage)
            .environmentObject(state.servers)
            .environmentObject(state.overview)
            .environmentObject(state.relief)
            .buttonStyle(.glass)
    }
}

@main
struct MultiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            LanguageRoot { MenuBarPanel().withStores(state) }
        } label: {
            MenuBarLabel(monitor: state.monitor)
        }
        .menuBarExtraStyle(.window)

        Window("MultiMac", id: "main") {
            LanguageRoot { MainWindow().withStores(state) }
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
    }
}

/// Dil değişince altındaki her şeyi yeni dille baştan çizer.
struct LanguageRoot<Content: View>: View {
    @AppStorage(Prefs.appLanguage) private var language = AppLanguage.system.rawValue
    @ViewBuilder let content: () -> Content

    var body: some View {
        let _ = Lang.sync(language)
        content()
            .id(language)
            .environment(\.locale, Lang.locale)
            .onChange(of: language) { AppState.shared.languageDidChange() }
    }
}
