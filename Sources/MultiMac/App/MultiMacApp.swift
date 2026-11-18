import SwiftUI
import AppKit

enum MainTab: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, storage, memory, automation, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Genel Bakış"
        case .cleanup: "Temizlik"
        case .storage: "Depolama"
        case .memory: "Bellek"
        case .automation: "Otomasyon"
        case .settings: "Ayarlar"
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
            let state = AppState.shared
            state.monitor.start()
            state.cleanup.startAutoSchedule()
            state.alerts.start(monitor: state.monitor)
            state.relief.start(monitor: state.monitor)
            if let dir = Snapshot.directory {
                Task { await Snapshot.run(to: dir) }
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
    }
}

@main
struct MultiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel().withStores(state)
        } label: {
            MenuBarLabel(monitor: state.monitor)
        }
        .menuBarExtraStyle(.window)

        Window("MultiMac", id: "main") {
            MainWindow().withStores(state)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
    }
}
