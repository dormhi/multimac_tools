import Foundation

/// Swap, bellek baskısı ve uygulama başına bellek eşiklerini izleyip bildirim gönderir.
/// Her uyarı türü için bekleme süresi (cooldown) vardır, böylece sürekli bildirim yağmaz.
@MainActor
final class MemoryAlerts {
    private var lastFired: [String: Date] = [:]
    private var timer: Timer?
    private var tick = 0
    private weak var monitor: SystemMonitor?

    func start(monitor: SystemMonitor) {
        self.monitor = monitor
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() async {
        guard let m = monitor?.memory else { return }
        let d = UserDefaults.standard
        tick += 1

        if d.bool(forKey: Prefs.alertSwapEnabled) {
            let limit = Double(d.integer(forKey: Prefs.alertSwapPercent)) / 100
            if m.swapTotal > 0, m.swapFraction >= limit {
                fire("swap", title: "Swap %\(Int(m.swapFraction * 100)) dolu",
                     body: "\(Fmt.bytes(m.swapUsed)) bellek diske taşmış durumda. Kullanmadığın uygulamaları kapatmak sistemi hızlandırır.")
            }
        }

        if d.bool(forKey: Prefs.alertPressureEnabled) {
            let onWarning = d.bool(forKey: Prefs.alertPressureOnWarning)
            if m.pressure == .critical || (onWarning && m.pressure == .warning) {
                fire("pressure", title: "Bellek baskısı \(m.pressure.title.lowercased())",
                     body: "\(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total)) kullanımda. MultiMac menüsünden ağır uygulamaları kapatabilirsin.")
            }
        }

        // Uygulama taraması daha pahalı: dakikada bir
        if d.bool(forKey: Prefs.alertAppEnabled), tick % 2 == 0 {
            let limit = UInt64(max(1, d.integer(forKey: Prefs.alertAppGB))) * 1_000_000_000
            let groups = await Task.detached(priority: .utility) { ProcessInspector.snapshot() }.value
            for g in groups where !g.isProtected && g.total >= limit {
                fire("app:" + g.id, title: "\(g.name) \(Fmt.bytes(g.total)) bellek kullanıyor",
                     body: "Belirlediğin \(d.integer(forKey: Prefs.alertAppGB)) GB sınırını aştı (\(g.processes.count) süreç).")
            }
        }
    }

    private func fire(_ key: String, title: String, body: String) {
        let cooldown = Double(max(5, UserDefaults.standard.integer(forKey: Prefs.alertCooldownMinutes))) * 60
        if let last = lastFired[key], Date().timeIntervalSince(last) < cooldown { return }
        lastFired[key] = Date()
        Notifier.post(title: title, body: body)
    }
}
