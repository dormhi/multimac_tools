import Foundation

enum CleanupCategory: String, CaseIterable, Identifiable {
    case appCaches, devCaches, buildArtifacts, xcode, logs, downloads, largeFiles, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches: L("Uygulama önbellekleri", "App caches")
        case .devCaches: L("Geliştirici önbellekleri", "Developer caches")
        case .buildArtifacts: L("Proje build kalıntıları", "Project build leftovers")
        case .xcode: L("Xcode ve simülatör", "Xcode and Simulator")
        case .logs: L("Günlükler", "Logs")
        case .downloads: L("İndirilenler", "Downloads")
        case .largeFiles: L("Büyük ve eski dosyalar", "Large and old files")
        case .trash: L("Çöp Kutusu", "Trash")
        }
    }

    var subtitle: String {
        switch self {
        case .appCaches: L("Uygulamalar bu dosyaları gerektiğinde yeniden oluşturur", "Apps recreate these files when needed")
        case .devCaches: L("npm, pnpm, yarn, pip, Homebrew, Gradle… İndirmeler tekrar yapılabilir", "npm, pnpm, yarn, pip, Homebrew, Gradle… Downloads can be fetched again")
        case .buildArtifacts: L("node_modules, .next, dist, target… Kullanılmayan projelerdekiler önceden seçili", "node_modules, .next, dist, target… Preselected in unused projects")
        case .xcode: L("DerivedData, eski cihaz sembolleri, simülatör önbelleği", "DerivedData, old device symbols, Simulator cache")
        case .logs: L("Uygulama ve çökme günlükleri", "App and crash logs")
        case .downloads: L("Kurulum dosyaları (.dmg/.pkg) ve 90 günden eski indirmeler", "Installers (.dmg/.pkg) and downloads older than 90 days")
        case .largeFiles: L("Ev klasöründeki çok büyük veya uzun süredir açılmamış dosyalar. Hiçbiri önceden seçili değil", "Very large or long-unopened files in your home folder. None are preselected")
        case .trash: L("Çöp Kutusu'ndaki dosyalar kalıcı olarak silinir", "Files in the Trash are deleted permanently")
        }
    }

    var symbol: String {
        switch self {
        case .appCaches: "square.stack.3d.up.fill"
        case .devCaches: "shippingbox.fill"
        case .buildArtifacts: "hammer.fill"
        case .xcode: "swift"
        case .logs: "doc.text.fill"
        case .downloads: "arrow.down.circle.fill"
        case .largeFiles: "doc.badge.clock.fill"
        case .trash: "trash.fill"
        }
    }
}

struct CleanupItem: Identifiable, Hashable {
    let id: String
    let urls: [URL]
    let title: String
    let detail: String
    let category: CleanupCategory
    var size: Int64 = 0
    /// Otomatik / hızlı temizlikte silinebilir mi? (kural var + kullanımda değil)
    var autoEligible: Bool
    /// Bu öğeyi otomatik temizliğe sokan kural; nil ise asla otomatik silinmez.
    var autoRule: AutoRule?
    /// Yalnızca bu kadar günden eski dosyalar silinir (günlükler, kayıtlı uygulama durumları).
    var minAgeDays: Int?
    let defaultSelected: Bool
    /// true: klasörün kendisi kalır, yalnızca içi silinir.
    let contentsOnly: Bool
    var note: String?
    var lastUsed: Date?
    /// Build kalıntısının ait olduğu proje klasörü
    var project: String?
    /// Açık bir uygulama veya çalışan bir süreç kullanıyor
    var inUse = false
    /// Bir öğenin içinden açılmış alt öğe ise üst öğenin kimliği
    var parentID: String?
    /// Tanınmayan veya veri içerebilecek öğe (ör. modeller, arşivler): agresif kip bile seçmez
    var sensitive = false
    /// Tarama sırasında belirlenir; satır her çizildiğinde dosya sistemine sorulmasın diye.
    var isDirectory = false

    var isAppleCache: Bool { urls.first?.lastPathComponent.hasPrefix("com.apple.") ?? false }

    init(urls: [URL], title: String, detail: String? = nil, category: CleanupCategory,
         autoEligible: Bool, defaultSelected: Bool, contentsOnly: Bool,
         note: String? = nil, lastUsed: Date? = nil, project: String? = nil, inUse: Bool = false,
         parentID: String? = nil) {
        self.id = urls.map(\.path).joined(separator: "|")
        self.urls = urls
        self.title = title
        self.detail = detail ?? urls.first.map { Fmt.displayPath($0.path) } ?? ""
        self.category = category
        self.autoEligible = autoEligible
        self.defaultSelected = defaultSelected
        self.contentsOnly = contentsOnly
        self.note = note
        self.lastUsed = lastUsed
        self.project = project
        self.inUse = inUse
        self.parentID = parentID
    }
}

enum CleanupPreset: String, CaseIterable, Identifiable {
    case safe, balanced, aggressive, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: L("Güvenli", "Safe")
        case .balanced: L("Dengeli", "Balanced")
        case .aggressive: L("Agresif", "Aggressive")
        case .custom: L("Özel", "Custom")
        }
    }

    var help: String {
        switch self {
        case .safe: L("Yalnızca otomatik temizliğe uygun önbellekler ve framework önbellekleri", "Only caches eligible for automatic cleanup and framework caches")
        case .balanced: L("Önbellekler, Xcode verisi, kurulum dosyaları ve uzun süredir kullanılmayan projelerin kalıntıları", "Caches, Xcode data, installers and leftovers of long-unused projects")
        case .aggressive: L("Tüm node_modules, .venv, build çıktıları, Playwright tarayıcıları ve Çöp Kutusu dahil. Kullanımdaki öğeler, eski indirmeler ve büyük dosyalar hariç", "Includes every node_modules, .venv, build output, Playwright browsers and the Trash. Excludes items in use, old downloads and large files")
        case .custom: L("Elle yapılmış seçim", "Manual selection")
        }
    }

    func includes(_ item: CleanupItem) -> Bool {
        switch self {
        case .safe: return item.autoEligible
        case .balanced: return item.defaultSelected
        case .aggressive:
            if item.inUse || item.sensitive || item.isAppleCache || item.category == .largeFiles { return false }
            if item.category == .downloads { return item.defaultSelected }
            return true
        case .custom: return false
        }
    }
}

struct CleanupResult {
    var trashed = false
    var freed: Int64 = 0
    var cleanedItems = 0
    var failedPaths: [String] = []
    var date = Date()
}

/// Otomatik temizliğin her biri ayrı ayrı açılıp kapatılabilen kuralları.
/// Hepsi yalnızca yeniden oluşturulabilen önbellek/geçici dosyaları hedefler; sistem dosyalarına dokunmaz.
enum AutoRule: String, CaseIterable, Identifiable {
    case appCaches, browserCaches, devToolCaches, packageDownloads, frameworkCaches, xcodeCaches, logs, savedState

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches: L("Uygulama önbellekleri", "App caches")
        case .browserCaches: L("Tarayıcı ve Electron önbellekleri", "Browser and Electron caches")
        case .devToolCaches: L("Geliştirici araç önbellekleri", "Developer tool caches")
        case .packageDownloads: L("Paket yöneticisi indirmeleri", "Package manager downloads")
        case .frameworkCaches: L("Proje framework önbellekleri", "Project framework caches")
        case .xcodeCaches: L("Xcode ve simülatör önbellekleri", "Xcode and Simulator caches")
        case .logs: L("Eski günlükler ve çökme raporları", "Old logs and crash reports")
        case .savedState: L("Eski kayıtlı pencere durumları", "Old saved window states")
        }
    }

    /// Otomasyon ekranındaki kutucuklar için kısa ad.
    var shortTitle: String {
        switch self {
        case .appCaches: L("Uygulama önbellekleri", "App caches")
        case .browserCaches: L("Tarayıcı önbellekleri", "Browser caches")
        case .devToolCaches: L("Geliştirici araçları", "Developer tools")
        case .packageDownloads: L("Paket indirmeleri", "Package downloads")
        case .frameworkCaches: L("Proje önbellekleri", "Project caches")
        case .xcodeCaches: "Xcode"
        case .logs: L("Eski günlükler", "Old logs")
        case .savedState: L("Eski pencere durumları", "Old window states")
        }
    }

    var detail: String {
        switch self {
        case .appCaches: L("~/Library/Caches altındaki üçüncü parti uygulama önbellekleri (Apple'ınkiler hariç)", "Third-party app caches in ~/Library/Caches (not Apple's)")
        case .browserCaches: L("Chrome, Brave, Edge, Arc, VS Code, Slack, Discord… yalnızca Cache, GPUCache, Code Cache, Service Worker önbellekleri", "Chrome, Brave, Edge, Arc, VS Code, Slack, Discord… only Cache, GPUCache, Code Cache and Service Worker caches")
        case .devToolCaches: L("eslint, prettier, vite, webpack, prisma, typescript, node-gyp, go-build, expo, android build cache…", "eslint, prettier, vite, webpack, prisma, typescript, node-gyp, go-build, expo, android build cache…")
        case .packageDownloads: L("npm, yarn, pnpm önbelleği, pip, uv, poetry, Homebrew, CocoaPods, Cargo indirmeleri (tekrar indirilebilir)", "npm, yarn and pnpm caches, pip, uv, poetry, Homebrew, CocoaPods and Cargo downloads (can be downloaded again)")
        case .frameworkCaches: L(".next, .turbo, .parcel-cache, .svelte-kit, .pytest_cache, .mypy_cache (içinde süreç çalışan projeler hariç)", ".next, .turbo, .parcel-cache, .svelte-kit, .pytest_cache, .mypy_cache (skipping projects with a running process)")
        case .xcodeCaches: L("DerivedData, simülatör önbelleği, SwiftUI önizlemeleri (Xcode açıkken atlanır)", "DerivedData, Simulator cache, SwiftUI previews (skipped while Xcode is open)")
        case .logs: L("~/Library/Logs içinde belirlenen günden eski dosyalar", "Files in ~/Library/Logs older than the set number of days")
        case .savedState: L("Uygulamaların pencere geri yükleme verisi, 30 günden eski olanlar", "Apps' window restore data older than 30 days")
        }
    }

    var symbol: String {
        switch self {
        case .appCaches: "square.stack.3d.up.fill"
        case .browserCaches: "globe"
        case .devToolCaches: "wrench.and.screwdriver.fill"
        case .packageDownloads: "shippingbox.fill"
        case .frameworkCaches: "hammer.fill"
        case .xcodeCaches: "swift"
        case .logs: "doc.text.fill"
        case .savedState: "macwindow.on.rectangle"
        }
    }

    var key: String { "autoRule." + rawValue }
}

enum AutoSettings {
    static let skipRunningApps = "autoSkipRunningApps"
    static let logAgeDays = "autoLogAgeDays"

    static func register() {
        var defaults: [String: Any] = [skipRunningApps: true, logAgeDays: 7]
        for rule in AutoRule.allCases { defaults[rule.key] = true }
        UserDefaults.standard.register(defaults: defaults)
    }

    static func isEnabled(_ rule: AutoRule) -> Bool { UserDefaults.standard.bool(forKey: rule.key) }
    static var skipsRunningApps: Bool { UserDefaults.standard.bool(forKey: skipRunningApps) }
    static var logDays: Int { max(1, UserDefaults.standard.integer(forKey: logAgeDays)) }
}
