import AppKit
import CoreServices
import Darwin

/// Akıllı Temizlik'in öneri türleri.
enum SmartKind: String, CaseIterable, Codable {
    case projectLeftover, cache, download, largeFile, xcode, appLeftover, oldVersion, aiModel
    case unusedApp, backup, mailDownloads

    /// Yalnızca bilgi: silme önerilmez, Finder'da gösterilir.
    var isInfoOnly: Bool { self == .unusedApp || self == .backup || self == .mailDownloads }

    /// Modelin tür başına başlangıç sabiti. Kişisel olabilecek türler daha temkinli başlar.
    var priorBias: Double {
        switch self {
        case .projectLeftover: -3.4
        case .cache: -3.6
        case .download: -2.6
        case .largeFile: -4.2
        case .xcode: -3.0
        case .appLeftover: -2.6
        case .oldVersion: -2.4
        case .aiModel: -3.0
        case .unusedApp, .backup, .mailDownloads: -6
        }
    }

    var title: String {
        switch self {
        case .projectLeftover: L("Proje kalıntısı", "Project leftover", "Остаток проекта")
        case .cache: L("Önbellek", "Cache", "Кэш")
        case .download: L("Kurulum dosyası", "Installer", "Установщик")
        case .largeFile: L("Büyük dosya", "Large file", "Большой файл")
        case .xcode: "Xcode"
        case .appLeftover: L("Silinmiş uygulama kalıntısı", "Removed app leftovers", "Остатки удалённого приложения")
        case .oldVersion: L("Eski sürüm", "Old version", "Старая версия")
        case .aiModel: L("Yapay zeka modeli", "AI model", "Модель ИИ")
        case .unusedApp: L("Kullanılmayan uygulama", "Unused app", "Неиспользуемое приложение")
        case .backup: L("iPhone yedeği", "iPhone backup", "Резервная копия iPhone")
        case .mailDownloads: L("Mail ekleri", "Mail attachments", "Вложения Mail")
        }
    }

    var symbol: String {
        switch self {
        case .projectLeftover: "hammer"
        case .cache: "square.stack.3d.up"
        case .download: "shippingbox"
        case .largeFile: "doc"
        case .xcode: "swift"
        case .appLeftover: "app.dashed"
        case .oldVersion: "clock.arrow.circlepath"
        case .aiModel: "cpu"
        case .unusedApp: "app.badge"
        case .backup: "iphone"
        case .mailDownloads: "paperclip"
        }
    }
}

/// Öneri için yapılacak iş.
enum SmartAction: Equatable {
    /// Temizlik motoruyla sil (ev klasörü güvenlik kapısından geçer).
    case delete(contentsOnly: Bool)
    /// Yolu ev klasörü dışında olan ya da aracın kendisiyle silinmesi gereken şeyler (brew, ollama).
    case command(String)
    /// Yalnızca Finder'da göster.
    case reveal
}

/// Ölçülmeden önceki aday.
struct SmartCandidate {
    var id: String
    var kind: SmartKind
    var title: String
    var detail: String
    var urls: [URL]
    var action: SmartAction
    var regenerable = false
    var ownerMissing = false
    var ownerRunning = false
    var newerVersion = false
    var projectBusy = false
    var projectIdleDays: Int?
    /// Bilinen boyut (ör. ollama manifesti); nil ise yollar ölçülür.
    var knownSize: Int64?
    var knownLastUsed: Date?
    /// Tanınan bir önbellek/kalıntıysa içerik "önemli mi" diye incelenmez.
    var skipImportanceCheck = false
}

// MARK: - Ölçüm

struct PathStats {
    var size: Int64 = 0
    var newestModified = 0
    var newestAccessed = 0
    var files = 0
    var sampled = 0
    var docLike = 0
}

enum SmartMeasure {
    /// Belge, fotoğraf, kod gibi "kişisel ve yeniden oluşturulamaz" olabilecek uzantılar.
    static let personalExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf", "txt", "md", "odt",
        "jpg", "jpeg", "png", "heic", "heif", "raw", "cr2", "nef", "dng", "psd", "sketch", "fig", "ai",
        "mov", "mp4", "m4v", "wav", "aif", "aiff", "logicx", "fcpbundle",
        "swift", "py", "js", "ts", "tsx", "go", "rs", "java", "kt", "c", "cpp", "h",
    ]

    /// Tek geçişte boyut, en yeni değişiklik/erişim tarihi ve ilk birkaç yüz dosyanın türü.
    static func stats(_ path: String, sampleLimit: Int = 400) -> PathStats {
        var s = PathStats()
        var seen = Set<UInt64>()
        FTSWalker.walk(path) { ent in
            let info = Int32(ent.pointee.fts_info)
            guard info == FTS_F || info == FTS_SL || info == FTS_DEFAULT, let st = ent.pointee.fts_statp else { return true }
            if st.pointee.st_nlink > 1, !seen.insert(st.pointee.st_ino).inserted { return true }
            s.size += FTSWalker.allocated(ent)
            s.files += 1
            s.newestModified = max(s.newestModified, Int(st.pointee.st_mtimespec.tv_sec))
            s.newestAccessed = max(s.newestAccessed, Int(st.pointee.st_atimespec.tv_sec))
            if s.sampled < sampleLimit, info == FTS_F {
                s.sampled += 1
                let ext = (FTSWalker.name(ent) as NSString).pathExtension.lowercased()
                if personalExtensions.contains(ext) { s.docLike += 1 }
            }
            return true
        }
        return s
    }

    /// macOS'un "son kullanılma" tarihi (Spotlight). Bazı dosyalarda güncellenmez: yoksa "bilinmiyor".
    static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

// MARK: - Dedektörler

enum SmartDetectors {
    private static let fm = FileManager.default
    private static var home: String { NSHomeDirectory() }

    private static func children(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.map { path + "/" + $0 }
    }

    private static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    private static func modifiedDays(_ path: String) -> Int? {
        guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        return Fmt.days(since: date)
    }

    static func all(_ ctx: CleanupContext) -> [SmartCandidate] {
        var out: [SmartCandidate] = []
        out += appLeftovers(ctx)
        out += playwright()
        out += nodeVersions()
        out += pythonVersions()
        out += deviceSupport()
        out += unavailableSimulators()
        out += homebrew()
        out += aiModels()
        out += unusedApps(ctx)
        out += backups()
        out += mailDownloads()
        return out
    }

    // MARK: Silinmiş uygulamaların kalıntıları

    private static let leftoverRoots = [
        "Library/Application Support", "Library/Caches", "Library/HTTPStorages", "Library/WebKit",
        "Library/Logs", "Library/Saved Application State",
    ]

    /// Ters alan adı biçimindeki klasör adları (com.firma.uygulama). Ada göre adlandırılmış
    /// ("Spotify") klasörler belirsiz olduğu için bilerek atlanır. Containers macOS izni istediği için taranmaz.
    static func appLeftovers(_ ctx: CleanupContext) -> [SmartCandidate] {
        let installed = installedBundleIDs()
        var groups: [String: [String]] = [:]
        for root in leftoverRoots {
            for path in children(home + "/" + root) {
                var name = (path as NSString).lastPathComponent
                if name.hasSuffix(".savedState") { name = String(name.dropLast(".savedState".count)) }
                guard isBundleID(name), !name.lowercased().hasPrefix("com.apple."), name != Bundle.main.bundleIdentifier else { continue }
                if isInstalled(name, installed: installed) || ctx.runningBundleIDs.contains(name) { continue }
                groups[name, default: []].append(path)
            }
        }
        return groups.compactMap { id, paths in
            // Komut satırı araçları da bu adlarla önbellek tutar: yalnızca 30 gündür dokunulmayanlar.
            let idle = paths.compactMap(modifiedDays).min() ?? 0
            guard idle >= 30 else { return nil }
            return SmartCandidate(
                id: "leftover:" + id, kind: .appLeftover, title: id,
                detail: paths.map { Fmt.displayPath(($0 as NSString).deletingLastPathComponent) }.joined(separator: ", "),
                urls: paths.map { URL(fileURLWithPath: $0) }, action: .delete(contentsOnly: false),
                ownerMissing: true, skipImportanceCheck: true)
        }
    }

    private static func isBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func isInstalled(_ id: String, installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        if installed.contains(lower) { return true }
        if installed.contains(where: { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let roots = ["/Applications", "/Applications/Utilities", home + "/Applications", "/System/Applications",
                     "/System/Applications/Utilities", "/Applications/Setapp"]
        for root in roots {
            for path in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where path.hasSuffix(".app") {
                if let id = Bundle(path: root + "/" + path)?.bundleIdentifier { ids.insert(id.lowercased()) }
            }
        }
        return ids
    }

    // MARK: Eski sürümler

    /// ~/Library/Caches/ms-playwright/chromium-1124 gibi: her tarayıcının en yeni sürümü dışındakiler.
    static func playwright() -> [SmartCandidate] {
        let base = home + "/Library/Caches/ms-playwright"
        var byName: [String: [(Int, String)]] = [:]
        for path in children(base) {
            let name = (path as NSString).lastPathComponent
            guard let dash = name.lastIndex(of: "-"), let rev = Int(name[name.index(after: dash)...]) else { continue }
            byName[String(name[..<dash]), default: []].append((rev, path))
        }
        return byName.flatMap { browser, list -> [SmartCandidate] in
            let newest = list.map(\.0).max() ?? 0
            return list.filter { $0.0 < newest }.map { rev, path in
                SmartCandidate(id: path, kind: .oldVersion, title: "Playwright \(browser)-\(rev)",
                               detail: L("Yeni sürümü var: \(browser)-\(newest)", "Newer version installed: \(browser)-\(newest)", "Установлена новая версия: \(browser)-\(newest)"),
                               urls: [URL(fileURLWithPath: path)], action: .delete(contentsOnly: false),
                               regenerable: true, newerVersion: true, skipImportanceCheck: true)
            }
        }
    }

    /// Proje köklerindeki .nvmrc / .python-version dosyalarında anılan sürümler (bunlara dokunulmaz).
    private static func pinnedVersions(file: String) -> Set<String> {
        var out = Set<String>()
        for root in Prefs.roots {
            for project in [root] + children(root) {
                if let s = try? String(contentsOfFile: project + "/" + file, encoding: .utf8) {
                    s.split(whereSeparator: \.isNewline).forEach { out.insert($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "v", with: "")) }
                }
            }
        }
        return out
    }

    private static func versionKey(_ v: String) -> [Int] {
        v.replacingOccurrences(of: "v", with: "").split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    private static func pinned(_ version: String, by pins: Set<String>) -> Bool {
        let v = version.replacingOccurrences(of: "v", with: "")
        return pins.contains { !$0.isEmpty && (v == $0 || v.hasPrefix($0 + ".")) }
    }

    /// nvm: varsayılan sürüm, en yeni sürüm ve projelerde anılanlar dışındakiler.
    static func nodeVersions() -> [SmartCandidate] {
        let base = home + "/.nvm/versions/node"
        let versions = children(base).map { ($0 as NSString).lastPathComponent }
        guard versions.count > 1 else { return [] }
        let def = (try? String(contentsOfFile: home + "/.nvm/alias/default", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "") ?? ""
        let newest = versions.max { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
        let pins = pinnedVersions(file: ".nvmrc")
        let defaultMatch = versions.filter { pinned($0, by: [def]) }.max { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
        return versions.filter { $0 != newest && $0 != defaultMatch && !pinned($0, by: pins) }.map { v in
            SmartCandidate(id: base + "/" + v, kind: .oldVersion, title: "Node.js \(v)",
                           detail: L("nvm · varsayılan değil, projelerinde kullanılmıyor", "nvm · not the default, not used by your projects", "nvm · не по умолчанию, не используется в проектах"),
                           urls: [URL(fileURLWithPath: base + "/" + v)], action: .delete(contentsOnly: false),
                           regenerable: true, newerVersion: true, skipImportanceCheck: true)
        }
    }

    /// pyenv: genel sürüm, içinde sanal ortam olanlar ve projelerde anılanlar dışındakiler.
    static func pythonVersions() -> [SmartCandidate] {
        let base = home + "/.pyenv/versions"
        let versions = children(base).map { ($0 as NSString).lastPathComponent }.filter { $0.first?.isNumber == true }
        guard versions.count > 1 else { return [] }
        var pins = pinnedVersions(file: ".python-version")
        if let g = try? String(contentsOfFile: home + "/.pyenv/version", encoding: .utf8) {
            g.split(whereSeparator: \.isNewline).forEach { pins.insert(String($0)) }
        }
        let newest = versions.max { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
        return versions.filter { v in
            v != newest && !pinned(v, by: pins) && children(base + "/" + v + "/envs").isEmpty
        }.map { v in
            SmartCandidate(id: base + "/" + v, kind: .oldVersion, title: "Python \(v)",
                           detail: L("pyenv · genel sürüm değil, projelerinde kullanılmıyor", "pyenv · not the global version, not used by your projects", "pyenv · не глобальная версия, не используется в проектах"),
                           urls: [URL(fileURLWithPath: base + "/" + v)], action: .delete(contentsOnly: false),
                           regenerable: true, newerVersion: true, skipImportanceCheck: true)
        }
    }

    /// Xcode cihaz sembolleri: en yeni ana sürüm dışındaki ve 60 gündür kullanılmayanlar.
    static func deviceSupport() -> [SmartCandidate] {
        var out: [SmartCandidate] = []
        for platform in ["iOS", "watchOS", "tvOS"] {
            let base = home + "/Library/Developer/Xcode/\(platform) DeviceSupport"
            let entries = children(base).map { path -> (String, [Int]) in
                let name = (path as NSString).lastPathComponent
                let ver = name.split(separator: " ").first { $0.contains(".") && $0.first?.isNumber == true } ?? ""
                return (path, versionKey(String(ver)))
            }
            guard entries.count > 1, let newest = entries.map(\.1).max(by: { $0.lexicographicallyPrecedes($1) }) else { continue }
            for (path, ver) in entries where ver.first ?? 0 < newest.first ?? 0 && (modifiedDays(path) ?? 0) >= 60 {
                let name = (path as NSString).lastPathComponent
                out.append(SmartCandidate(
                    id: path, kind: .xcode, title: L("\(platform) \(name) cihaz sembolleri", "\(platform) \(name) device symbols", "Символы устройства \(platform) \(name)"),
                    detail: L("Bu sürüme bağlı cihaz uzun süredir takılmadı", "No device on this version was connected for a long time", "Устройство с этой версией давно не подключалось"),
                    urls: [URL(fileURLWithPath: path)], action: .delete(contentsOnly: false),
                    regenerable: true, newerVersion: true, skipImportanceCheck: true))
            }
        }
        return out
    }

    /// Kurulu olmayan bir iOS sürümüne bağlı simülatörler (Xcode varsa).
    static func unavailableSimulators() -> [SmartCandidate] {
        guard fm.fileExists(atPath: "/Applications/Xcode.app"),
              let data = run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "--json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.values.flatMap { $0 }.compactMap { d in
            guard let path = d["dataPath"] as? String, let udid = d["udid"] as? String else { return nil }
            let dir = (path as NSString).deletingLastPathComponent
            guard dir.hasSuffix(udid), fm.fileExists(atPath: dir) else { return nil }
            return SmartCandidate(id: dir, kind: .xcode, title: L("Simülatör: \(d["name"] as? String ?? udid)", "Simulator: \(d["name"] as? String ?? udid)", "Симулятор: \(d["name"] as? String ?? udid)"),
                                  detail: L("Bağlı olduğu iOS sürümü artık kurulu değil", "Its iOS version is no longer installed", "Его версия iOS больше не установлена"),
                                  urls: [URL(fileURLWithPath: dir)], action: .delete(contentsOnly: false),
                                  ownerMissing: true, skipImportanceCheck: true)
        }
    }

    /// Homebrew'un eski paket sürümleri. Ev klasörü dışında olduğu için Homebrew'un kendi komutuyla temizlenir.
    static func homebrew() -> [SmartCandidate] {
        guard let prefix = ["/opt/homebrew", "/usr/local"].first(where: { fm.fileExists(atPath: $0 + "/Cellar") }) else { return [] }
        var old: [URL] = []
        for formula in children(prefix + "/Cellar") {
            let versions = children(formula)
            guard versions.count > 1 else { continue }
            let name = (formula as NSString).lastPathComponent
            let linked = (try? fm.destinationOfSymbolicLink(atPath: prefix + "/opt/" + name)).map { ($0 as NSString).lastPathComponent }
            let keep = linked ?? versions.map { ($0 as NSString).lastPathComponent }.max { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
            old += versions.filter { ($0 as NSString).lastPathComponent != keep }.map { URL(fileURLWithPath: $0) }
        }
        guard !old.isEmpty else { return [] }
        return [SmartCandidate(id: "homebrew-old", kind: .oldVersion, title: L("Homebrew eski paket sürümleri", "Homebrew old package versions", "Старые версии пакетов Homebrew"),
                               detail: L("\(old.count) eski sürüm · Homebrew'un kendi komutuyla silinir", "\(old.count) old versions · removed with Homebrew's own command", "Старых версий: \(old.count) · удаляются командой Homebrew"),
                               urls: old, action: .command("brew cleanup"), regenerable: true, newerVersion: true, skipImportanceCheck: true)]
    }

    // MARK: Yapay zeka modelleri

    static func aiModels() -> [SmartCandidate] {
        var out: [SmartCandidate] = []
        // Hugging Face önbelleği: her model / veri seti ayrı öneri
        for root in [home + "/.cache/huggingface/hub", home + "/.cache/huggingface/datasets"] {
            for path in children(root) {
                let name = (path as NSString).lastPathComponent
                guard name.hasPrefix("models--") || name.hasPrefix("datasets--") else { continue }
                let title = name.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "datasets--", with: "")
                    .replacingOccurrences(of: "--", with: "/")
                out.append(SmartCandidate(id: path, kind: .aiModel, title: title, detail: "Hugging Face · " + Fmt.displayPath(root),
                                          urls: [URL(fileURLWithPath: path)], action: .delete(contentsOnly: false),
                                          regenerable: true, skipImportanceCheck: true))
            }
        }
        // LM Studio
        for root in [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"] {
            for publisher in children(root) {
                for model in children(publisher) {
                    out.append(SmartCandidate(id: model, kind: .aiModel,
                                              title: (publisher as NSString).lastPathComponent + "/" + (model as NSString).lastPathComponent,
                                              detail: "LM Studio · " + Fmt.displayPath(root),
                                              urls: [URL(fileURLWithPath: model)], action: .delete(contentsOnly: false),
                                              regenerable: true, skipImportanceCheck: true))
                }
            }
        }
        // Whisper ve PyTorch hub indirmeleri
        for (path, title) in [(home + "/.cache/whisper", "Whisper"), (home + "/.cache/torch/hub", "PyTorch Hub")] where isDir(path) {
            out.append(SmartCandidate(id: path, kind: .aiModel, title: title, detail: Fmt.displayPath(path),
                                      urls: [URL(fileURLWithPath: path)], action: .delete(contentsOnly: true),
                                      regenerable: true, skipImportanceCheck: true))
        }
        out += ollamaModels()
        return out
    }

    /// Ollama: dosyalar modeller arasında paylaşıldığı için yalnızca `ollama rm` ile silinir.
    static func ollamaModels() -> [SmartCandidate] {
        let base = home + "/.ollama/models/manifests"
        var out: [SmartCandidate] = []
        for registry in children(base) {
            for ns in children(registry) {
                for model in children(ns) {
                    for tagPath in children(model) {
                        guard let data = fm.contents(atPath: tagPath),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        let layers = (json["layers"] as? [[String: Any]]) ?? []
                        let size = layers.compactMap { ($0["size"] as? NSNumber)?.int64Value }.reduce(0, +)
                        let nsName = (ns as NSString).lastPathComponent
                        let name = (nsName == "library" ? "" : nsName + "/") + (model as NSString).lastPathComponent
                            + ":" + (tagPath as NSString).lastPathComponent
                        let attrs = try? fm.attributesOfItem(atPath: tagPath)
                        out.append(SmartCandidate(id: tagPath, kind: .aiModel, title: name, detail: "Ollama",
                                                  urls: [URL(fileURLWithPath: tagPath)], action: .command("ollama rm \(name)"),
                                                  regenerable: true, knownSize: size,
                                                  knownLastUsed: attrs?[.modificationDate] as? Date, skipImportanceCheck: true))
                    }
                }
            }
        }
        return out
    }

    // MARK: Bilgi amaçlı

    /// 120 günden uzun süredir açılmamış uygulamalar (macOS'un son kullanım bilgisi varsa).
    static func unusedApps(_ ctx: CleanupContext) -> [SmartCandidate] {
        var out: [SmartCandidate] = []
        for root in ["/Applications", home + "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
                let path = root + "/" + name
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier,
                      !id.hasPrefix("com.apple."), !ctx.runningBundleIDs.contains(id),
                      let used = SmartMeasure.lastUsedDate(path), let days = Fmt.days(since: used), days >= 120 else { continue }
                out.append(SmartCandidate(id: path, kind: .unusedApp, title: String(name.dropLast(4)),
                                          detail: L("\(days) gündür açılmadı", "Not opened for \(days) days", "Не открывалось дней: \(days)"),
                                          urls: [URL(fileURLWithPath: path)], action: .reveal, knownLastUsed: used, skipImportanceCheck: true))
            }
        }
        return out
    }

    static func backups() -> [SmartCandidate] {
        let base = home + "/Library/Application Support/MobileSync/Backup"
        return children(base).compactMap { path in
            let info = NSDictionary(contentsOfFile: path + "/Info.plist")
            let device = info?["Device Name"] as? String ?? (path as NSString).lastPathComponent
            let date = info?["Last Backup Date"] as? Date
            return SmartCandidate(id: path, kind: .backup, title: device,
                                  detail: date.map { L("Son yedek: \(Fmt.relative($0))", "Last backup: \(Fmt.relative($0))", "Последняя копия: \(Fmt.relative($0))") } ?? Fmt.displayPath(base),
                                  urls: [URL(fileURLWithPath: path)], action: .reveal, knownLastUsed: date, skipImportanceCheck: true)
        }
    }

    /// Mail'in indirdiği ekler. Mail'in kendi alanında olduğu için yalnızca Tam Disk Erişimi varsa ölçülür.
    static func mailDownloads() -> [SmartCandidate] {
        let path = home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        guard FullDiskAccess.isGranted, isDir(path) else { return [] }
        return [SmartCandidate(id: path, kind: .mailDownloads, title: L("Mail'in indirdiği ekler", "Attachments downloaded by Mail", "Вложения, загруженные Mail"),
                               detail: L("Mail gerektiğinde sunucudan yeniden indirir", "Mail downloads them again from the server when needed", "Mail загрузит их с сервера снова при необходимости"),
                               urls: [URL(fileURLWithPath: path)], action: .reveal, skipImportanceCheck: true)]
    }

    // MARK: Yardımcı

    private static func run(_ tool: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
