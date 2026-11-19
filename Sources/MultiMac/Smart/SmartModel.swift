import Foundation

// MARK: - Özellikler

/// Modelin her öneriye baktığı sayılar. Hepsi kabaca 0…1 aralığına ölçeklenir.
enum SmartFeature: Int, CaseIterable, Codable {
    case idle            // kaç gündür değişmedi (log)
    case unopened        // kaç gündür açılmadı (log); bilinmiyorsa idle ile aynı
    case lastUsedUnknown // "son kullanım" bilgisi yok
    case size            // boyut (log, 1 MB → 0, 10 GB → 1)
    case recentGrowth    // son 7 günde büyüme oranı
    case burstThenIdle   // kısa sürede büyüdü, sonra durdu
    case regrows         // temizlendikten sonra hızla geri doluyor
    case ownerMissing    // sahibi uygulama artık yüklü değil
    case ownerRunning    // sahibi uygulama açık
    case projectIdle     // ait olduğu proje kaç gündür boşta (log)
    case projectBusy     // projede süreç çalışıyor
    case newerVersion    // daha yeni sürümü var
    case regenerable     // yeniden oluşturulabilir / indirilebilir
    case cleanedBefore   // kullanıcı bu yolu daha önce temizledi

    var title: String {
        switch self {
        case .idle: L("Dokunulmama süresi", "Time untouched", "Время без изменений")
        case .unopened: L("Açılmama süresi", "Time unopened", "Время без открытия")
        case .lastUsedUnknown: L("Kullanım bilgisi yok", "No usage data", "Нет данных об использовании")
        case .size: L("Boyut", "Size", "Размер")
        case .recentGrowth: L("Son haftadaki büyüme", "Growth this week", "Рост за неделю")
        case .burstThenIdle: L("Büyüyüp durması", "Grew, then stopped", "Вырос и остановился")
        case .regrows: L("Hızla geri dolması", "Refills quickly", "Быстро заполняется снова")
        case .ownerMissing: L("Uygulaması silinmiş", "Its app was removed", "Приложение удалено")
        case .ownerRunning: L("Uygulaması açık", "Its app is running", "Приложение запущено")
        case .projectIdle: L("Projenin boşta kalması", "Project idle", "Проект простаивает")
        case .projectBusy: L("Projede iş sürüyor", "Project in use", "Проект используется")
        case .newerVersion: L("Yeni sürümünün olması", "A newer version exists", "Есть новая версия")
        case .regenerable: L("Yeniden oluşturulabilmesi", "Can be recreated", "Можно создать заново")
        case .cleanedBefore: L("Daha önce temizlemen", "You cleaned it before", "Вы уже очищали")
        }
    }
}

typealias FeatureVector = [Double]

extension Array where Element == Double {
    static var zeroFeatures: FeatureVector { Array(repeating: 0, count: SmartFeature.allCases.count) }
    subscript(_ f: SmartFeature) -> Double {
        get { self[f.rawValue] }
        set { self[f.rawValue] = newValue }
    }
}

enum FeatureScale {
    static func days(_ d: Int?) -> Double {
        guard let d, d > 0 else { return 0 }
        return min(1, log1p(Double(d)) / log1p(365))
    }
    static func bytes(_ b: Int64) -> Double {
        guard b > 0 else { return 0 }
        return min(1, max(0, (log10(Double(b)) - 6) / 4))
    }
}

// MARK: - Model

/// Lojistik regresyon: p = σ(tür sabiti + Σ ağırlık × özellik).
/// ~15 ağırlık + tür başına bir sabit; diskte ve bellekte 1 KB civarı. Her geri bildirimde tek adım öğrenir.
struct SmartModel: Codable {
    var version = 1
    var weights: [Double]
    var bias: [String: Double]
    /// Kaç geri bildirimden öğrendi
    var updates = 0

    /// Başlangıç ağırlıkları: bugünkü kurallardan elle çıkarıldı. İlk gün de makul öneri verir.
    static let prior: SmartModel = {
        var w = FeatureVector.zeroFeatures
        w[.idle] = 2.2
        w[.unopened] = 1.6
        w[.lastUsedUnknown] = -0.3
        w[.size] = 1.0
        w[.recentGrowth] = -1.6
        w[.burstThenIdle] = 1.4
        w[.regrows] = -2.6
        w[.ownerMissing] = 2.4
        w[.ownerRunning] = -2.2
        w[.projectIdle] = 1.6
        w[.projectBusy] = -3.0
        w[.newerVersion] = 1.8
        w[.regenerable] = 0.9
        w[.cleanedBefore] = 0.8
        var b: [String: Double] = [:]
        for k in SmartKind.allCases { b[k.rawValue] = k.priorBias }
        return SmartModel(weights: w, bias: b)
    }()

    static func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-z)) }

    func score(_ x: FeatureVector, kind: SmartKind) -> Double {
        Self.sigmoid(logit(x, kind: kind))
    }

    func logit(_ x: FeatureVector, kind: SmartKind) -> Double {
        var z = bias[kind.rawValue] ?? kind.priorBias
        for i in weights.indices where i < x.count { z += weights[i] * x[i] }
        return z
    }

    /// Puana en çok katkı veren özellikler (açıklama satırı için).
    func contributions(_ x: FeatureVector) -> [(SmartFeature, Double)] {
        SmartFeature.allCases.map { ($0, weights[$0.rawValue] * x[$0.rawValue]) }.sorted { $0.1 > $1.1 }
    }

    /// Tek adımlık öğrenme. Ağırlıklar başlangıç değerlerine doğru hafifçe çekilir (L2),
    /// böylece tek bir karar modeli bozamaz.
    mutating func learn(_ x: FeatureVector, kind: SmartKind, label: Double, weight: Double = 1) {
        let lr = 0.12 * weight
        let lambda = 0.02
        let p = score(x, kind: kind)
        let err = label - p
        let prior = Self.prior
        for i in weights.indices where i < x.count {
            weights[i] += lr * (err * x[i] - lambda * (weights[i] - prior.weights[i]))
            weights[i] = min(6, max(-6, weights[i]))
        }
        let k = kind.rawValue
        let b0 = prior.bias[k] ?? 0
        bias[k] = min(4, max(-4, (bias[k] ?? b0) + lr * (err - lambda * ((bias[k] ?? b0) - b0))))
        updates += 1
    }
}

// MARK: - Gözlem kaydı

/// Her aday yolun günlük boyutu, temizlik olayları ve kullanıcının kararları.
/// Diskte (~300 KB'a kadar) tutulur; yalnızca analiz ve geri bildirim anında belleğe alınır.
struct SmartHistory: Codable {
    struct Sample: Codable { var d: Int; var s: Int64 }
    struct CleanEvent: Codable {
        var d: Int
        var s: Int64
        /// Model önerisiyle temizlendiyse o anki özellikler (sonradan dolaylı etiket için)
        var x: FeatureVector?
        var k: String?
        var resolved = false
    }
    struct Record: Codable {
        var samples: [Sample] = []
        var cleaned: [CleanEvent] = []
        var muted = false
        var lastSeen = 0
    }
    struct KindStat: Codable { var accepted = 0; var dismissed = 0 }

    var version = 1
    var records: [String: Record] = [:]
    var kinds: [String: KindStat] = [:]
    var lastAnalysis: Double = 0

    static var today: Int { Int(Date().timeIntervalSince1970 / 86_400) }

    mutating func observe(path: String, size: Int64, day: Int = today) {
        var r = records[path] ?? Record()
        if let last = r.samples.last, last.d == day {
            r.samples[r.samples.count - 1].s = size
        } else {
            r.samples.append(Sample(d: day, s: size))
        }
        if r.samples.count > 45 { r.samples.removeFirst(r.samples.count - 45) }
        r.lastSeen = day
        records[path] = r
    }

    mutating func recordCleaned(path: String, size: Int64, features: FeatureVector? = nil, kind: SmartKind? = nil) {
        var r = records[path] ?? Record()
        r.cleaned.append(CleanEvent(d: Self.today, s: size, x: features, k: kind?.rawValue))
        if r.cleaned.count > 12 { r.cleaned.removeFirst(r.cleaned.count - 12) }
        r.samples.append(Sample(d: Self.today, s: 0))
        r.lastSeen = Self.today
        records[path] = r
    }

    /// Eski ve küçük kayıtları atar: dosya hiçbir zaman şişmesin.
    mutating func prune() {
        let today = Self.today
        records = records.filter { today - $0.value.lastSeen <= 60 || $0.value.muted }
        if records.count > 900 {
            let keep = records.sorted { ($0.value.samples.last?.s ?? 0) > ($1.value.samples.last?.s ?? 0) }.prefix(900)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    // MARK: Geçmişten çıkarılan bilgiler

    /// Temizlendikten sonra kaç günde, ne kadar geri doldu. (gün, boyut) — en son temizlik için.
    func regrowth(_ path: String) -> (days: Int, size: Int64)? {
        guard let r = records[path], let ev = r.cleaned.last, ev.s > 0 else { return nil }
        let after = r.samples.filter { $0.d > ev.d }
        guard let back = after.first(where: { $0.s >= ev.s / 2 }) else { return nil }
        return (back.d - ev.d, back.s)
    }

    /// Son 7 günde büyüme (bayt).
    func growth(_ path: String, days: Int = 7) -> Int64 {
        guard let r = records[path], let last = r.samples.last else { return 0 }
        guard let base = r.samples.last(where: { $0.d <= last.d - days }) ?? r.samples.first, base.d < last.d else { return 0 }
        return max(0, last.s - base.s)
    }

    /// Kısa sürede (≤3 gün) büyük büyüme ve ardından ≥14 gün durgunluk. (büyüme günü, büyüme miktarı)
    func burst(_ path: String) -> (day: Int, amount: Int64)? {
        guard let r = records[path], r.samples.count >= 3, let last = r.samples.last else { return nil }
        var best: (Int, Int64)?
        for i in r.samples.indices {
            for j in (i + 1)..<r.samples.count where r.samples[j].d - r.samples[i].d <= 3 {
                let g = r.samples[j].s - r.samples[i].s
                if g > (best?.1 ?? 0) { best = (r.samples[j].d, g) }
            }
        }
        guard let (day, amount) = best, amount > max(300_000_000, last.s * 3 / 10), last.d - day >= 14 else { return nil }
        let flat = r.samples.filter { $0.d >= day }.allSatisfy { abs($0.s - last.s) < max(50_000_000, last.s / 20) }
        return flat ? (day, amount) : nil
    }

    func timesCleaned(_ path: String) -> Int { records[path]?.cleaned.count ?? 0 }
    func isMuted(_ path: String) -> Bool { records[path]?.muted ?? false }
}

// MARK: - Disk üzerindeki dosyalar

enum SmartStorage {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.multimac", isDirectory: true)
    }
    private static var historyURL: URL { dir.appendingPathComponent("smart-history.json") }
    private static var modelURL: URL { dir.appendingPathComponent("smart-model.json") }

    static func loadHistory() -> SmartHistory {
        guard let data = try? Data(contentsOf: historyURL),
              let h = try? JSONDecoder().decode(SmartHistory.self, from: data) else { return SmartHistory() }
        return h
    }

    static func save(_ h: SmartHistory) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(h) { try? data.write(to: historyURL, options: .atomic) }
    }

    static func loadModel() -> SmartModel {
        guard let data = try? Data(contentsOf: modelURL),
              let m = try? JSONDecoder().decode(SmartModel.self, from: data),
              m.weights.count == SmartFeature.allCases.count else { return .prior }
        return m
    }

    static func save(_ m: SmartModel) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: modelURL, options: .atomic) }
    }

    /// Öğrenilenleri sıfırla: model başlangıç ağırlıklarına döner, susturulan öneriler geri gelir.
    /// Boyut geçmişi (ham gözlem) korunur.
    static func resetLearning() {
        try? FileManager.default.removeItem(at: modelURL)
        var h = loadHistory()
        for k in h.records.keys { h.records[k]?.muted = false }
        h.kinds = [:]
        save(h)
    }

    static var diskBytes: Int64 {
        [historyURL, modelURL].reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
