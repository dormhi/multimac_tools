import Foundation
import UserNotifications

enum CleanupEngine {
    private static let fm = FileManager.default
    private static let home = NSHomeDirectory()

    private static let neverDeleteWhole: Set<String> = [
        "Library", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Developer",
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", ".Trash", ".cache", ".npm",
    ]

    /// Son güvenlik kapısı: yalnızca ev klasörü altındaki beklenen yollar silinebilir.
    static func isAllowed(_ url: URL, contentsOnly: Bool) -> Bool {
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(home + "/"), !p.contains("/../") else { return false }
        let rel = String(p.dropFirst(home.count + 1))
        if contentsOnly { return !rel.isEmpty && rel != "Library" }
        return rel.split(separator: "/").count >= 2 && !neverDeleteWhole.contains(rel)
    }

    private static func remove(_ url: URL, toTrash: Bool) -> Bool {
        do {
            if toTrash { try fm.trashItem(at: url, resultingItemURL: nil) } else { try fm.removeItem(at: url) }
            return true
        } catch {
            return false
        }
    }

    static func clean(_ items: [CleanupItem], toTrash: Bool = false) -> CleanupResult {
        var result = CleanupResult()
        result.trashed = toTrash
        let excluded = Exclusions.all
        for item in items {
            // Yaş sınırlı öğeler (günlükler, pencere durumları): yalnızca eski dosyalar silinir.
            if let days = item.minAgeDays {
                var freed: Int64 = 0
                var failed = false
                for url in item.urls where isAllowed(url, contentsOnly: true)
                    && !Exclusions.isExcluded(url.standardizedFileURL.path, in: excluded) {
                    let r = DirectorySizer.deleteFiles(in: url.path, olderThanDays: days, excluded: excluded)
                    freed += r.freed
                    failed = failed || r.failed
                }
                result.freed += freed
                if freed > 0 { result.cleanedItems += 1 }
                if failed && freed == 0 { result.failedPaths.append(item.detail) }
                continue
            }
            var failed = false
            for url in item.urls {
                let path = url.standardizedFileURL.path
                guard isAllowed(url, contentsOnly: item.contentsOnly),
                      !Exclusions.isExcluded(path, in: excluded) else {
                    failed = true
                    continue
                }
                if item.contentsOnly {
                    let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    for child in kids {
                        let cp = child.standardizedFileURL.path
                        // Hariç tutulan bir şey içeren alt klasörlere dokunma
                        if Exclusions.isExcluded(cp, in: excluded) || Exclusions.containsExcluded(cp, in: excluded) {
                            failed = true
                            continue
                        }
                        if !remove(child, toTrash: toTrash) { failed = true }
                    }
                } else if Exclusions.containsExcluded(path, in: excluded) {
                    failed = true
                } else if !remove(url, toTrash: toTrash) {
                    failed = true
                }
            }
            // Kısmen silinemeyenler için kalan boyutu ölç
            let remaining = failed ? item.urls.reduce(Int64(0)) { $0 + DirectorySizer.allocatedSize($1.path, olderThanDays: item.minAgeDays) } : 0
            let freed = max(0, item.size - remaining)
            result.freed += freed
            if freed > 0 { result.cleanedItems += 1 }
            if failed && freed == 0 { result.failedPaths.append(item.detail) }
        }
        return result
    }
}

struct CleanupFilter: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case size, name, date
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: L("Boyut", "Size", "Размер")
            case .name: L("Ad", "Name", "Имя")
            case .date: L("Son kullanım", "Last used", "Последнее использование")
            }
        }
    }

    var search = ""
    var minSize: Int64 = 0
    var minAgeDays = 0
    var onlySelected = false
    var sort: Sort = .size

    var isActive: Bool { !search.isEmpty || minSize > 0 || minAgeDays > 0 || onlySelected }
}

struct CleanupSummary {
    var total: Int64 = 0
    var categoryTotals: [CleanupCategory: Int64] = [:]
    var categoryCounts: [CleanupCategory: Int] = [:]
    var presetSizes: [CleanupPreset: Int64] = [:]
    /// Boyuta göre sıralı, boş olmayan kategoriler
    var categories: [(CleanupCategory, Int64)] = []
    var projects: [ProjectGroup] = []
}

struct ProjectGroup: Identifiable {
    let path: String
    let items: [CleanupItem]
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var lastUsed: Date? { items.compactMap(\.lastUsed).max() }
    var inUse: Bool { items.contains(where: \.inUse) }
}

@MainActor
final class CleanupStore: ObservableObject {
    enum QuickState: Equatable {
        case idle, scanning, cleaning
        case done(freed: Int64, items: Int)
    }

    @Published private(set) var items: [CleanupItem] = [] {
        didSet { rebuildSummary() }
    }
    /// Görünümlerin her çizimde yeniden hesaplamaması için önceden hesaplanmış toplamlar.
    @Published private(set) var summary = CleanupSummary()
    @Published var selected: Set<String> = []
    @Published private(set) var preset: CleanupPreset
    @Published private(set) var subItems: [String: [CleanupItem]] = [:]
    @Published private(set) var loadingSubs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastResult: CleanupResult?
    @Published private(set) var quickState: QuickState = .idle
    @Published private(set) var lastAutoDate: Date?
    @Published private(set) var lastAutoBytes: Int64 = 0

    var onDiskChanged: (() -> Void)?
    private var autoTimer: Timer?

    var isBusy: Bool { isScanning || isCleaning || quickState == .scanning || quickState == .cleaning }

    init() {
        let d = UserDefaults.standard
        let t = d.double(forKey: Prefs.lastAutoCleanDate)
        lastAutoDate = t > 0 ? Date(timeIntervalSince1970: t) : nil
        lastAutoBytes = Int64(d.integer(forKey: Prefs.lastAutoCleanBytes))
        preset = CleanupPreset(rawValue: d.string(forKey: Prefs.cleanupPreset) ?? "") ?? .balanced
    }

    // MARK: Seçim ve görünüm

    var allSubItems: [CleanupItem] { subItems.values.flatMap { $0 } }

    var selectedItems: [CleanupItem] {
        items.filter { selected.contains($0.id) }
            + allSubItems.filter { selected.contains($0.id) && !selected.contains($0.parentID ?? "") }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { selectedItems.count }
    var totalSize: Int64 { summary.total }

    private func rebuildSummary() {
        var s = CleanupSummary()
        for item in items {
            s.total += item.size
            s.categoryTotals[item.category, default: 0] += item.size
            s.categoryCounts[item.category, default: 0] += 1
            for p in [CleanupPreset.safe, .balanced, .aggressive] where p.includes(item) {
                s.presetSizes[p, default: 0] += item.size
            }
        }
        s.categories = CleanupCategory.allCases
            .compactMap { c in s.categoryTotals[c].map { (c, $0) } }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        s.projects = Dictionary(grouping: items.filter { $0.project != nil }) { $0.project! }
            .map { ProjectGroup(path: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size > $1.size }
        summary = s
    }

    func visible(_ list: [CleanupItem], filter f: CleanupFilter) -> [CleanupItem] {
        let filtered = list.filter { item in
            if f.minSize > 0 && item.size < f.minSize { return false }
            if f.minAgeDays > 0 {
                guard let days = Fmt.days(since: item.lastUsed), days >= f.minAgeDays else { return false }
            }
            if f.onlySelected && checkState(item) == .off { return false }
            if !f.search.isEmpty {
                let q = f.search
                return item.title.localizedCaseInsensitiveContains(q) || item.detail.localizedCaseInsensitiveContains(q)
                    || (item.note?.localizedCaseInsensitiveContains(q) ?? false)
            }
            return true
        }
        switch f.sort {
        case .size: return filtered.sorted { $0.size > $1.size }
        case .name: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date: return filtered.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        }
    }

    func items(in category: CleanupCategory, filter: CleanupFilter = CleanupFilter()) -> [CleanupItem] {
        visible(items.filter { $0.category == category }, filter: filter)
    }

    func projects(filter: CleanupFilter) -> [ProjectGroup] {
        let artifacts = visible(items.filter { $0.project != nil }, filter: filter)
        let groups = Dictionary(grouping: artifacts) { $0.project! }
            .map { ProjectGroup(path: $0.key, items: $0.value) }
        switch filter.sort {
        case .size: return groups.sorted { $0.size > $1.size }
        case .name: return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: return groups.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        }
    }

    func checkState(_ item: CleanupItem) -> Checkbox.State {
        if selected.contains(item.id) { return .on }
        if let subs = subItems[item.id], subs.contains(where: { selected.contains($0.id) }) { return .mixed }
        return .off
    }

    func checkState(_ list: [CleanupItem]) -> Checkbox.State {
        guard !list.isEmpty else { return .off }
        let states = list.map(checkState)
        if states.allSatisfy({ $0 == .on }) { return .on }
        if states.allSatisfy({ $0 == .off }) { return .off }
        return .mixed
    }

    func toggle(_ item: CleanupItem) {
        if let parentID = item.parentID {
            toggleSub(item, parentID: parentID)
        } else {
            set([item], selected: checkState(item) != .on)
        }
        preset = .custom
    }

    /// Bir grup öğeyi (kategori, proje) topluca seç / bırak.
    func set(_ list: [CleanupItem], selected on: Bool) {
        for item in list {
            subItems[item.id]?.forEach { selected.remove($0.id) }
            if on { selected.insert(item.id) } else { selected.remove(item.id) }
        }
        preset = .custom
    }

    private func toggleSub(_ sub: CleanupItem, parentID: String) {
        let siblings = subItems[parentID] ?? []
        if selected.contains(parentID) {
            // Üst öğe tamamen seçiliydi: bu alt öğe hariç diğerlerini seç
            selected.remove(parentID)
            siblings.filter { $0.id != sub.id }.forEach { selected.insert($0.id) }
        } else if selected.contains(sub.id) {
            selected.remove(sub.id)
        } else {
            selected.insert(sub.id)
        }
    }

    func apply(_ newPreset: CleanupPreset) {
        guard newPreset != .custom else { return }
        preset = newPreset
        UserDefaults.standard.set(newPreset.rawValue, forKey: Prefs.cleanupPreset)
        selected = Set(items.filter(newPreset.includes).map(\.id))
    }

    // MARK: Alt öğeler (bir öğenin içini aç)

    func loadSubItems(_ item: CleanupItem) async {
        guard subItems[item.id] == nil, !loadingSubs.contains(item.id) else { return }
        loadingSubs.insert(item.id)
        let parentID = item.id
        let category = item.category
        let candidates: [CleanupItem] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let urls: [URL] = item.urls.count > 1
                ? item.urls
                : item.urls.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            return urls.map { url in
                CleanupItem(urls: [url], title: url.lastPathComponent, category: category,
                            autoEligible: false, defaultSelected: false, contentsOnly: false, parentID: parentID)
            }
        }.value
        let measured = await CleanupScanner.measure(candidates)
        subItems[item.id] = Array(measured.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(150))
        loadingSubs.remove(item.id)
    }

    func canExpand(_ item: CleanupItem) -> Bool {
        item.parentID == nil && item.isDirectory
    }

    // MARK: Hariç tutma

    func exclude(path: String) {
        Exclusions.add(path)
        let removedIDs = Set(items.filter { $0.urls.contains { Exclusions.isExcluded($0.path, in: [path]) } }.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        selected.subtract(removedIDs)
        for (key, subs) in subItems {
            let kept = subs.filter { !Exclusions.isExcluded($0.urls[0].path, in: [path]) }
            subs.filter { !kept.contains($0) }.forEach { selected.remove($0.id) }
            subItems[key] = kept
        }
    }

    // MARK: Detaylı tarama

    func scanAll() async {
        guard !isScanning else { return }
        isScanning = true
        let ctx = await CleanupContext.current()
        let found = await CleanupScanner.scan(context: ctx, autoOnly: false)
        items = found
        subItems = [:]
        let p = preset == .custom ? .balanced : preset
        selected = Set(found.filter(p.includes).map(\.id))
        if preset == .custom { preset = .balanced }
        lastScan = Date()
        isScanning = false
    }

    /// Öğe başlıkları ve notları tarama anında o dille yazılır. Dil değişince yeniden tarar,
    /// kullanıcının seçimini ve kipini korur.
    func refreshForLanguage() async {
        if lastScan != nil, !isScanning, !isCleaning {
            let keepSelection = selected
            let keepPreset = preset
            await scanAll()
            selected = keepSelection.intersection(Set(items.map(\.id)))
            preset = keepPreset
        }
        if autoPreview != nil { await previewAuto() }
    }

    func cleanSelected() async {
        let targets = selectedItems
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        let toTrash = UserDefaults.standard.bool(forKey: Prefs.deleteToTrash)
        let result = await Task.detached(priority: .userInitiated) {
            CleanupEngine.clean(targets, toTrash: toTrash)
        }.value
        lastResult = result
        isCleaning = false
        onDiskChanged?()
        await scanAll()
    }

    // MARK: Hızlı / otomatik temizlik

    /// Güvenli öğeleri tarar ve kalıcı olarak siler. Menü çubuğundaki "Hızlı Temizlik" ve zamanlayıcı bunu kullanır.
    @discardableResult
    func quickClean(automatic: Bool = false) async -> CleanupResult? {
        guard !isBusy else { return nil }
        quickState = .scanning
        let ctx = await CleanupContext.current()
        let targets = await CleanupScanner.scan(context: ctx, autoOnly: true)
        quickState = .cleaning
        let result = await Task.detached(priority: automatic ? .background : .userInitiated) {
            CleanupEngine.clean(targets)
        }.value
        quickState = .done(freed: result.freed, items: result.cleanedItems)
        lastAutoDate = Date()
        lastAutoBytes = result.freed
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.lastAutoCleanDate)
        UserDefaults.standard.set(Int(result.freed), forKey: Prefs.lastAutoCleanBytes)
        onDiskChanged?()
        if automatic, result.freed > 50_000_000, UserDefaults.standard.bool(forKey: Prefs.notifyAfterClean) {
            Notifier.post(title: L("Otomatik temizlik tamamlandı", "Automatic cleanup finished", "Автоочистка завершена"),
                          body: L("\(Fmt.bytes(result.freed)) yer açıldı (\(result.cleanedItems) öğe).", "Freed \(Fmt.bytes(result.freed)) (\(result.cleanedItems) items).", "Освобождено \(Fmt.bytes(result.freed)) (объектов: \(result.cleanedItems))."))
        }
        if !items.isEmpty { await scanAll() }
        return result
    }

    /// Otomatik temizliğin kapsayabileceği her şeyi kapalı kurallar dahil ölçer (hiçbir şey silmez).
    /// Ekran, kuralı açık olanları süzerek "şu an ne silinir" sorusunu yanıtlar.
    @Published private(set) var autoPreview: [CleanupItem]?
    @Published private(set) var isPreviewing = false

    func previewAuto() async {
        guard !isPreviewing else { return }
        isPreviewing = true
        let ctx = await CleanupContext.current()
        autoPreview = await CleanupScanner.scan(context: ctx, autoOnly: true, allRules: true)
        isPreviewing = false
    }

    /// Zamanlamaya göre bir sonraki otomatik temizliğin yaklaşık zamanı (kontrol 15 dakikada bir yapılır).
    var nextAutoDate: Date? {
        let d = UserDefaults.standard
        let hours = d.integer(forKey: Prefs.autoCleanIntervalHours)
        guard d.bool(forKey: Prefs.autoStorageEnabled), hours > 0 else { return nil }
        guard let last = lastAutoDate else { return Date() }
        return max(Date(), last.addingTimeInterval(Double(hours) * 3600))
    }

    func startAutoSchedule() {
        autoTimer?.invalidate()
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoCheck() }
        }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
        Task {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await autoCheck()
        }
    }

    func autoCheck() async {
        guard !isBusy else { return }
        let d = UserDefaults.standard
        let since = lastAutoDate.map { Date().timeIntervalSince($0) } ?? .infinity
        guard d.bool(forKey: Prefs.autoStorageEnabled) else { return }
        let hours = d.integer(forKey: Prefs.autoCleanIntervalHours)
        let threshold = Int64(d.integer(forKey: Prefs.lowDiskThresholdGB)) * 1_000_000_000

        // Saat 0 = "zamanlama yok": yalnızca disk dolunca çalışır.
        let scheduled = hours > 0 && since >= Double(hours) * 3600
        let lowDisk = d.bool(forKey: Prefs.lowDiskEnabled) && DiskReader.read().available < threshold && since > 3600
        if scheduled || lowDisk {
            await quickClean(automatic: true)
        }
    }
}

enum Notifier {
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
