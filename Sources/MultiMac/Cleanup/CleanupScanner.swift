import AppKit

struct CleanupContext {
    let home: URL
    let runningBundleIDs: Set<String>
    /// Küçük harfli uygulama adları ve paket adları
    let runningNames: Set<String>
    /// Uygulama dışı süreçlerin (node, python…) çalışma dizinleri
    let busyDirectories: [String]
    let projectRoots: [URL]
    let staleDays: Int

    @MainActor
    static func current() async -> CleanupContext {
        let apps = NSWorkspace.shared.runningApplications
        var names = Set<String>()
        for app in apps {
            if let n = app.localizedName { names.insert(n.lowercased()) }
            if let b = app.bundleURL { names.insert(b.deletingPathExtension().lastPathComponent.lowercased()) }
        }
        let busy = await Task.detached(priority: .utility) { ProcessInspector.busyDirectories() }.value
        return CleanupContext(
            home: URL(fileURLWithPath: NSHomeDirectory()),
            runningBundleIDs: Set(apps.compactMap(\.bundleIdentifier)),
            runningNames: names,
            busyDirectories: busy,
            projectRoots: Prefs.roots.map { URL(fileURLWithPath: $0) },
            staleDays: max(1, UserDefaults.standard.integer(forKey: Prefs.staleDays)))
    }

    func isBusy(_ dir: String) -> Bool {
        busyDirectories.contains { $0 == dir || $0.hasPrefix(dir + "/") }
    }

    func isAppRunning(name: String) -> Bool {
        let n = name.lowercased()
        guard n.count >= 3 else { return false }
        return runningBundleIDs.contains(name)
            || runningBundleIDs.contains { name.hasPrefix($0 + ".") }
            || runningNames.contains(n)
            || runningNames.contains { $0.contains(n) || n.contains($0) && $0.count >= 4 }
    }
}

enum CleanupScanner {
    private static let fm = FileManager.default
    private static let minimumSize: Int64 = 1_000_000

    /// Tüm adayları bulur ve boyutlarını ölçer. autoOnly: yalnızca otomatik temizliğe uygunlar.
    static func scan(context: CleanupContext, autoOnly: Bool) async -> [CleanupItem] {
        let excluded = Exclusions.all
        var items = await Task.detached(priority: .utility) { candidates(context, autoOnly: autoOnly) }.value
        assignRules(&items, context)
        if autoOnly { items = items.filter(\.autoEligible) }
        items = items.filter { item in !item.urls.contains { Exclusions.isExcluded($0.path, in: excluded) } }
        let measured = await measure(items)
        return measured.filter { $0.size >= minimumSize }.sorted { $0.size > $1.size }
    }

    static func measure(_ items: [CleanupItem]) async -> [CleanupItem] {
        var result = items
        await withTaskGroup(of: (Int, Int64).self) { group in
            var next = 0
            func add() {
                let i = next
                next += 1
                let urls = items[i].urls
                let age = items[i].minAgeDays
                group.addTask(priority: .utility) {
                    (i, urls.reduce(Int64(0)) { $0 + DirectorySizer.allocatedSize($1.path, olderThanDays: age) })
                }
            }
            for _ in 0..<min(4, items.count) { add() }
            while let (i, size) = await group.next() {
                result[i].size = size
                result[i].isDirectory = result[i].urls.count > 1
                    || ((try? result[i].urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                if next < items.count { add() }
            }
        }
        return result
    }

    // MARK: - Otomatik temizlik kuralları

    /// Paket yöneticisi indirmeleri (ev klasörüne göre)
    private static let packagePaths: Set<String> = [
        ".npm/_cacache", ".npm/_npx", "Library/pnpm/store", ".pnpm-store", "Library/Caches/pnpm", "Library/Caches/Yarn",
        ".yarn/berry/cache", ".bun/install/cache", "Library/Caches/Homebrew", "Library/Caches/pip", ".cache/pip",
        ".cache/uv", "Library/Caches/CocoaPods", ".cargo/registry/cache", "Library/Caches/pypoetry", ".cache/poetry",
        ".bundle/cache", ".gem/specs", ".composer/cache", "Library/Caches/composer", ".rustup/downloads",
        ".tnpm/_cacache", ".pyenv/cache", ".rbenv/cache",
    ]

    /// Her öğeye kuralını ve yaş sınırını atar; ayarlara göre otomatik temizliğe girip girmeyeceğine karar verir.
    static func assignRules(_ items: inout [CleanupItem], _ ctx: CleanupContext) {
        let home = ctx.home.path + "/"
        for i in items.indices {
            // Kaynağı "otomatik olabilir" demeyen öğeler (node_modules, indirilenler, büyük dosyalar…) asla kurala girmez.
            guard items[i].autoEligible, let first = items[i].urls.first else {
                items[i].autoRule = nil
                items[i].autoEligible = false
                continue
            }
            let rel = first.path.hasPrefix(home) ? String(first.path.dropFirst(home.count)) : first.path
            let rule: AutoRule
            switch items[i].category {
            case .appCaches: rule = rel.hasPrefix("Library/Application Support/") ? .browserCaches : .appCaches
            case .devCaches: rule = packagePaths.contains(rel) ? .packageDownloads : .devToolCaches
            case .buildArtifacts: rule = .frameworkCaches
            case .xcode: rule = .xcodeCaches
            case .logs: rule = rel.hasPrefix("Library/Saved Application State") ? .savedState : .logs
            default:
                items[i].autoRule = nil
                items[i].autoEligible = false
                continue
            }
            items[i].autoRule = rule
            if rule == .logs { items[i].minAgeDays = AutoSettings.logDays }
            if rule == .savedState { items[i].minAgeDays = 30 }
            // Çalışan dev server'ın .next'i veya açık Xcode'un DerivedData'sı her durumda atlanır;
            // açık uygulamaların önbelleği ayara bağlı.
            let alwaysGuard = rule == .frameworkCaches || rule == .xcodeCaches
            let blocked = items[i].inUse && (alwaysGuard || AutoSettings.skipsRunningApps)
            items[i].autoEligible = AutoSettings.isEnabled(rule) && !blocked
        }
    }

    // MARK: - Aday üretimi

    static func candidates(_ ctx: CleanupContext, autoOnly: Bool) -> [CleanupItem] {
        var items: [CleanupItem] = []
        items += devCaches(ctx)
        items += appCaches(ctx)
        items += browserCaches(ctx)
        items += electronCaches(ctx)
        items += xcode(ctx)
        items += logs(ctx)
        items += savedState(ctx)
        items += buildArtifacts(ctx, autoOnly: autoOnly)
        if !autoOnly {
            items += downloads(ctx)
            items += largeFiles(ctx)
            items += trash(ctx)
        }
        // Aynı yol iki kez gelmesin
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    private static func children(_ url: URL, keys: [URLResourceKey] = [.isDirectoryKey]) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            .map { ($0.isDirectory ?? false) && !($0.isSymbolicLink ?? false) } ?? false
    }

    /// ~/Library/Caches altında ayrı ele alınan klasörler
    private static let devCacheNames: Set<String> = [
        "Homebrew", "pip", "Yarn", "go-build", "CocoaPods", "ms-playwright", "ms-playwright-go",
        "node-gyp", "typescript", "pnpm",
    ]

    private struct DevCacheRule {
        let path: String
        let title: String
        let auto: Bool
        let selected: Bool
        let contentsOnly: Bool
        var note: String? = nil
        var sensitive = false
    }

    private static let devCacheRules: [DevCacheRule] = [
        .init(path: ".npm/_cacache", title: "npm önbelleği", auto: true, selected: true, contentsOnly: false),
        .init(path: ".npm/_npx", title: "npx paketleri", auto: true, selected: true, contentsOnly: false),
        .init(path: ".npm/_logs", title: "npm günlükleri", auto: true, selected: true, contentsOnly: false),
        .init(path: "Library/pnpm/store", title: "pnpm deposu", auto: false, selected: true, contentsOnly: false,
              note: "Sonraki kurulumda paketler yeniden indirilir"),
        .init(path: ".pnpm-store", title: "pnpm deposu", auto: false, selected: true, contentsOnly: false,
              note: "Sonraki kurulumda paketler yeniden indirilir"),
        .init(path: "Library/Caches/pnpm", title: "pnpm önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/Yarn", title: "Yarn önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".yarn/berry/cache", title: "Yarn Berry önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".bun/install/cache", title: "Bun önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/Homebrew", title: "Homebrew indirmeleri", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/pip", title: "pip önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/pip", title: "pip önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/uv", title: "uv önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/pre-commit", title: "pre-commit önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/go-build", title: "Go build önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/node-gyp", title: "node-gyp başlıkları", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/typescript", title: "TypeScript önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/CocoaPods", title: "CocoaPods önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cargo/registry/cache", title: "Cargo indirmeleri", auto: true, selected: true, contentsOnly: true),
        // Mole'un listesinden: yeniden oluşturulabilen araç önbellekleri
        .init(path: "Library/Caches/pypoetry", title: "Poetry önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/poetry", title: "Poetry önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/eslint", title: "ESLint önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/prettier", title: "Prettier önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/prisma", title: "Prisma önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/vite", title: "Vite önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".vite/cache", title: "Vite önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/webpack", title: "Webpack önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/typescript", title: "TypeScript önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/node-gyp", title: "node-gyp başlıkları", auto: true, selected: true, contentsOnly: true),
        .init(path: ".node-gyp", title: "node-gyp başlıkları", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/mypy", title: "mypy önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/ruff", title: "Ruff önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/electron", title: "Electron indirmeleri", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/curl", title: "curl önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/wget", title: "wget önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/zig", title: "Zig önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/terraform", title: "Terraform önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/swift-package-manager", title: "SwiftPM önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".turbo/cache", title: "Turborepo önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".parcel-cache", title: "Parcel önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".bundle/cache", title: "Ruby Bundler önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".gem/specs", title: "RubyGems spec önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".composer/cache", title: "Composer önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: "Library/Caches/composer", title: "Composer önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".rustup/downloads", title: "Rustup indirmeleri", auto: true, selected: true, contentsOnly: true),
        .init(path: ".pyenv/cache", title: "pyenv indirmeleri", auto: true, selected: true, contentsOnly: true),
        .init(path: ".rbenv/cache", title: "rbenv indirmeleri", auto: true, selected: true, contentsOnly: true),
        .init(path: ".tnpm/_cacache", title: "tnpm önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".android/build-cache", title: "Android build önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".android/cache", title: "Android SDK önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".expo/android-apk-cache", title: "Expo APK önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".expo/ios-simulator-app-cache", title: "Expo simülatör önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".expo/native-modules-cache", title: "Expo native modül önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".expo/versions-cache", title: "Expo sürüm önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".kube/cache", title: "Kubernetes önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".aws/cli/cache", title: "AWS CLI önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".docker/buildx/cache", title: "Docker BuildX önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".oh-my-zsh/cache", title: "Oh My Zsh önbelleği", auto: true, selected: true, contentsOnly: true),
        .init(path: ".cache/bazel", title: "Bazel önbelleği", auto: false, selected: false, contentsOnly: true,
              note: "Yeniden derleme uzun sürer"),
        .init(path: ".gradle/caches", title: "Gradle önbelleği", auto: false, selected: true, contentsOnly: false,
              note: "Bağımlılıklar yeniden indirilir"),
        .init(path: ".gradle/wrapper/dists", title: "Gradle sürümleri", auto: false, selected: false, contentsOnly: true),
        .init(path: ".m2/repository", title: "Maven deposu", auto: false, selected: false, contentsOnly: true,
              sensitive: true),
        .init(path: "Library/Caches/ms-playwright", title: "Playwright tarayıcıları", auto: false, selected: false,
              contentsOnly: true, note: "Testler için yeniden indirilmesi gerekir"),
        .init(path: ".cache/puppeteer", title: "Puppeteer tarayıcıları", auto: false, selected: false,
              contentsOnly: true, note: "Yeniden indirilmesi gerekir"),
        .init(path: ".cache/huggingface", title: "Hugging Face modelleri", auto: false, selected: false,
              contentsOnly: true, note: "İndirilmiş yapay zekâ modelleri", sensitive: true),
    ]

    private static func devCaches(_ ctx: CleanupContext) -> [CleanupItem] {
        var items: [CleanupItem] = []
        var covered = Set<String>()
        for rule in devCacheRules {
            let url = ctx.home.appendingPathComponent(rule.path)
            guard exists(url) else { continue }
            covered.insert(url.path)
            var item = CleanupItem(urls: [url], title: rule.title, category: .devCaches,
                                   autoEligible: rule.auto, defaultSelected: rule.selected,
                                   contentsOnly: rule.contentsOnly, note: rule.note)
            item.sensitive = rule.sensitive
            items.append(item)
        }
        // ~/.cache altındaki tanınmayan klasörler: listelenir ama seçilmez
        for dir in children(ctx.home.appendingPathComponent(".cache")) where isDirectory(dir) {
            guard !covered.contains(dir.path) else { continue }
            var item = CleanupItem(urls: [dir], title: "~/.cache/\(dir.lastPathComponent)", category: .devCaches,
                                   autoEligible: false, defaultSelected: false, contentsOnly: true,
                                   note: "Tanınmayan araç verisi, içeriğini kontrol et")
            item.sensitive = true
            items.append(item)
        }
        return items
    }

    private static func appCaches(_ ctx: CleanupContext) -> [CleanupItem] {
        let base = ctx.home.appendingPathComponent("Library/Caches")
        let ownID = Bundle.main.bundleIdentifier ?? "local.multimac"
        var items: [CleanupItem] = []
        for dir in children(base) where isDirectory(dir) {
            let name = dir.lastPathComponent
            if devCacheNames.contains(name) || name == ownID { continue }
            let isApple = name.hasPrefix("com.apple.")
            let running = ctx.isAppRunning(name: name)
            var note: String?
            if isApple { note = "Apple sistem önbelleği" } else if running { note = "Uygulama açık" }
            items.append(CleanupItem(
                urls: [dir], title: cacheTitle(name), category: .appCaches,
                autoEligible: !isApple, defaultSelected: !isApple,
                contentsOnly: true, note: note, inUse: running))
        }
        return items
    }

    private static func cacheTitle(_ name: String) -> String {
        if name.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return ProcessInspector.appName(forBundle: url.path)
        }
        return name
    }

    private static let electronCacheDirs = [
        "Cache", "Code Cache", "GPUCache", "CachedData", "DawnCache", "DawnGraphiteCache",
        "DawnWebGPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache",
        "CachedExtensionVSIXs", "ShaderCache", "GrShaderCache", "GraphiteDawnCache", "GPUPersistentCache",
        "Crashpad/completed",
    ]

    /// Chromium tabanlı tarayıcılar: önbellekler profil klasörlerinin içinde.
    private static let browserRoots: [(path: String, name: String, appName: String)] = [
        ("Google/Chrome", "Chrome", "google chrome"),
        ("BraveSoftware/Brave-Browser", "Brave", "brave browser"),
        ("Microsoft Edge", "Edge", "microsoft edge"),
        ("Arc/User Data", "Arc", "arc"),
        ("Vivaldi", "Vivaldi", "vivaldi"),
        ("Chromium", "Chromium", "chromium"),
        ("Yandex/YandexBrowser", "Yandex", "yandex"),
    ]
    private static let browserTopDirs: Set<String> = ["Google", "BraveSoftware", "Microsoft Edge", "Arc", "Vivaldi", "Chromium", "Yandex"]
    private static let profileCacheDirs = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache", "Application Cache",
    ]
    private static let browserRootCacheDirs = [
        "GrShaderCache", "ShaderCache", "GraphiteDawnCache", "GPUPersistentCache", "component_crx_cache",
        "extensions_crx_cache", "Crashpad/completed",
    ]

    /// Mole'daki gibi: yalnızca profil içindeki önbellek klasörlerinin içi; geçmiş, çerez, şifre vb. asla.
    private static func browserCaches(_ ctx: CleanupContext) -> [CleanupItem] {
        let base = ctx.home.appendingPathComponent("Library/Application Support")
        var items: [CleanupItem] = []
        for root in browserRoots {
            let rootURL = base.appendingPathComponent(root.path)
            guard exists(rootURL) else { continue }
            var dirs = browserRootCacheDirs.map { rootURL.appendingPathComponent($0) }.filter(exists)
            for profile in children(rootURL) where isDirectory(profile) {
                let n = profile.lastPathComponent
                guard n == "Default" || n.hasPrefix("Profile ") || n == "Guest Profile" || n == "System Profile" else { continue }
                dirs += profileCacheDirs.map { profile.appendingPathComponent($0) }.filter(exists)
            }
            guard !dirs.isEmpty else { continue }
            let running = ctx.isAppRunning(name: root.appName)
            items.append(CleanupItem(
                urls: dirs, title: "\(root.name) tarayıcı önbelleği",
                detail: Fmt.displayPath(rootURL.path) + " · \(dirs.count) önbellek klasörü (geçmiş ve çerezlere dokunulmaz)",
                category: .appCaches, autoEligible: true, defaultSelected: true, contentsOnly: true,
                note: running ? "Uygulama açık" : nil, inUse: running))
        }
        return items
    }

    private static func savedState(_ ctx: CleanupContext) -> [CleanupItem] {
        let url = ctx.home.appendingPathComponent("Library/Saved Application State")
        guard exists(url) else { return [] }
        return [CleanupItem(urls: [url], title: "Kayıtlı pencere durumları (30+ gün)", category: .logs,
                            autoEligible: true, defaultSelected: true, contentsOnly: true)]
    }

    /// Electron/Chromium uygulamaları (VS Code, Slack, Discord, Claude…) önbelleği Application Support'ta tutar.
    private static func electronCaches(_ ctx: CleanupContext) -> [CleanupItem] {
        let base = ctx.home.appendingPathComponent("Library/Application Support")
        var items: [CleanupItem] = []
        for app in children(base) where isDirectory(app) && !browserTopDirs.contains(app.lastPathComponent) {
            let dirs = electronCacheDirs.map { app.appendingPathComponent($0) }.filter(exists)
            guard !dirs.isEmpty else { continue }
            let running = ctx.isAppRunning(name: app.lastPathComponent)
            items.append(CleanupItem(
                urls: dirs, title: "\(app.lastPathComponent) (web önbelleği)",
                detail: Fmt.displayPath(app.path) + " · " + dirs.map(\.lastPathComponent).joined(separator: ", "),
                category: .appCaches, autoEligible: true, defaultSelected: true,
                contentsOnly: true, note: running ? "Uygulama açık" : nil, inUse: running))
        }
        return items
    }

    private static func xcode(_ ctx: CleanupContext) -> [CleanupItem] {
        let dev = ctx.home.appendingPathComponent("Library/Developer")
        let rules: [(String, String, Bool, Bool, String?)] = [
            ("Xcode/DerivedData", "DerivedData", true, true, nil),
            ("Xcode/iOS DeviceSupport", "iOS cihaz sembolleri", false, true, "Cihaz yeniden bağlanınca yeniden oluşturulur"),
            ("Xcode/watchOS DeviceSupport", "watchOS cihaz sembolleri", false, true, nil),
            ("Xcode/Archives", "Xcode arşivleri", false, false, "Yayınlanmış sürümlerin arşivleri"),
            ("CoreSimulator/Caches", "Simülatör önbelleği", true, true, nil),
            ("Xcode/UserData/Previews", "SwiftUI önizleme verisi", true, true, nil),
        ]
        return rules.compactMap { path, title, auto, selected, note in
            let url = dev.appendingPathComponent(path)
            guard exists(url) else { return nil }
            let xcodeRunning = ctx.isAppRunning(name: "xcode") || ctx.isAppRunning(name: "simulator")
            var item = CleanupItem(urls: [url], title: title, category: .xcode, autoEligible: auto,
                                   defaultSelected: selected, contentsOnly: true,
                                   note: xcodeRunning ? "Xcode veya simülatör açık" : note, inUse: xcodeRunning)
            item.sensitive = path.hasSuffix("Archives")
            return item
        }
    }

    private static func logs(_ ctx: CleanupContext) -> [CleanupItem] {
        let url = ctx.home.appendingPathComponent("Library/Logs")
        guard exists(url) else { return [] }
        return [CleanupItem(urls: [url], title: "Kullanıcı günlükleri (\(AutoSettings.logDays)+ gün)", category: .logs,
                            autoEligible: true, defaultSelected: true, contentsOnly: true)]
    }

    private static func trash(_ ctx: CleanupContext) -> [CleanupItem] {
        let url = ctx.home.appendingPathComponent(".Trash")
        guard exists(url) else { return [] }
        return [CleanupItem(urls: [url], title: "Çöp Kutusu", category: .trash, autoEligible: false,
                            defaultSelected: false, contentsOnly: true)]
    }

    private static func downloads(_ ctx: CleanupContext) -> [CleanupItem] {
        let base = ctx.home.appendingPathComponent("Downloads")
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let installers: Set<String> = ["dmg", "pkg", "xip", "iso", "mpkg"]
        var items: [CleanupItem] = []
        for url in children(base, keys: keys) where !url.lastPathComponent.hasPrefix(".") {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let date = v?.addedToDirectoryDate ?? v?.contentModificationDate
            let age = Fmt.days(since: date) ?? 0
            let isInstaller = installers.contains(url.pathExtension.lowercased())
            guard isInstaller || age >= 90 else { continue }
            items.append(CleanupItem(
                urls: [url], title: url.lastPathComponent,
                detail: "~/Downloads · \(age) gün önce indirildi", category: .downloads,
                autoEligible: false, defaultSelected: isInstaller, contentsOnly: false,
                note: isInstaller ? "Kurulum dosyası" : nil, lastUsed: date))
        }
        return items
    }

    // MARK: - Proje build kalıntıları

    private struct ArtifactRule {
        let names: Set<String>
        let markers: [String]   // boşsa her yerde geçerli
        let kind: String
        let auto: Bool          // otomatik temizlikte silinebilir mi (yalnızca proje boştaysa)
        let selectAlways: Bool  // aktif projelerde bile önceden seçili mi
        let note: String?
        var selectWhenStale = true  // uzun süredir dokunulmayan projelerde önceden seçili mi
    }

    private static let artifactRules: [ArtifactRule] = [
        .init(names: ["node_modules"], markers: ["package.json"], kind: "Bağımlılıklar",
              auto: false, selectAlways: false, note: "npm/pnpm install ile geri gelir"),
        .init(names: [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".expo", ".docusaurus"],
              markers: ["package.json"], kind: "Framework önbelleği", auto: true, selectAlways: true, note: nil),
        .init(names: ["dist", "build", "out", ".output"], markers: ["package.json"], kind: "Build çıktısı",
              auto: false, selectAlways: false, note: nil),
        .init(names: ["target"], markers: ["Cargo.toml", "pom.xml"], kind: "Build çıktısı",
              auto: false, selectAlways: false, note: nil),
        .init(names: ["build", ".gradle"], markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              kind: "Gradle build", auto: false, selectAlways: false, note: nil),
        .init(names: [".build"], markers: ["Package.swift"], kind: "Swift build", auto: false, selectAlways: false, note: nil),
        .init(names: ["Pods"], markers: ["Podfile"], kind: "CocoaPods", auto: false, selectAlways: false,
              note: "pod install ile geri gelir"),
        .init(names: [".dart_tool", "build"], markers: ["pubspec.yaml"], kind: "Flutter build", auto: false,
              selectAlways: false, note: nil),
        .init(names: ["build"], markers: ["CMakeLists.txt"], kind: "CMake build", auto: false, selectAlways: false, note: nil),
        .init(names: [".pytest_cache", ".mypy_cache", ".ruff_cache"], markers: [], kind: "Python araç önbelleği",
              auto: true, selectAlways: true, note: nil),
        .init(names: [".venv", "venv"], markers: ["pyproject.toml", "requirements.txt", "setup.py"],
              kind: "Python sanal ortamı", auto: false, selectAlways: false, note: "Paketler yeniden kurulmalı",
              selectWhenStale: false),
    ]

    private static let skipDirs: Set<String> = [".git", ".hg", ".svn", "Library", ".Trash", ".idea", ".vscode"]

    private static func buildArtifacts(_ ctx: CleanupContext, autoOnly: Bool) -> [CleanupItem] {
        var items: [CleanupItem] = []
        var projectInfo: [String: (lastUsed: Date?, busy: Bool)] = [:]

        func info(for project: URL) -> (lastUsed: Date?, busy: Bool) {
            if let cached = projectInfo[project.path] { return cached }
            let artifactNames = artifactRules.reduce(into: Set<String>()) { $0.formUnion($1.names) }
            let kids = children(project, keys: [.contentModificationDateKey])
                .filter { !artifactNames.contains($0.lastPathComponent) && $0.lastPathComponent != ".DS_Store" }
            let last = kids.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            let result = (last, ctx.isBusy(project.path))
            projectInfo[project.path] = result
            return result
        }

        func visit(_ dir: URL, depth: Int, root: URL) {
            guard depth <= 6 else { return }
            let entries = children(dir, keys: [.isDirectoryKey, .isSymbolicLinkKey])
            let names = Set(entries.map(\.lastPathComponent))
            for entry in entries where isDirectory(entry) {
                let name = entry.lastPathComponent
                if let rule = artifactRules.first(where: {
                    $0.names.contains(name) && ($0.markers.isEmpty || $0.markers.contains(where: names.contains))
                }) {
                    let (lastUsed, busy) = info(for: dir)
                    let idleDays = Fmt.days(since: lastUsed) ?? 0
                    let stale = idleDays >= ctx.staleDays
                    let rel = dir.path.hasPrefix(root.path) ? String(dir.path.dropFirst(root.path.count + 1)) : dir.lastPathComponent
                    let projectName = rel.isEmpty ? dir.lastPathComponent : rel
                    var notes: [String] = []
                    if busy { notes.append("Projede çalışan süreç var") }
                    if let n = rule.note { notes.append(n) }
                    items.append(CleanupItem(
                        urls: [entry], title: "\(projectName) › \(name)",
                        detail: "\(rule.kind) · \(Fmt.displayPath(entry.path)) · \(idleDays) gündür dokunulmadı",
                        category: .buildArtifacts,
                        autoEligible: rule.auto,
                        defaultSelected: !busy && (rule.selectAlways || (stale && rule.selectWhenStale)),
                        contentsOnly: false,
                        note: notes.isEmpty ? nil : notes.joined(separator: " · "),
                        lastUsed: lastUsed, project: dir.path, inUse: busy))
                    continue
                }
                if skipDirs.contains(name) || name == "node_modules" { continue }
                if name.hasPrefix(".") && depth > 0 { continue }
                visit(entry, depth: depth + 1, root: root)
            }
        }

        for root in ctx.projectRoots where exists(root) {
            visit(root, depth: 0, root: root)
        }
        return items
    }
}
