import SwiftUI
import AppKit

/// Otomasyon: MultiMac'in senin yerine yapabileceği iki iş. Her biri tek bir kart; kural soru-cevap biçiminde.
struct AutomationView: View {
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var relief: MemoryRelief
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var appState: AppState

    // Önbellek temizliği
    @AppStorage(Prefs.autoStorageEnabled) private var storageOn = false
    @AppStorage(Prefs.autoCleanIntervalHours) private var interval = 6
    @AppStorage(Prefs.lowDiskEnabled) private var lowDisk = true
    @AppStorage(Prefs.lowDiskThresholdGB) private var threshold = 10
    @AppStorage(Prefs.notifyAfterClean) private var notify = true
    @AppStorage(AutoSettings.skipRunningApps) private var skipRunning = true
    @AppStorage(AutoSettings.logAgeDays) private var logDays = 7
    @State private var ruleTick = 0
    @State private var hoveredRule: AutoRule?
    @State private var showPreview = false

    // RAM
    @AppStorage(MemoryRelief.enabledKey) private var ramOn = false
    @AppStorage(MemoryRelief.triggerKey) private var ramTrigger = MemoryRelief.Trigger.pressureWarning.rawValue
    @AppStorage(MemoryRelief.swapPercentKey) private var ramSwap = 80
    @AppStorage(MemoryRelief.sustainKey) private var ramSustain = 2
    @AppStorage(MemoryRelief.idleKey) private var ramIdle = 20
    @AppStorage(MemoryRelief.cooldownKey) private var ramCooldown = 30
    @AppStorage(MemoryRelief.notifyKey) private var ramNotify = true
    @State private var ramApps: [String] = Prefs.list(MemoryRelief.appsKey)
    @State private var confirmRelief = false

    @State private var showSafety = false
    @State private var showAdvanced = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Otomasyon", subtitle: "MultiMac'in senin yerine yapabileceği iki iş",
                       symbol: "wand.and.stars", color: .purple) {
                HStack(spacing: 6) {
                    Badge(text: storageOn ? "Önbellek: açık" : "Önbellek: kapalı", color: storageOn ? .green : .secondary)
                    Badge(text: ramOn ? "RAM: açık" : "RAM: kapalı", color: ramOn ? .green : .secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    storageCard
                    ramCard
                    Collapsible(title: "Asla dokunulmayanlar", symbol: "checkmark.shield.fill", color: .green,
                                hint: "Otomasyonun hiçbir koşulda silmediği şeyler", isOpen: $showSafety) { safetyContent }
                    Collapsible(title: "Gelişmiş", symbol: "slider.horizontal.3", color: .gray,
                                hint: "Bildirimler, açık uygulamalar, günlük yaşı, bekleme süresi", isOpen: $showAdvanced) { advancedContent }
                    Collapsible(title: "Geçmiş", symbol: "clock.arrow.circlepath", color: .gray,
                                hint: historyHint, isOpen: $showHistory) { historyContent }
                }
                .padding(24)
            }
        }
        .task { if cleanup.autoPreview == nil { await cleanup.previewAuto() } }
        .alert("Listedeki uygulamalar şimdi kapatılsın mı?", isPresented: $confirmRelief) {
            Button("Kapat", role: .destructive) {
                Task { await relief.relieve(reason: "Elle başlatıldı", ignoreIdle: true) }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            let names = relief.candidates(ignoreIdle: true).compactMap(\.localizedName)
            Text(names.isEmpty ? "Listede şu an açık ve arka planda olan uygulama yok."
                 : "\(names.joined(separator: ", ")) düzgünce kapatılacak. Kaydedilmemiş belge varsa uygulama soracak.")
        }
    }

    // MARK: - Önbellek kartı

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TaskHeader(title: "Önbellekleri kendiliğinden temizle",
                       subtitle: "Uygulamaların gerektiğinde yeniden oluşturduğu çöpü siler. Belgelerine ve ayarlarına dokunmaz.",
                       symbol: "sparkles", color: .green, isOn: $storageOn)

            VStack(alignment: .leading, spacing: 10) {
                QuestionRow("Ne zaman?") {
                    PillPicker(selection: $interval, options: [
                        (1, "Her saat"), (6, "6 saatte bir"), (12, "12 saatte bir"),
                        (24, "Her gün"), (168, "Her hafta"), (0, "Zamanlama yok"),
                    ], custom: { "\($0) saatte bir" })
                }
                QuestionRow("Disk dolarsa?") {
                    PillPicker(selection: lowDiskBinding, options: [
                        (0, "Bir şey yapma, zamanını bekle"),
                        (5, "Boş alan 5 GB'ın altına inince hemen temizle"),
                        (10, "Boş alan 10 GB'ın altına inince hemen temizle"),
                        (20, "Boş alan 20 GB'ın altına inince hemen temizle"),
                        (30, "Boş alan 30 GB'ın altına inince hemen temizle"),
                        (50, "Boş alan 50 GB'ın altına inince hemen temizle"),
                    ], custom: { "Boş alan \($0) GB'ın altına inince hemen temizle" })
                }
                if interval == 0 && !lowDisk {
                    Label("Bu ayarlarla otomatik temizlik hiç çalışmaz. Bir zaman ya da disk eşiği seç.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.leading, questionWidth + 12)
                }
                QuestionRow("Neler temizlensin?", alignTop: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowLayout(spacing: 6) {
                            ForEach(AutoRule.allCases) { rule in ruleChip(rule) }
                        }
                        Text(hoveredRule?.detail ?? "Bir kutunun üzerine gel, neleri kapsadığını gör. Tıklayınca açılır ya da kapanır.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .opacity(storageOn ? 1 : 0.6)

            Divider()
            HStack(spacing: 10) {
                Image(systemName: storageOn ? "clock" : "pause.circle").foregroundStyle(.secondary)
                Text(storageStatus).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if cleanup.isPreviewing { ProgressView().controlSize(.small) }
                Button {
                    showPreview.toggle()
                    if showPreview { Task { await cleanup.previewAuto() } }
                } label: {
                    Label(showPreview ? "Listeyi gizle" : "Ne silinir?", systemImage: showPreview ? "chevron.up" : "eye")
                }
                Button {
                    Task {
                        await cleanup.quickClean()
                        await cleanup.previewAuto()
                    }
                } label: {
                    Label(cleanup.isBusy ? "Temizleniyor…" : "Şimdi çalıştır", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(cleanup.isBusy || enabledItems.isEmpty)
            }
            if showPreview { previewList }
        }
        .card(padding: 18)
    }

    /// Disk eşiği tek bir seçimde: 0 = kapalı, aksi halde GB.
    private var lowDiskBinding: Binding<Int> {
        Binding(get: { lowDisk ? threshold : 0 },
                set: { v in
                    if v == 0 { lowDisk = false } else { lowDisk = true; threshold = v }
                })
    }

    private func ruleBinding(_ rule: AutoRule) -> Binding<Bool> {
        Binding(get: { _ = ruleTick; return AutoSettings.isEnabled(rule) },
                set: { UserDefaults.standard.set($0, forKey: rule.key); ruleTick += 1 })
    }

    private func size(of rule: AutoRule) -> Int64? {
        guard let items = cleanup.autoPreview else { return nil }
        return items.filter { $0.autoRule == rule }.reduce(Int64(0)) { $0 + $1.size }
    }

    /// Şu an kuralı açık olan, gerçekten silinecek öğeler.
    private var enabledItems: [CleanupItem] {
        _ = ruleTick
        return (cleanup.autoPreview ?? []).filter { $0.autoRule.map(AutoSettings.isEnabled) ?? false }
    }

    private func ruleChip(_ rule: AutoRule) -> some View {
        let on = ruleBinding(rule)
        let bytes = size(of: rule)
        return Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on.wrappedValue ? Color.green : Color.secondary)
                Text(rule.shortTitle)
                if let bytes {
                    Text(bytes > 0 ? Fmt.bytes(bytes) : "boş")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on.wrappedValue ? Color.green.opacity(0.12) : Color.primary.opacity(0.04))
                    .stroke(on.wrappedValue ? Color.green.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredRule = rule } else if hoveredRule == rule { hoveredRule = nil }
        }
    }

    private var storageStatus: String {
        let total = enabledItems.reduce(Int64(0)) { $0 + $1.size }
        let now = cleanup.autoPreview == nil ? "" : " Şu an \(Fmt.bytes(total)) temizlenebilir."
        let last = cleanup.lastAutoDate.map { " Son temizlik \(Fmt.relative($0)), \(Fmt.bytes(cleanup.lastAutoBytes))." } ?? ""
        guard storageOn else { return "Kapalı. Yalnızca \"Şimdi çalıştır\"a basınca temizler." + now }
        if let next = cleanup.nextAutoDate {
            let when = next.timeIntervalSinceNow < 15 * 60 ? "birkaç dakika içinde" : Fmt.relative(next)
            return "Sonraki temizlik \(when)." + last
        }
        return lowDisk ? "Yalnızca boş alan \(threshold) GB'ın altına inince çalışır." + last
            : "Çalışmıyor: zaman ya da disk eşiği seçilmedi."
    }

    private var previewList: some View {
        let items = enabledItems
        return VStack(alignment: .leading, spacing: 6) {
            Text(items.isEmpty ? "Şu an temizlenecek bir şey yok."
                 : "Şimdi çalışsa \(items.count) öğeden \(Fmt.bytes(items.reduce(Int64(0)) { $0 + $1.size })) silinir:")
                .font(.callout.weight(.semibold))
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(items.prefix(15)) { item in
                    HStack {
                        Image(systemName: item.autoRule?.symbol ?? "circle").foregroundStyle(.green).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Asla dokunma: \(item.urls.first?.lastPathComponent ?? "")") {
                            item.urls.forEach { cleanup.exclude(path: $0.path) }
                            Task { await cleanup.previewAuto() }
                        }
                    }
                }
            }
            if items.count > 15 {
                Text("…ve \(items.count - 15) öğe daha").font(.caption).foregroundStyle(.secondary)
            }
            Text("Önizleme hiçbir şey silmez. Bir satıra sağ tıklayıp \"Asla dokunma\" dersen otomasyon onu bir daha silmez.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - RAM kartı

    private var ramCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TaskHeader(title: "Bellek sıkışınca uygulama kapat",
                       subtitle: "RAM'i gerçekten açmanın tek güvenli yolu. Yalnızca senin seçtiğin uygulamalar, düzgünce kapatılır.",
                       symbol: "memorychip", color: .blue, isOn: $ramOn)

            VStack(alignment: .leading, spacing: 10) {
                QuestionRow("Ne zaman?") {
                    HStack(spacing: 6) {
                        PillPicker(selection: triggerBinding, options: [
                            ("w", "Bellek sıkışınca"), ("c", "Bellek kritik olunca"),
                            ("s50", "Swap %50 dolunca"), ("s70", "Swap %70 dolunca"), ("s80", "Swap %80 dolunca"),
                            ("s90", "Swap %90 dolunca"),
                        ])
                        PillPicker(selection: $ramSustain, options: [
                            (0, "hemen"), (1, "1 dakika sürerse"), (2, "2 dakika sürerse"),
                            (5, "5 dakika sürerse"), (10, "10 dakika sürerse"),
                        ], custom: { "\($0) dakika sürerse" })
                    }
                }
                QuestionRow("Hangi uygulamalar?", alignTop: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowLayout(spacing: 6) {
                            ForEach(ramApps, id: \.self) { name in appChip(name) }
                            addAppMenu
                        }
                        if ramApps.isEmpty {
                            Text("Liste boş, yani hiçbir uygulama kapatılmaz. Arka planda RAM tutan ama hemen gerekmeyenleri ekle: Spotify, Discord, WhatsApp, Slack…")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                QuestionRow("Hangileri kapansın?") {
                    PillPicker(selection: $ramIdle, options: [
                        (0, "Arka plandaki hepsi"), (5, "5 dakikadır kullanmadıklarım"),
                        (10, "10 dakikadır kullanmadıklarım"), (20, "20 dakikadır kullanmadıklarım"),
                        (30, "30 dakikadır kullanmadıklarım"), (60, "1 saattir kullanmadıklarım"),
                        (120, "2 saattir kullanmadıklarım"),
                    ], custom: { "\($0) dakikadır kullanmadıklarım" })
                }
                Text("Öndeki uygulama ve korunan uygulamalar asla kapatılmaz. Kaydedilmemiş belge varsa uygulama sana sorar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, questionWidth + 12)
            }
            .opacity(ramOn ? 1 : 0.6)

            Divider()
            HStack(spacing: 10) {
                Image(systemName: ramStatusSymbol.0).foregroundStyle(ramStatusSymbol.1)
                Text(ramStatus).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    confirmRelief = true
                } label: {
                    Label("Şimdi kapat…", systemImage: "xmark.circle")
                }
                .disabled(ramApps.isEmpty)
            }
        }
        .card(padding: 18)
    }

    /// Tetik ve swap yüzdesi tek seçimde: "w", "c" veya "s80".
    private var triggerBinding: Binding<String> {
        Binding(get: {
            switch MemoryRelief.Trigger(rawValue: ramTrigger) ?? .pressureWarning {
            case .pressureWarning: "w"
            case .pressureCritical: "c"
            case .swap: "s\([50, 70, 80, 90].min { abs($0 - ramSwap) < abs($1 - ramSwap) } ?? 80)"
            }
        }, set: { v in
            switch v {
            case "w": ramTrigger = MemoryRelief.Trigger.pressureWarning.rawValue
            case "c": ramTrigger = MemoryRelief.Trigger.pressureCritical.rawValue
            default:
                ramTrigger = MemoryRelief.Trigger.swap.rawValue
                ramSwap = Int(v.dropFirst()) ?? 80
            }
        })
    }

    private func bundlePath(for name: String) -> String? {
        if let path = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.bundleURL?.path {
            return path
        }
        return ["/Applications/\(name).app", "/System/Applications/\(name).app"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func appChip(_ name: String) -> some View {
        HStack(spacing: 6) {
            if let path = bundlePath(for: name) {
                AppIconView(bundlePath: path, size: 16)
            } else {
                Image(systemName: "app.fill").foregroundStyle(.blue)
            }
            Text(name)
            Button {
                ramApps.removeAll { $0 == name }
                Prefs.setList(MemoryRelief.appsKey, ramApps)
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name) uygulamasını listeden çıkar")
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.10))
                .stroke(Color.blue.opacity(0.35), lineWidth: 1)
        )
    }

    private var runningAppNames: [String] {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName))
            .subtracting(ramApps)
            .subtracting(Prefs.list(Prefs.protectedApps))
            .sorted()
    }

    private var addAppMenu: some View {
        Menu {
            let names = runningAppNames
            if names.isEmpty { Text("Eklenecek açık uygulama yok") }
            ForEach(names, id: \.self) { name in
                Button(name) {
                    ramApps.append(name)
                    Prefs.setList(MemoryRelief.appsKey, ramApps)
                }
            }
        } label: {
            Label("Uygulama ekle", systemImage: "plus")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private var ramStatusSymbol: (String, Color) {
        guard ramOn else { return ("pause.circle", .secondary) }
        return relief.conditionMet(monitor.memory) ? ("exclamationmark.circle.fill", .orange) : ("checkmark.circle.fill", .green)
    }

    private var ramStatus: String {
        guard ramOn else { return "Kapalı. Yalnızca \"Şimdi kapat\"a basınca listedekileri kapatır." }
        guard !ramApps.isEmpty else { return "Açık ama liste boş, bu yüzden hiçbir şey kapatılmaz." }
        guard relief.conditionMet(monitor.memory) else { return "Bellek şu an rahat, kapatılacak bir şey yok." }
        let names = relief.candidates().compactMap(\.localizedName)
        let since = relief.conditionSince.map { " (\(Fmt.relative($0)) başladı)" } ?? ""
        return names.isEmpty
            ? "Koşul sağlanıyor\(since) ama listeden kapatılmaya uygun uygulama yok."
            : "Koşul sağlanıyor\(since). Sırada: \(names.joined(separator: ", "))."
    }

    // MARK: - Katlanan bölümler

    private var safetyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([
                ("internaldrive", "Sistem dosyaları: /System, /Library, /private"),
                ("apple.logo", "Apple'ın kendi önbellekleri"),
                ("person.crop.circle", "Uygulama verileri ve ayarları"),
                ("lock.fill", "Tarayıcı geçmişi, çerezler ve şifreler"),
                ("folder.fill", "node_modules, .venv, İndirilenler, büyük dosyalar ve Çöp Kutusu"),
                ("hammer.fill", "Açık Xcode'un DerivedData'sı ve içinde dev server çalışan projelerin önbellekleri"),
            ], id: \.1) { symbol, text in
                Label(text, systemImage: symbol).font(.callout)
            }
            HStack {
                Label("\"Asla dokunma\" listende \(Exclusions.all.count) öğe var", systemImage: "hand.raised.fill")
                    .font(.callout)
                Spacer()
                Button("Listeyi düzenle") { appState.tab = .settings }
            }
            .padding(.top, 4)
        }
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Önbellek temizliği").font(.subheadline.weight(.semibold))
            Toggle("Temizlikten sonra bildirim göster", isOn: $notify)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Açık uygulamaların önbelleklerini atla", isOn: $skipRunning)
                Text("Kapatırsan açık uygulamaların (ör. Chrome) önbellekleri de silinir; uygulama bir süre yavaşlayabilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Günlükler \(logDays) günden eskiyse silinsin", value: $logDays, in: 1...90)
            Divider()
            Text("Bellek").font(.subheadline.weight(.semibold))
            Toggle("Uygulama kapattıktan sonra bildirim göster", isOn: $ramNotify)
            VStack(alignment: .leading, spacing: 2) {
                Stepper("İki kapatma arasında en az \(ramCooldown) dakika bekle", value: $ramCooldown, in: 5...240, step: 5)
                Text("Bellek sıkışık kalmaya devam ederse uygulamaları art arda kapatmasın diye.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: logDays) { Task { await cleanup.previewAuto() } }
        .onChange(of: skipRunning) { Task { await cleanup.previewAuto() } }
    }

    private var historyHint: String {
        cleanup.lastAutoDate == nil && relief.history.isEmpty
            ? "Henüz bir şey yapılmadı" : "Son temizlik ve kapatılan uygulamalar"
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let date = cleanup.lastAutoDate {
                HStack(alignment: .top) {
                    Image(systemName: "sparkles").foregroundStyle(.green).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Önbellek temizliği: \(Fmt.bytes(cleanup.lastAutoBytes)) yer açıldı")
                        Text(Fmt.relative(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(relief.history) { a in
                HStack(alignment: .top) {
                    Image(systemName: "memorychip").foregroundStyle(.blue).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Kapatıldı: \(a.apps.joined(separator: ", "))").lineLimit(2)
                        Text("\(Fmt.relative(a.date)) · ~\(Fmt.bytes(a.freed)) · \(a.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if cleanup.lastAutoDate == nil && relief.history.isEmpty {
                Text("Otomasyon henüz bir şey yapmadı.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Yapı taşları

/// Soru sütununun genişliği; uyarı ve not satırları buna göre içeri kaydırılır.
private let questionWidth: CGFloat = 150

/// Kartın üst satırı: ikon, ne yaptığını anlatan başlık ve tek ana anahtar.
private struct TaskHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Text(isOn ? "Açık" : "Kapalı")
                .font(.callout.weight(.medium))
                .foregroundStyle(isOn ? color : .secondary)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(color)
        }
    }
}

/// Soldaki soru, sağdaki cevap.
private struct QuestionRow<Content: View>: View {
    let question: String
    let alignTop: Bool
    let content: Content

    init(_ question: String, alignTop: Bool = false, @ViewBuilder content: () -> Content) {
        self.question = question
        self.alignTop = alignTop
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 12) {
            Text(question)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: questionWidth, alignment: .leading)
                .padding(.top, alignTop ? 6 : 0)
            content
            Spacer(minLength: 0)
        }
    }
}

/// Seçili değeri bir hap içinde gösteren açılır menü.
private struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    /// Kayıtlı değer listede yoksa (eski sürümden ya da elle girilmiş) gösterilecek metin.
    var custom: (Value) -> String = { "\($0)" }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    selection = options[i].0
                } label: {
                    if options[i].0 == selection {
                        Label(options[i].1, systemImage: "checkmark")
                    } else {
                        Text(options[i].1)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? custom(selection))
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Başlığa tıklayınca açılan kart.
private struct Collapsible<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let hint: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
                    Text(title).font(.headline)
                    Text(hint).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Divider()
                content()
            }
        }
        .card(padding: 14)
    }
}

/// Öğeleri satıra sığdığı kadar dizer, sığmayanı alt satıra geçirir.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(Row())
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
