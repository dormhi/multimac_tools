import Foundation

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    static func bytes(_ b: UInt64) -> String { bytes(Int64(clamping: b)) }

    static func percent(_ v: Double) -> String {
        "%" + String(Int((max(0, v) * 100).rounded()))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.unitsStyle = .full
        return f
    }()

    static func relative(_ d: Date) -> String {
        relativeFormatter.localizedString(for: d, relativeTo: Date())
    }

    static let home = NSHomeDirectory()

    /// /Users/x/Projects → ~/Projects, /System/Volumes/Data/Users → /Users
    static func displayPath(_ p: String) -> String {
        let logical = SafetyClassifier.logicalPath(p)
        if logical == home { return "~" }
        if logical.hasPrefix(home + "/") { return "~" + logical.dropFirst(home.count) }
        return logical
    }

    static func days(since date: Date?) -> Int? {
        guard let date else { return nil }
        return Int(Date().timeIntervalSince(date) / 86_400)
    }
}

enum Prefs {
    static let autoCleanEnabled = "autoCleanEnabled"
    static let autoCleanIntervalHours = "autoCleanIntervalHours"
    static let lowDiskEnabled = "lowDiskEnabled"
    static let lowDiskThresholdGB = "lowDiskThresholdGB"
    static let staleDays = "staleDays"
    static let projectRoots = "projectRoots"
    static let lastAutoCleanDate = "lastAutoCleanDate"
    static let lastAutoCleanBytes = "lastAutoCleanBytes"
    static let menuBarStyle = "menuBarStyle"
    static let notifyAfterClean = "notifyAfterClean"
    // Temizlik
    static let exclusions = "exclusions"
    static let cleanupPreset = "cleanupPreset"
    static let deleteToTrash = "deleteToTrash"
    static let largeFileMinMB = "largeFileMinMB"
    static let oldFileDays = "oldFileDays"
    static let oldFileMinMB = "oldFileMinMB"
    // Bellek
    static let alertSwapEnabled = "alertSwapEnabled"
    static let alertSwapPercent = "alertSwapPercent"
    static let alertPressureEnabled = "alertPressureEnabled"
    static let alertPressureOnWarning = "alertPressureOnWarning"
    static let alertAppEnabled = "alertAppEnabled"
    static let alertAppGB = "alertAppGB"
    static let alertCooldownMinutes = "alertCooldownMinutes"
    static let protectedApps = "protectedApps"
    static let menuTopCount = "menuTopCount"

    static func register() {
        AutoSettings.register()
        MemoryRelief.registerDefaults()
        let home = NSHomeDirectory()
        let candidates = ["Projects", "Developer", "Code", "dev", "src", "GitHub", "Documents/GitHub"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
        UserDefaults.standard.register(defaults: [
            autoCleanEnabled: true,
            autoCleanIntervalHours: 6,
            lowDiskEnabled: true,
            lowDiskThresholdGB: 10,
            staleDays: 30,
            projectRoots: candidates,
            menuBarStyle: 0,
            notifyAfterClean: true,
            exclusions: [String](),
            cleanupPreset: "balanced",
            deleteToTrash: false,
            largeFileMinMB: 500,
            oldFileDays: 180,
            oldFileMinMB: 50,
            alertSwapEnabled: true,
            alertSwapPercent: 90,
            alertPressureEnabled: true,
            alertPressureOnWarning: false,
            alertAppEnabled: true,
            alertAppGB: 3,
            alertCooldownMinutes: 60,
            protectedApps: [String](),
            menuTopCount: 6,
        ])
    }

    static func list(_ key: String) -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func setList(_ key: String, _ value: [String]) { UserDefaults.standard.set(value, forKey: key) }

    static var roots: [String] {
        get { UserDefaults.standard.stringArray(forKey: projectRoots) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: projectRoots) }
    }
}

/// "Asla dokunma" listesi. Hem tarayıcı hem silme motoru buna uyar.
enum Exclusions {
    static var all: [String] { Prefs.list(Prefs.exclusions) }

    static func add(_ path: String) {
        var list = all
        guard !list.contains(path) else { return }
        list.append(path)
        Prefs.setList(Prefs.exclusions, list)
    }

    static func remove(_ path: String) {
        Prefs.setList(Prefs.exclusions, all.filter { $0 != path })
    }

    /// Yolun kendisi veya bir üst klasörü hariç tutulmuş mu?
    static func isExcluded(_ path: String, in list: [String] = all) -> Bool {
        list.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Yolun altında hariç tutulmuş bir şey var mı? (Bu durumda klasör bütün olarak silinmemeli.)
    static func containsExcluded(_ path: String, in list: [String] = all) -> Bool {
        list.contains { $0.hasPrefix(path + "/") }
    }
}
