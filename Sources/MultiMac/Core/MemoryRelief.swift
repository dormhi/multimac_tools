import AppKit

/// Otomatik RAM rahatlatma.
///
/// Mole gibi swap/purge ile oynamaz (Mole bunu "sistem çökmesi riski" diye kaldırmış; `purge` ayrıca
/// root ister ve yalnızca dosya önbelleğini boşaltır, macOS bunu zaten kendisi yapar). Bunun yerine
/// gerçekten RAM açan tek güvenli şeyi yapar: bellek baskısı belirli bir süre yüksek kalırsa,
/// kullanıcının seçtiği ve uzun süredir arka planda duran uygulamaları *düzgünce* kapatır
/// (kaydedilmemiş belge varsa uygulama kendisi sorar).
@MainActor
final class MemoryRelief: ObservableObject {
    enum Trigger: String, CaseIterable, Identifiable {
        case pressureWarning, pressureCritical, swap
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pressureWarning: L("Bellek baskısı \"yüksek\" olunca", "When memory pressure is \"high\"", "Когда нагрузка на память «высокая»")
            case .pressureCritical: L("Bellek baskısı \"kritik\" olunca", "When memory pressure is \"critical\"", "Когда нагрузка на память «критическая»")
            case .swap: L("Swap belirli bir yüzdeyi geçince", "When swap passes a percentage", "Когда своп превышает порог")
            }
        }
    }

    struct Action: Identifiable {
        let id = UUID()
        let date: Date
        let apps: [String]
        let freed: UInt64
        let reason: String
    }

    // Ayar anahtarları
    nonisolated static let enabledKey = "ramRelief.enabled"
    nonisolated static let triggerKey = "ramRelief.trigger"
    nonisolated static let swapPercentKey = "ramRelief.swapPercent"
    nonisolated static let sustainKey = "ramRelief.sustainMinutes"
    nonisolated static let idleKey = "ramRelief.backgroundMinutes"
    nonisolated static let appsKey = "ramRelief.apps"
    nonisolated static let cooldownKey = "ramRelief.cooldownMinutes"
    nonisolated static let notifyKey = "ramRelief.notify"

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: false,
            triggerKey: Trigger.pressureWarning.rawValue,
            swapPercentKey: 80,
            sustainKey: 2,
            idleKey: 20,
            appsKey: [String](),
            cooldownKey: 30,
            notifyKey: true,
        ])
    }

    @Published private(set) var history: [Action] = []
    @Published private(set) var conditionSince: Date?

    private var lastActive: [String: Date] = [:]   // bundle path → son öne gelme
    private let startedAt = Date()
    private var lastRun: Date?
    private var timer: Timer?
    private weak var monitor: SystemMonitor?

    func start(monitor: SystemMonitor) {
        self.monitor = monitor
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let path = app?.bundleURL?.path else { return }
            Task { @MainActor in self?.lastActive[path] = Date() }
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Ayarlar

    private var d: UserDefaults { .standard }
    var isEnabled: Bool { d.bool(forKey: Self.enabledKey) }
    var trigger: Trigger { Trigger(rawValue: d.string(forKey: Self.triggerKey) ?? "") ?? .pressureWarning }
    var apps: [String] { Prefs.list(Self.appsKey) }

    /// Tetikleme koşulu şu an sağlanıyor mu?
    func conditionMet(_ m: MemorySnapshot) -> Bool {
        switch trigger {
        case .pressureWarning: return m.pressure != .normal
        case .pressureCritical: return m.pressure == .critical
        case .swap: return m.swapTotal > 0 && m.swapFraction * 100 >= Double(d.integer(forKey: Self.swapPercentKey))
        }
    }

    /// Listede olup şu an kapatılmaya uygun uygulamalar (arka planda, yeterince süredir kullanılmamış).
    func candidates(ignoreIdle: Bool = false) -> [NSRunningApplication] {
        let names = Set(apps)
        let idle = TimeInterval(max(0, d.integer(forKey: Self.idleKey)) * 60)
        let protected = Set(Prefs.list(Prefs.protectedApps))
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.localizedName, names.contains(name), !protected.contains(name),
                  app.activationPolicy == .regular, !app.isActive,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            if ignoreIdle { return true }
            let path = app.bundleURL?.path ?? ""
            let last = lastActive[path] ?? max(startedAt, app.launchDate ?? startedAt)
            return Date().timeIntervalSince(last) >= idle
        }
    }

    // MARK: Çalıştırma

    private func check() async {
        guard isEnabled, let m = monitor?.memory else { conditionSince = nil; return }
        guard conditionMet(m) else { conditionSince = nil; return }
        let since = conditionSince ?? Date()
        conditionSince = since
        let sustain = TimeInterval(max(0, d.integer(forKey: Self.sustainKey)) * 60)
        let cooldown = TimeInterval(max(1, d.integer(forKey: Self.cooldownKey)) * 60)
        guard Date().timeIntervalSince(since) >= sustain else { return }
        if let lastRun, Date().timeIntervalSince(lastRun) < cooldown { return }
        await relieve(reason: trigger.title, ignoreIdle: false)
    }

    /// Listedeki uygun uygulamaları kapatır. "Şimdi uygula" butonu ignoreIdle ile çağırır.
    @discardableResult
    func relieve(reason: String, ignoreIdle: Bool) async -> Action? {
        let targets = candidates(ignoreIdle: ignoreIdle)
        // Kapatılacak uygulama yoksa bekleme süresi başlamasın: biri boşta kalınca hemen kapatılabilsin.
        guard !targets.isEmpty else { return nil }
        lastRun = Date()
        let groups = await Task.detached(priority: .utility) { ProcessInspector.snapshot() }.value
        var freed: UInt64 = 0
        var names: [String] = []
        for app in targets {
            if let path = app.bundleURL?.path, let g = groups.first(where: { $0.bundlePath == path }) {
                freed += g.total
            }
            names.append(app.localizedName ?? "?")
            app.terminate()
        }
        let action = Action(date: Date(), apps: names, freed: freed, reason: reason)
        history.insert(action, at: 0)
        if history.count > 20 { history.removeLast() }
        if d.bool(forKey: Self.notifyKey) {
            Notifier.post(title: L("RAM rahatlatıldı", "Memory freed", "Память освобождена"),
                          body: L("\(names.joined(separator: ", ")) kapatıldı (~\(Fmt.memory(freed))). Neden: \(reason.lowercased())", "Quit \(names.joined(separator: ", ")) (~\(Fmt.memory(freed))). Reason: \(reason.lowercased())", "Закрыто: \(names.joined(separator: ", ")) (~\(Fmt.memory(freed))). Причина: \(reason.lowercased())"))
        }
        return action
    }
}
