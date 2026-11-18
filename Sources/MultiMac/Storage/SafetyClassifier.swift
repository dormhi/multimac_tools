import SwiftUI

enum SafetyLevel: Int, Comparable {
    case junk, normal, caution, protected

    static func < (a: SafetyLevel, b: SafetyLevel) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .protected: "Sistem / Korunan"
        case .caution: "Dikkat"
        case .junk: "Silinebilir"
        case .normal: "Kullanıcı dosyası"
        }
    }

    var symbol: String {
        switch self {
        case .protected: "lock.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .junk: "trash.fill"
        case .normal: "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .protected: .red
        case .caution: .orange
        case .junk: .green
        case .normal: .blue
        }
    }
}

struct SafetyInfo {
    let level: SafetyLevel
    let reason: String
}

enum SafetyClassifier {
    static let dataPrefix = "/System/Volumes/Data"
    static let home = NSHomeDirectory()

    static func logicalPath(_ p: String) -> String {
        if p == dataPrefix { return "/" }
        if p.hasPrefix(dataPrefix + "/") { return String(p.dropFirst(dataPrefix.count)) }
        return p
    }

    private static let rootFolders: Set<String> = [
        "/", "/Users", home, home + "/Library", "/Library", "/private", "/private/var",
        "/System", "/usr", "/Applications", "/opt", "/Volumes",
    ]

    private static let protectedPrefixes: [(String, String)] = [
        ("/System", "macOS sistem dosyaları (SIP korumalı)"),
        ("/bin", "Unix sistem araçları"),
        ("/sbin", "Unix sistem araçları"),
        ("/private/var/vm", "Swap ve uyku görüntüsü. macOS yönetir, RAM baskısı azalınca küçülür"),
        ("/private/var/db", "Sistem veritabanları"),
        ("/private/etc", "Sistem yapılandırması"),
        ("/private/var/root", "Root kullanıcısının verisi"),
        ("/Library/Apple", "Apple sistem bileşenleri"),
        ("/Library/Extensions", "Çekirdek uzantıları"),
        ("/Library/LaunchDaemons", "Sistem servisleri"),
        ("/Library/Keychains", "Sistem anahtar zinciri"),
        ("/Library/Security", "Güvenlik bileşenleri"),
        ("/.Spotlight-V100", "Spotlight dizini"),
        ("/.fseventsd", "Dosya sistemi olay kaydı"),
        ("/.DocumentRevisions-V100", "Belge sürüm geçmişi"),
        ("/.PreviousSystemInformation", "Sistem güncelleme bilgisi"),
        (home + "/Library/Keychains", "Parolalar ve sertifikalar"),
        (home + "/Library/Mobile Documents", "iCloud Drive"),
        (home + "/Library/CloudStorage", "Bulut depolama klasörleri"),
        (home + "/Library/Preferences", "Uygulama ayarları"),
        (home + "/Library/Mail", "E-posta arşivi"),
        (home + "/Library/Messages", "Mesaj arşivi"),
        (home + "/Library/Group Containers", "Uygulamaların paylaşılan verisi"),
        (home + "/.ssh", "SSH anahtarları"),
        (home + "/.gnupg", "GPG anahtarları"),
    ]

    private static let junkPrefixes: [(String, String)] = [
        (home + "/Library/Caches", "Önbellek. Uygulamalar gerektiğinde yeniden oluşturur"),
        (home + "/Library/Logs", "Günlük dosyaları"),
        (home + "/Library/Developer/Xcode/DerivedData", "Xcode build kalıntıları"),
        (home + "/Library/Developer/Xcode/iOS DeviceSupport", "Eski iOS cihaz sembolleri"),
        (home + "/Library/Developer/CoreSimulator/Caches", "Simülatör önbelleği"),
        (home + "/.npm/_cacache", "npm önbelleği"),
        (home + "/.npm/_npx", "npx önbelleği"),
        (home + "/Library/pnpm/store", "pnpm paket deposu"),
        (home + "/.pnpm-store", "pnpm paket deposu"),
        (home + "/.gradle/caches", "Gradle önbelleği"),
        (home + "/.cache", "Araç önbellekleri"),
        (home + "/.Trash", "Çöp Kutusu"),
    ]

    /// Klasörün kendisi değil, yalnızca içeriği silinmeli.
    private static let containerFolders: Set<String> = [
        home + "/Library/Caches", home + "/Library/Logs", home + "/.Trash", home + "/.cache",
        home + "/Library/Developer/Xcode/DerivedData",
    ]

    private static let junkNames: [String: String] = [
        "node_modules": "Bağımlılıklar. npm/pnpm install ile geri gelir",
        ".next": "Next.js build önbelleği",
        ".nuxt": "Nuxt build önbelleği",
        ".turbo": "Turborepo önbelleği",
        ".parcel-cache": "Parcel önbelleği",
        ".svelte-kit": "SvelteKit build çıktısı",
        "__pycache__": "Python bytecode önbelleği",
        ".pytest_cache": "pytest önbelleği",
        ".mypy_cache": "mypy önbelleği",
        ".ruff_cache": "ruff önbelleği",
        "DerivedData": "Xcode build kalıntıları",
        ".build": "Swift build kalıntıları",
    ]

    static func classify(_ rawPath: String) -> SafetyInfo {
        let p = logicalPath(rawPath)
        func under(_ base: String) -> Bool { p == base || p.hasPrefix(base + "/") }
        let name = (p as NSString).lastPathComponent

        if rootFolders.contains(p) {
            return SafetyInfo(level: .protected, reason: "Temel sistem klasörü. Asla tümüyle silinmemeli")
        }
        if under("/usr") && !under("/usr/local") {
            return SafetyInfo(level: .protected, reason: "Unix sistem dosyaları")
        }
        for (prefix, reason) in protectedPrefixes where under(prefix) {
            return SafetyInfo(level: .protected, reason: reason)
        }
        if p.hasSuffix(".photoslibrary") || p.contains(".photoslibrary/") {
            return SafetyInfo(level: .protected, reason: "Fotoğraflar arşivi")
        }

        if containerFolders.contains(p) {
            return SafetyInfo(level: .caution, reason: "İçeriği silinebilir ama klasörün kendisi kalmalı")
        }
        for (prefix, reason) in junkPrefixes where under(prefix) {
            return SafetyInfo(level: .junk, reason: reason)
        }
        if p.contains("/Data/Library/Caches"), under(home + "/Library/Containers") {
            return SafetyInfo(level: .junk, reason: "Uygulama önbelleği")
        }
        let comps = p.split(separator: "/")
        if comps.contains("node_modules") {
            return SafetyInfo(level: .junk, reason: junkNames["node_modules"]!)
        }
        if let reason = junkNames[name] {
            return SafetyInfo(level: .junk, reason: reason)
        }
        if under(home + "/Downloads"), ["dmg", "pkg", "xip", "iso"].contains((name as NSString).pathExtension.lowercased()) {
            return SafetyInfo(level: .junk, reason: "Kurulum dosyası. Uygulama kurulduysa gereksiz")
        }

        if under("/private/var/folders") {
            return SafetyInfo(level: .caution, reason: "Geçici dosyalar. macOS yönetir, açık uygulamalar kullanıyor olabilir")
        }
        if under(home + "/Library") {
            return SafetyInfo(level: .caution, reason: "Uygulama verisi. Silmek uygulamayı sıfırlayabilir veya veri kaybettirebilir")
        }
        if p.hasSuffix(".app"), under("/Applications") || under(home + "/Applications") {
            return SafetyInfo(level: .caution, reason: "Uygulama. Silmek onu kaldırır (ayar/veri dosyaları kalır)")
        }
        if under("/Applications") {
            return SafetyInfo(level: .caution, reason: "Uygulama paketinin parçası")
        }
        if under("/Library") || under("/private") || under("/opt") || under("/usr/local") {
            return SafetyInfo(level: .caution, reason: "Sistem genelinde kurulu yazılım veya veri")
        }
        if [home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Pictures",
            home + "/Movies", home + "/Music"].contains(p) {
            return SafetyInfo(level: .caution, reason: "Kişisel ana klasör. İçindekileri tek tek inceleyin")
        }
        if p.hasPrefix(home + "/."), comps.count == 3 {
            return SafetyInfo(level: .caution, reason: "Gizli yapılandırma klasörü")
        }
        return SafetyInfo(level: .normal, reason: "Kişisel dosya")
    }
}
