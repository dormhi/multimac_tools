import AppKit

/// Önerinin neden yapıldığını anlatan gerçekler. Metin ekranda o anki dille üretilir.
enum SmartFact: Hashable {
    case idle(Int), unopened(Int), burst(day: Int, amount: Int64), regrows(days: Int, size: Int64)
    case ownerMissing, ownerRunning, projectIdle(Int), projectBusy, newerVersion, regenerable
    case cleanedBefore(Int), growth(Int64)

    var text: String {
        switch self {
        case .idle(let d): return L("\(d) gündür değişmedi", "Unchanged for \(d) days", "Не менялось дней: \(d)")
        case .unopened(let d): return L("\(d) gündür açılmadı", "Not opened for \(d) days", "Не открывалось дней: \(d)")
        case .burst(let day, let amount):
            let date = Date(timeIntervalSince1970: Double(day) * 86_400)
            return L("\(Fmt.shortDate(date)) civarı \(Fmt.bytes(amount)) büyüdü, sonra durdu", "Grew by \(Fmt.bytes(amount)) around \(Fmt.shortDate(date)), then stopped", "Вырос на \(Fmt.bytes(amount)) около \(Fmt.shortDate(date)) и остановился")
        case .regrows(let days, let size): return L("Temizlendikten \(days) gün sonra \(Fmt.bytes(size))'a döndü", "Back to \(Fmt.bytes(size)) \(days) days after cleaning", "Вернулся к \(Fmt.bytes(size)) через \(days) дн. после очистки")
        case .ownerMissing: return L("Uygulaması artık yüklü değil", "Its app is no longer installed", "Приложение больше не установлено")
        case .ownerRunning: return L("Uygulaması açık", "Its app is running", "Приложение запущено")
        case .projectIdle(let d): return L("Proje \(d) gündür boşta", "Project idle for \(d) days", "Проект простаивает дней: \(d)")
        case .projectBusy: return L("Projede çalışan süreç var", "A process is running in the project", "В проекте запущен процесс")
        case .newerVersion: return L("Daha yeni sürümü var", "A newer version is installed", "Установлена новая версия")
        case .regenerable: return L("Gerekirse yeniden indirilir", "Downloaded again if needed", "При необходимости загрузится снова")
        case .cleanedBefore(let n): return L("Bunu daha önce \(n) kez temizledin", "You cleaned this \(n) times before", "Вы уже очищали это \(n) раз")
        case .growth(let b): return L("Bu hafta \(Fmt.bytes(b)) büyüdü", "Grew by \(Fmt.bytes(b)) this week", "Вырос на \(Fmt.bytes(b)) за неделю")
        }
    }
}

struct SmartItem: Identifiable {
    enum Section { case suggest, regrows, keep }
    enum KeepReason { case personal, learned, info }

    let id: String
    let kind: SmartKind
    let title: String
    let detail: String
    let urls: [URL]
    let action: SmartAction
    var size: Int64
    var features: FeatureVector
    var score: Double
    var section: Section
    var facts: [SmartFact]
    var keepReason: KeepReason?
}

/// Diskteki gözlem kaydı ve model: tek sırayla okunup yazılır (analiz, geri bildirim, temizlik kaydı).
actor SmartDisk {
    static let shared = SmartDisk()

    func update<T>(_ body: (inout SmartHistory, inout SmartModel) -> T) -> T {
        var h = SmartStorage.loadHistory()
        var m = SmartStorage.loadModel()
        let result = body(&h, &m)
        h.prune()
        SmartStorage.save(h)
        SmartStorage.save(m)
        return result
    }

    func read<T>(_ body: (SmartHistory, SmartModel) -> T) -> T {
        body(SmartStorage.loadHistory(), SmartStorage.loadModel())
    }

    func reset() { SmartStorage.resetLearning() }

    /// Normal temizlik ve hızlı temizlik de kaydedilir: "geri doldu mu?" sorusu için.
    func recordCleaned(_ items: [(id: String, size: Int64)]) {
        update { h, _ in items.forEach { h.recordCleaned(path: $0.id, size: $0.size) } }
    }
}

@MainActor
final class SmartStore: ObservableObject {
    @Published private(set) var items: [SmartItem] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isCleaning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var analyzedAt: Date?
    @Published private(set) var lastResult: CleanupResult?
    @Published var selected: Set<String> = []
    /// Model kartı için özet
    @Published private(set) var stats = Stats()

    struct Stats {
        var observedPaths = 0
        var decisions = 0
        var updates = 0
        var hidden = 0
        var diskBytes: Int64 = 0
        var topWeights: [(SmartFeature, Double)] = []
    }

    var onDiskChanged: (() -> Void)?

    var suggestions: [SmartItem] { items.filter { $0.section == .suggest } }
    var regrowing: [SmartItem] { items.filter { $0.section == .regrows } }
    var keep: [SmartItem] { items.filter { $0.section == .keep } }
    var selectedItems: [SmartItem] { suggestions.filter { selected.contains($0.id) && isDeletable($0) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var suggestedSize: Int64 { suggestions.reduce(0) { $0 + $1.size } }

    func isDeletable(_ item: SmartItem) -> Bool {
        if case .delete = item.action { return true }
        return false
    }

    nonisolated static let threshold = 0.6
    nonisolated static let minimumSize: Int64 = 50_000_000

    // MARK: Analiz

    func analyzeIfNeeded() async {
        guard !isAnalyzing else { return }
        // Analiz sürerken de model kartı dolu görünsün: kayıtlı özet hemen okunur.
        if analyzedAt == nil, stats.topWeights.isEmpty {
            stats = await SmartDisk.shared.read { h, m in Self.makeStats(h, m) }
        }
        if let at = analyzedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        await analyze()
    }

    /// Günde en fazla bir kez, uygulama arka plandayken: sessiz gözlem (öğrenme için boyut geçmişi).
    func dailyObservationIfNeeded() async {
        guard !isAnalyzing, !NSApp.isActive else { return }
        let last = await SmartDisk.shared.read { h, _ in h.lastAnalysis }
        guard Date().timeIntervalSince1970 - last > 23 * 3600 else { return }
        await analyze(priority: .background)
    }

    func analyze(priority: TaskPriority = .utility) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        progress = 0
        let ctx = await CleanupContext.current()
        let candidates = await Task.detached(priority: priority) { Self.collect(ctx) }.value
        let measured = await measure(candidates, priority: priority)
        let result = await SmartDisk.shared.update { h, m in Self.evaluate(measured, history: &h, model: &m) }
        items = result.items
        stats = result.stats
        stats.diskBytes = SmartStorage.diskBytes
        selected = Set(result.items.filter { $0.section == .suggest && $0.score >= 0.75 }.map(\.id))
        analyzedAt = Date()
        progress = 1
        isAnalyzing = false
    }

    /// Temizlik tarayıcısının adayları + akıllı dedektörler. Aynı yeri iki kez saymamak için
    /// dedektörün bulduğu bir yolun içinde kalan tarayıcı adayları atılır.
    nonisolated private static func collect(_ ctx: CleanupContext) -> [SmartCandidate] {
        let excluded = Exclusions.all
        var scanner = CleanupScanner.candidates(ctx, autoOnly: false)
        CleanupScanner.assignRules(&scanner, ctx, allRules: true)
        let detectors = SmartDetectors.all(ctx)
        let detectorPaths = detectors.flatMap { $0.urls.map(\.path) }
        let installers: Set<String> = ["dmg", "pkg", "xip", "iso", "mpkg"]

        let fromScanner: [SmartCandidate] = scanner.compactMap { item in
            guard item.category != .trash, item.category != .logs, item.minAgeDays == nil else { return nil }
            if item.urls.contains(where: { u in detectorPaths.contains { u.path == $0 || u.path.hasPrefix($0 + "/") } }) { return nil }
            var c = SmartCandidate(id: item.id, kind: .cache, title: item.title, detail: item.detail, urls: item.urls,
                                   action: .delete(contentsOnly: item.contentsOnly))
            switch item.category {
            case .buildArtifacts:
                c.kind = .projectLeftover
                c.projectBusy = item.inUse
                c.projectIdleDays = Fmt.days(since: item.lastUsed)
                // Sanal ortamlar paket kurulumu ister: "yeniden oluşturulabilir" sayılmaz, model daha temkinli olur.
                let name = item.urls.first?.lastPathComponent ?? ""
                c.regenerable = name != ".venv" && name != "venv"
                c.skipImportanceCheck = true
            case .appCaches, .devCaches:
                c.kind = .cache
                c.ownerRunning = item.inUse
                c.regenerable = !item.sensitive
                c.skipImportanceCheck = !item.sensitive
            case .xcode:
                c.kind = .xcode
                c.ownerRunning = item.inUse
                c.regenerable = !item.sensitive
                c.skipImportanceCheck = !item.sensitive
            case .downloads:
                let isInstaller = installers.contains(item.urls.first?.pathExtension.lowercased() ?? "")
                c.kind = isInstaller ? .download : .largeFile
                c.regenerable = isInstaller
                c.skipImportanceCheck = isInstaller
            case .largeFiles:
                c.kind = .largeFile
            case .logs, .trash:
                return nil
            }
            return c
        }
        return (detectors + fromScanner).filter { c in
            !c.urls.contains { Exclusions.isExcluded($0.path, in: excluded) }
        }
    }

    private struct Measured {
        var candidate: SmartCandidate
        var stats: PathStats
        var lastUsed: Date?
    }

    private func measure(_ candidates: [SmartCandidate], priority: TaskPriority) async -> [Measured] {
        var out: [Measured] = []
        out.reserveCapacity(candidates.count)
        var done = 0
        await withTaskGroup(of: Measured.self) { group in
            var next = 0
            func add() {
                let c = candidates[next]
                next += 1
                group.addTask(priority: priority) {
                    var s = PathStats()
                    if let known = c.knownSize {
                        s.size = known
                    } else {
                        for u in c.urls {
                            let one = SmartMeasure.stats(u.path)
                            s.size += one.size
                            s.files += one.files
                            s.sampled += one.sampled
                            s.docLike += one.docLike
                            s.newestModified = max(s.newestModified, one.newestModified)
                            s.newestAccessed = max(s.newestAccessed, one.newestAccessed)
                        }
                    }
                    // Tek dosyada macOS'un "son kullanılma" bilgisi daha anlamlı
                    var used = c.knownLastUsed
                    if used == nil, c.urls.count == 1, s.files == 1 { used = SmartMeasure.lastUsedDate(c.urls[0].path) }
                    return Measured(candidate: c, stats: s, lastUsed: used)
                }
            }
            for _ in 0..<min(3, candidates.count) { add() }
            while let m = await group.next() {
                out.append(m)
                done += 1
                progress = Double(done) / Double(max(1, candidates.count))
                if next < candidates.count { add() }
            }
        }
        return out
    }

    // MARK: Puanlama

    nonisolated private static func evaluate(_ measured: [Measured], history h: inout SmartHistory, model m: inout SmartModel)
        -> (items: [SmartItem], stats: Stats) {
        let now = Date().timeIntervalSince1970
        let homePath = NSHomeDirectory()
        learnFromOutcomes(&h, &m)

        var items: [SmartItem] = []
        var hidden = 0
        for entry in measured {
            let c = entry.candidate
            let s = entry.stats
            guard s.size >= minimumSize || (c.kind.isInfoOnly && s.size >= 20_000_000) else { continue }
            if case .delete(let contentsOnly) = c.action,
               !c.urls.allSatisfy({ CleanupEngine.isAllowed($0, contentsOnly: contentsOnly) }) { continue }
            h.observe(path: c.id, size: s.size)
            if h.isMuted(c.id) { hidden += 1; continue }

            let idleDays = s.newestModified > 0 ? Int((now - Double(s.newestModified)) / 86_400) : nil
            let usedDays: Int? = entry.lastUsed.flatMap { Fmt.days(since: $0) }
                ?? (s.newestAccessed > 0 ? Int((now - Double(max(s.newestAccessed, s.newestModified))) / 86_400) : nil)
            let regrow = h.regrowth(c.id)
            let burst = h.burst(c.id)
            let growth = h.growth(c.id)
            let cleanedTimes = h.timesCleaned(c.id)

            var x = FeatureVector.zeroFeatures
            x[.idle] = FeatureScale.days(idleDays)
            x[.unopened] = FeatureScale.days(usedDays ?? idleDays)
            x[.lastUsedUnknown] = usedDays == nil ? 1 : 0
            x[.size] = FeatureScale.bytes(s.size)
            x[.recentGrowth] = min(1, Double(growth) / Double(max(1, s.size)))
            x[.burstThenIdle] = burst == nil ? 0 : 1
            x[.regrows] = regrow.map { $0.days <= 7 ? 1 : $0.days <= 14 ? 0.5 : 0 } ?? 0
            x[.ownerMissing] = c.ownerMissing ? 1 : 0
            x[.ownerRunning] = c.ownerRunning ? 1 : 0
            x[.projectIdle] = FeatureScale.days(c.projectIdleDays)
            x[.projectBusy] = c.projectBusy ? 1 : 0
            x[.newerVersion] = c.newerVersion ? 1 : 0
            x[.regenerable] = c.regenerable ? 1 : 0
            x[.cleanedBefore] = Double(min(cleanedTimes, 5)) / 5

            let score = m.score(x, kind: c.kind)

            // Gerçekler: puana en çok katkı verenlerden metne dönüşebilenler
            var facts: [SmartFact] = []
            for (f, contribution) in m.contributions(x) where contribution > 0.15 {
                switch f {
                case .idle: if let d = idleDays, d >= 7 { facts.append(.idle(d)) }
                case .unopened: if let d = usedDays, d >= 7, d != idleDays { facts.append(.unopened(d)) }
                case .burstThenIdle: if let b = burst { facts.append(.burst(day: b.day, amount: b.amount)) }
                case .ownerMissing: facts.append(.ownerMissing)
                case .projectIdle: if let d = c.projectIdleDays { facts.append(.projectIdle(d)) }
                case .newerVersion: facts.append(.newerVersion)
                case .regenerable: facts.append(.regenerable)
                case .cleanedBefore: facts.append(.cleanedBefore(cleanedTimes))
                default: break
                }
                if facts.count == 2 { break }
            }
            if c.ownerRunning { facts.append(.ownerRunning) }
            if c.projectBusy { facts.append(.projectBusy) }
            if growth > 200_000_000 { facts.append(.growth(growth)) }

            var item = SmartItem(id: c.id, kind: c.kind, title: c.title, detail: c.detail, urls: c.urls, action: c.action,
                                 size: s.size, features: x, score: score, section: .suggest, facts: facts)

            let stat = h.kinds[c.kind.rawValue] ?? SmartHistory.KindStat()
            let inPersonalPlace = c.urls.contains { u in
                ["/Documents/", "/Desktop/", "/Library/Mobile Documents/", "/Pictures/", "/Movies/"].contains { u.path.hasPrefix(homePath + $0) }
            }
            let personalContent = !c.skipImportanceCheck && !c.regenerable
                && ((s.sampled > 0 && Double(s.docLike) / Double(s.sampled) >= 0.3) || inPersonalPlace)

            if c.kind.isInfoOnly {
                item.section = .keep
                item.keepReason = .info
            } else if personalContent {
                // Yalnızca gerçekten uzun süredir dokunulmayanlar: "eski ama önemli" listesi.
                guard (idleDays ?? 0) >= 60 else { hidden += 1; continue }
                item.section = .keep
                item.keepReason = .personal
            } else if let r = regrow, r.days <= 7 {
                item.section = .regrows
                item.facts = [.regrows(days: max(1, r.days), size: r.size)]
            } else if stat.dismissed >= 3, stat.accepted == 0, score < 0.5 {
                item.section = .keep
                item.keepReason = .learned
            } else if score >= threshold {
                item.section = .suggest
            } else {
                hidden += 1
                continue
            }
            items.append(item)
        }
        h.lastAnalysis = now

        items.sort { a, b in
            if a.section != b.section { return a.section.order < b.section.order }
            return a.size > b.size
        }
        var stats = makeStats(h, m)
        stats.hidden = hidden
        return (items, stats)
    }

    nonisolated private static func makeStats(_ h: SmartHistory, _ m: SmartModel) -> Stats {
        var stats = Stats()
        stats.observedPaths = h.records.count
        stats.decisions = h.kinds.values.reduce(0) { $0 + $1.accepted + $1.dismissed }
        stats.updates = m.updates
        stats.diskBytes = SmartStorage.diskBytes
        stats.topWeights = SmartFeature.allCases.map { ($0, m.weights[$0.rawValue]) }
            .sorted { abs($0.1) > abs($1.1) }
        return stats
    }

    /// Dolaylı etiketler: modelin önerisiyle temizlenen şey 7 gün içinde geri dolduysa yanlış öneriydi,
    /// 30 gün boyunca geri gelmediyse doğru öneriydi.
    nonisolated private static func learnFromOutcomes(_ h: inout SmartHistory, _ m: inout SmartModel) {
        let today = SmartHistory.today
        for (path, var r) in h.records {
            var changed = false
            for i in r.cleaned.indices where !r.cleaned[i].resolved {
                let ev = r.cleaned[i]
                guard let x = ev.x, let kind = ev.k.flatMap(SmartKind.init(rawValue:)) else {
                    r.cleaned[i].resolved = today - ev.d > 30
                    changed = true
                    continue
                }
                let refilled = r.samples.contains { $0.d > ev.d && $0.d <= ev.d + 7 && $0.s >= max(ev.s / 2, 20_000_000) }
                if refilled {
                    m.learn(x, kind: kind, label: 0, weight: 0.5)
                    r.cleaned[i].resolved = true
                    changed = true
                } else if today - ev.d >= 30 {
                    m.learn(x, kind: kind, label: 1, weight: 0.5)
                    r.cleaned[i].resolved = true
                    changed = true
                }
            }
            if changed { h.records[path] = r }
        }
    }

    // MARK: Geri bildirim

    /// "Önerme": bu yol bir daha önerilmez, model bu türden benzerlerine daha temkinli yaklaşır.
    func dismiss(_ item: SmartItem) {
        items.removeAll { $0.id == item.id }
        selected.remove(item.id)
        stats.hidden += 1
        stats.decisions += 1
        let x = item.features
        let kind = item.kind
        let id = item.id
        Task {
            let updates = await SmartDisk.shared.update { h, m in
                h.records[id, default: SmartHistory.Record()].muted = true
                h.kinds[kind.rawValue, default: SmartHistory.KindStat()].dismissed += 1
                m.learn(x, kind: kind, label: 0)
                return m.updates
            }
            stats.updates = updates
        }
    }

    /// Komutla silinen öneriler (brew cleanup, ollama rm): komut kopyalanınca kabul sayılır.
    func copyCommand(_ item: SmartItem) {
        guard case .command(let cmd) = item.action else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        let x = item.features
        let kind = item.kind
        Task {
            await SmartDisk.shared.update { h, m in
                h.kinds[kind.rawValue, default: SmartHistory.KindStat()].accepted += 1
                m.learn(x, kind: kind, label: 1, weight: 0.5)
            }
        }
    }

    func cleanSelected() async {
        let targets = selectedItems
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        let toTrash = UserDefaults.standard.bool(forKey: Prefs.deleteToTrash)
        let cleanupItems: [CleanupItem] = targets.map { t in
            var contentsOnly = false
            if case .delete(let c) = t.action { contentsOnly = c }
            var ci = CleanupItem(urls: t.urls, title: t.title, detail: t.detail, category: .largeFiles,
                                 autoEligible: false, defaultSelected: false, contentsOnly: contentsOnly)
            ci.size = t.size
            return ci
        }
        let result = await Task.detached(priority: .userInitiated) {
            CleanupEngine.clean(cleanupItems, toTrash: toTrash)
        }.value
        lastResult = result
        let records = targets.map { ($0.id, $0.size, $0.features, $0.kind) }
        let updates = await SmartDisk.shared.update { h, m in
            for (id, size, x, kind) in records {
                h.recordCleaned(path: id, size: size, features: x, kind: kind)
                h.kinds[kind.rawValue, default: SmartHistory.KindStat()].accepted += 1
                m.learn(x, kind: kind, label: 1)
            }
            return m.updates
        }
        let cleanedIDs = Set(targets.map(\.id))
        items.removeAll { cleanedIDs.contains($0.id) }
        selected.subtract(cleanedIDs)
        stats.updates = updates
        stats.decisions += targets.count
        isCleaning = false
        onDiskChanged?()
    }

    func resetLearning() async {
        await SmartDisk.shared.reset()
        analyzedAt = nil
        await analyze()
    }

    func toggle(_ item: SmartItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
}

private extension SmartItem.Section {
    var order: Int {
        switch self {
        case .suggest: 0
        case .regrows: 1
        case .keep: 2
        }
    }
}
