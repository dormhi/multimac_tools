import Foundation

enum CleanupCategory: String, CaseIterable, Identifiable {
    case appCaches, devCaches, buildArtifacts, xcode, logs, downloads, largeFiles, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches: "Uygulama önbellekleri"
        case .devCaches: "Geliştirici önbellekleri"
        case .buildArtifacts: "Proje build kalıntıları"
        case .xcode: "Xcode ve simülatör"
        case .logs: "Günlükler"
        case .downloads: "İndirilenler"
        case .largeFiles: "Büyük ve eski dosyalar"
        case .trash: "Çöp Kutusu"
        }
    }

    var subtitle: String {
        switch self {
        case .appCaches: "Uygulamalar bu dosyaları gerektiğinde yeniden oluşturur"
        case .devCaches: "npm, pnpm, yarn, pip, Homebrew, Gradle… İndirmeler tekrar yapılabilir"
        case .buildArtifacts: "node_modules, .next, dist, target… Kullanılmayan projelerdekiler önceden seçili"
        case .xcode: "DerivedData, eski cihaz sembolleri, simülatör önbelleği"
        case .logs: "Uygulama ve çökme günlükleri"
        case .downloads: "Kurulum dosyaları (.dmg/.pkg) ve 90 günden eski indirmeler"
        case .largeFiles: "Ev klasöründeki çok büyük veya uzun süredir açılmamış dosyalar. Hiçbiri önceden seçili değil"
        case .trash: "Çöp Kutusu'ndaki dosyalar kalıcı olarak silinir"
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
        case .safe: "Güvenli"
        case .balanced: "Dengeli"
        case .aggressive: "Agresif"
        case .custom: "Özel"
        }
    }

    var help: String {
        switch self {
        case .safe: "Yalnızca otomatik temizliğe uygun önbellekler ve framework önbellekleri"
        case .balanced: "Önbellekler, Xcode verisi, kurulum dosyaları ve uzun süredir kullanılmayan projelerin kalıntıları"
        case .aggressive: "Tüm node_modules, .venv, build çıktıları, Playwright tarayıcıları ve Çöp Kutusu dahil. Kullanımdaki öğeler, eski indirmeler ve büyük dosyalar hariç"
        case .custom: "Elle yapılmış seçim"
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
        case .appCaches: "Uygulama önbellekleri"
        case .browserCaches: "Tarayıcı ve Electron önbellekleri"
        case .devToolCaches: "Geliştirici araç önbellekleri"
        case .packageDownloads: "Paket yöneticisi indirmeleri"
        case .frameworkCaches: "Proje framework önbellekleri"
        case .xcodeCaches: "Xcode ve simülatör önbellekleri"
        case .logs: "Eski günlükler ve çökme raporları"
        case .savedState: "Eski kayıtlı pencere durumları"
        }
    }

    var detail: String {
        switch self {
        case .appCaches: "~/Library/Caches altındaki üçüncü parti uygulama önbellekleri (Apple'ınkiler hariç)"
        case .browserCaches: "Chrome, Brave, Edge, Arc, VS Code, Slack, Discord… yalnızca Cache, GPUCache, Code Cache, Service Worker önbellekleri"
        case .devToolCaches: "eslint, prettier, vite, webpack, prisma, typescript, node-gyp, go-build, expo, android build cache…"
        case .packageDownloads: "npm, yarn, pnpm önbelleği, pip, uv, poetry, Homebrew, CocoaPods, Cargo indirmeleri (tekrar indirilebilir)"
        case .frameworkCaches: ".next, .turbo, .parcel-cache, .svelte-kit, .pytest_cache, .mypy_cache (içinde süreç çalışan projeler hariç)"
        case .xcodeCaches: "DerivedData, simülatör önbelleği, SwiftUI önizlemeleri (Xcode açıkken atlanır)"
        case .logs: "~/Library/Logs içinde belirlenen günden eski dosyalar"
        case .savedState: "Uygulamaların pencere geri yükleme verisi, 30 günden eski olanlar"
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
