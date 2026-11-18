import Foundation

enum Fmt {
    /// Finder gibi 1000 tabanlı birimler; ondalık ayırıcı ve "Sıfır KB" uygulama diline göre.
    static func bytes(_ b: Int64) -> String {
        let v = Double(max(0, b))
        if v == 0 { return L("Sıfır KB", "Zero KB", "Ноль КБ") }
        if v < 1000 { return "\(Int(v)) " + L("bayt", "bytes", "байт") }
        var x = v / 1000
        var unit = 0
        while x >= 1000 && unit < 3 { x /= 1000; unit += 1 }
        let digits = unit == 0 ? 0 : unit == 1 ? 1 : 2
        let f = numberFormatters[Lang.localeID]?[digits] ?? enNumber[digits]
        let units = Lang.isRussian ? ["КБ", "МБ", "ГБ", "ТБ"] : ["KB", "MB", "GB", "TB"]
        return (f.string(from: NSNumber(value: x)) ?? String(x)) + " " + units[unit]
    }

    static func bytes(_ b: UInt64) -> String { bytes(Int64(clamping: b)) }

    private static func numberFormatters(_ id: String) -> [NumberFormatter] {
        (0...2).map { digits in
            let f = NumberFormatter()
            f.locale = Locale(identifier: id)
            f.numberStyle = .decimal
            f.maximumFractionDigits = digits
            f.minimumFractionDigits = 0
            return f
        }
    }
    private static let enNumber = numberFormatters("en_US")
    private static let numberFormatters: [String: [NumberFormatter]] = [
        "tr_TR": numberFormatters("tr_TR"), "en_US": enNumber, "ru_RU": numberFormatters("ru_RU"),
    ]

    /// Türkçede "%80", İngilizce ve Rusçada "80%".
    static func percent(_ v: Double) -> String {
        let n = String(Int((max(0, v) * 100).rounded()))
        return Lang.isTurkish ? "%" + n : n + "%"
    }

    private static func relativeFormatter(_ id: String) -> RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: id)
        f.unitsStyle = .full
        return f
    }
    nonisolated(unsafe) private static let relativeFormatters: [String: RelativeDateTimeFormatter] = [
        "tr_TR": relativeFormatter("tr_TR"), "en_US": relativeFormatter("en_US"), "ru_RU": relativeFormatter("ru_RU"),
    ]

    static func relative(_ d: Date) -> String {
        (relativeFormatters[Lang.localeID] ?? relativeFormatter("en_US")).localizedString(for: d, relativeTo: Date())
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
    static let appearance = "appearance"        // system / light / dark
    static let appLanguage = "appLanguage"      // system / tr / en
    static let autoCleanEnabled = "autoCleanEnabled"   // eski; yalnızca geçiş için okunur
    /// Otomatik önbellek temizliğinin ana anahtarı. Zamanlama ve disk eşiği bunun altında çalışır.
    static let autoStorageEnabled = "autoStorage.enabled"
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

    /// Eski sürümde zamanlama ve disk eşiği ayrı ayrı açılıyordu. Kullanıcı birini açıkça açtıysa
    /// yeni ana anahtar da açık başlasın; hiç dokunmadıysa kapalı kalsın.
    private static func migrateAutoStorage() {
        let d = UserDefaults.standard
        guard d.object(forKey: autoStorageEnabled) == nil,
              let saved = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") else { return }
        let wasOn = (saved[autoCleanEnabled] as? Bool) == true || (saved[lowDiskEnabled] as? Bool) == true
        if saved[autoCleanEnabled] != nil || saved[lowDiskEnabled] != nil { d.set(wasOn, forKey: autoStorageEnabled) }
        // Yalnızca disk eşiği açıktı: zamanlama yeni modelde "zamanlama yok" olur.
        if wasOn, (saved[autoCleanEnabled] as? Bool) == false { d.set(0, forKey: autoCleanIntervalHours) }
    }

    static func register() {
        AutoSettings.register()
        MemoryRelief.registerDefaults()
        let home = NSHomeDirectory()
        let candidates = ["Projects", "Developer", "Code", "dev", "src", "GitHub", "Documents/GitHub"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
        migrateAutoStorage()
        UserDefaults.standard.register(defaults: [
            autoStorageEnabled: false,
            appearance: "system",
            appLanguage: "system",
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

// MARK: - Dil

/// Uygulamanın dili. "Sistem": macOS dili Türkçe veya Rusçaysa o, değilse İngilizce.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, tr, en, ru
    var id: String { rawValue }

    /// Dil adları her zaman kendi dilinde yazılır ki yanlış dilde kalan kullanıcı da bulabilsin.
    var title: String {
        switch self {
        case .system: L("Sistem dili", "System language", "Язык системы")
        case .tr: "Türkçe"
        case .en: "English"
        case .ru: "Русский"
        }
    }
}

/// Arayüzün o anki dili (Sistem seçeneği çözülmüş hali).
enum UILanguage {
    case tr, en, ru
}

enum Lang {
    /// Her metin çağrısında UserDefaults okumamak için önbellek; `sync` ile güncellenir.
    nonisolated(unsafe) private(set) static var current = resolve(UserDefaults.standard.string(forKey: Prefs.appLanguage))

    static var isTurkish: Bool { current == .tr }
    static var isRussian: Bool { current == .ru }

    static func resolve(_ raw: String?) -> UILanguage {
        switch AppLanguage(rawValue: raw ?? "") ?? .system {
        case .tr: return .tr
        case .en: return .en
        case .ru: return .ru
        case .system:
            let first = Locale.preferredLanguages.first ?? ""
            if first.hasPrefix("tr") { return .tr }
            if first.hasPrefix("ru") { return .ru }
            return .en
        }
    }

    /// Kök görünümler body içinde çağırır; dil değişince bütün arayüz yeni dille yeniden çizilir.
    @discardableResult
    static func sync(_ raw: String) -> UILanguage {
        current = resolve(raw)
        return current
    }

    static var localeID: String {
        switch current {
        case .tr: "tr_TR"
        case .en: "en_US"
        case .ru: "ru_RU"
        }
    }

    static var locale: Locale { Locale(identifier: localeID) }
}

/// Arayüz metni: Türkçesi, İngilizcesi ve Rusçası yan yana yazılır, o anki dile göre biri döner.
/// Rusçası verilmemişse İngilizcesi kullanılır. Argümanlar @autoclosure: yalnızca seçili dildeki metin
/// hazırlanır (içindeki Fmt.bytes gibi biçimlendirmeler üç kez değil bir kez çalışır).
func L(_ tr: @autoclosure () -> String, _ en: @autoclosure () -> String, _ ru: @autoclosure () -> String? = nil) -> String {
    switch Lang.current {
    case .tr: tr()
    case .en: en()
    case .ru: ru() ?? en()
    }
}

/// Sabit tablolarda (statik kurallar) Türkçe tutulan metinleri kullanıldığı anda çevirir.
/// Önce sözlüğe, sonra "X önbelleği" → "X cache" / "Кэш X" gibi kalıplara bakar; bulamazsa metni olduğu gibi döner.
func LT(_ tr: String) -> String {
    switch Lang.current {
    case .tr:
        return tr
    case .en:
        if let en = Glossary.english[tr] ?? SafetyText.english[tr] { return en }
        for rule in Glossary.suffixes where tr.hasSuffix(rule.tr) {
            return String(tr.dropLast(rule.tr.count)) + rule.en
        }
    case .ru:
        if let ru = Glossary.russian[tr] ?? SafetyText.russian[tr] { return ru }
        for rule in Glossary.suffixes where tr.hasSuffix(rule.tr) {
            return rule.ru + String(tr.dropLast(rule.tr.count))
        }
        if let en = Glossary.english[tr] ?? SafetyText.english[tr] { return en }
    }
    return tr
}

enum Glossary {
    /// İngilizcede sona, Rusçada başa gelir: "npm önbelleği" → "npm cache" / "Кэш npm".
    static let suffixes: [(tr: String, en: String, ru: String)] = [
        (" önbelleği", " cache", "Кэш "), (" indirmeleri", " downloads", "Загрузки "),
        (" deposu", " repository", "Хранилище "), (" tarayıcıları", " browsers", "Браузеры "),
        (" modelleri", " models", "Модели "), (" başlıkları", " headers", "Заголовки "),
        (" paketleri", " packages", "Пакеты "), (" günlükleri", " logs", "Журналы "),
        (" sürümleri", " versions", "Версии "),
    ]

    static let english: [String: String] = [
        "Sonraki kurulumda paketler yeniden indirilir": "Packages are downloaded again on the next install",
        "Expo native modül önbelleği": "Expo native module cache",
        "Expo simülatör önbelleği": "Expo simulator cache",
        "Expo sürüm önbelleği": "Expo version cache",
        "Yeniden derleme uzun sürer": "Rebuilding takes a long time",
        "Bağımlılıklar yeniden indirilir": "Dependencies are downloaded again",
        "Testler için yeniden indirilmesi gerekir": "Must be downloaded again for tests",
        "Yeniden indirilmesi gerekir": "Must be downloaded again",
        "İndirilmiş yapay zekâ modelleri": "Downloaded AI models",
        "Bağımlılıklar": "Dependencies",
        "Framework önbelleği": "Framework cache",
        "Build çıktısı": "Build output",
        "Python araç önbelleği": "Python tool cache",
        "Python sanal ortamı": "Python virtual environment",
        "Paketler yeniden kurulmalı": "Packages must be reinstalled",
        "npm/pnpm install ile geri gelir": "npm/pnpm install brings it back",
        "pod install ile geri gelir": "pod install brings it back",
    ]

    static let russian: [String: String] = [
        "Sonraki kurulumda paketler yeniden indirilir": "Пакеты будут скачаны заново при следующей установке",
        "Expo native modül önbelleği": "Кэш нативных модулей Expo",
        "Expo simülatör önbelleği": "Кэш симулятора Expo",
        "Expo sürüm önbelleği": "Кэш версий Expo",
        "Yeniden derleme uzun sürer": "Пересборка займёт много времени",
        "Bağımlılıklar yeniden indirilir": "Зависимости будут скачаны заново",
        "Testler için yeniden indirilmesi gerekir": "Для тестов придётся скачать заново",
        "Yeniden indirilmesi gerekir": "Придётся скачать заново",
        "İndirilmiş yapay zekâ modelleri": "Скачанные модели ИИ",
        "Bağımlılıklar": "Зависимости",
        "Framework önbelleği": "Кэш фреймворка",
        "Build çıktısı": "Результаты сборки",
        "Python araç önbelleği": "Кэш инструментов Python",
        "Python sanal ortamı": "Виртуальное окружение Python",
        "Paketler yeniden kurulmalı": "Пакеты нужно будет переустановить",
        "npm/pnpm install ile geri gelir": "Восстанавливается через npm/pnpm install",
        "pod install ile geri gelir": "Восстанавливается через pod install",
        "node-gyp başlıkları": "Заголовки node-gyp",
        "npx paketleri": "Пакеты npx",
        "Gradle sürümleri": "Версии Gradle",
    ]
}
