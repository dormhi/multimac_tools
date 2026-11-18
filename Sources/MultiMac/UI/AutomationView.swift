import SwiftUI
import AppKit

/// Otomatik depolama ve RAM temizliğinin tüm kuralları tek yerde.
struct AutomationView: View {
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var relief: MemoryRelief
    @EnvironmentObject private var monitor: SystemMonitor

    // Depolama
    @AppStorage(Prefs.autoCleanEnabled) private var autoClean = true
    @AppStorage(Prefs.autoCleanIntervalHours) private var interval = 6
    @AppStorage(Prefs.lowDiskEnabled) private var lowDisk = true
    @AppStorage(Prefs.lowDiskThresholdGB) private var threshold = 10
    @AppStorage(Prefs.notifyAfterClean) private var notify = true
    @AppStorage(AutoSettings.skipRunningApps) private var skipRunning = true
    @AppStorage(AutoSettings.logAgeDays) private var logDays = 7
    @State private var ruleTick = 0

    // RAM
    @AppStorage(MemoryRelief.enabledKey) private var ramEnabled = false
    @AppStorage(MemoryRelief.triggerKey) private var ramTrigger = MemoryRelief.Trigger.pressureWarning.rawValue
    @AppStorage(MemoryRelief.swapPercentKey) private var ramSwap = 80
    @AppStorage(MemoryRelief.sustainKey) private var ramSustain = 2
    @AppStorage(MemoryRelief.idleKey) private var ramIdle = 20
    @AppStorage(MemoryRelief.cooldownKey) private var ramCooldown = 30
    @AppStorage(MemoryRelief.notifyKey) private var ramNotify = true
    @State private var ramApps: [String] = Prefs.list(MemoryRelief.appsKey)
    @State private var confirmRelief = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Otomasyon", subtitle: "Otomatik depolama ve RAM temizliğinin kuralları",
                       symbol: "wand.and.stars", color: .purple) {
                HStack(spacing: 6) {
                    Badge(text: autoClean ? "Depolama: açık" : "Depolama: kapalı", color: autoClean ? .green : .secondary)
                    Badge(text: ramEnabled ? "RAM: açık" : "RAM: kapalı", color: ramEnabled ? .green : .secondary)
                }
            }
            Form {
                storageSchedule
                storageRules
                storagePreview
                ramSection
                ramApplist
                ramStatus
            }
            .formStyle(.grouped)
        }
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

    // MARK: Depolama

    private var storageSchedule: some View {
        Section {
            Toggle("Önbellekleri düzenli olarak otomatik temizle", isOn: $autoClean)
            Picker("Sıklık", selection: $interval) {
                Text("Her saat").tag(1)
                Text("6 saatte bir").tag(6)
                Text("12 saatte bir").tag(12)
                Text("Günde bir").tag(24)
                Text("Haftada bir").tag(168)
            }
            .disabled(!autoClean)
            Toggle("Disk alanı azalınca hemen temizle", isOn: $lowDisk)
            Stepper("Eşik: \(threshold) GB boş alanın altı", value: $threshold, in: 2...100)
                .disabled(!lowDisk)
            Toggle("Temizlikten sonra bildirim göster", isOn: $notify)
            LabeledContent("Son otomatik temizlik") {
                Text(cleanup.lastAutoDate.map { "\(Fmt.relative($0)) · \(Fmt.bytes(cleanup.lastAutoBytes))" } ?? "Henüz yapılmadı")
            }
        } header: {
            Label("Depolama: ne zaman?", systemImage: "clock")
        }
    }

    private func ruleBinding(_ rule: AutoRule) -> Binding<Bool> {
        Binding(get: { _ = ruleTick; return AutoSettings.isEnabled(rule) },
                set: { UserDefaults.standard.set($0, forKey: rule.key); ruleTick += 1 })
    }

    private var storageRules: some View {
        Section {
            ForEach(AutoRule.allCases) { rule in
                Toggle(isOn: ruleBinding(rule)) {
                    HStack(spacing: 10) {
                        IconTile(symbol: rule.symbol, color: .purple, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(rule.title)
                                if let size = previewSize(rule) {
                                    Text(Fmt.bytes(size)).font(.caption.monospacedDigit()).foregroundStyle(.green)
                                }
                            }
                            Text(rule.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Stepper("Günlükler: \(logDays) günden eski olanlar silinsin", value: $logDays, in: 1...90)
            Toggle("Açık uygulamaların önbelleklerini atla", isOn: $skipRunning)
            Text("Kapalıyken açık uygulamaların (ör. Chrome) önbellekleri de silinir; uygulama gerekirse yeniden oluşturur ama bir süre yavaşlayabilir. Açık Xcode'un DerivedData'sı ve içinde dev server çalışan projelerin .next/.turbo klasörleri her durumda atlanır.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label("Depolama: neler temizlensin?", systemImage: "checklist")
        } footer: {
            Text("Hiçbir zaman otomatik silinmez: sistem dosyaları (/System, /Library, /private), Apple'ın kendi önbellekleri, uygulama verisi ve ayarları, tarayıcı geçmişi/çerezleri/şifreleri, node_modules, .venv, İndirilenler, büyük dosyalar, Çöp Kutusu ve \"Asla dokunma\" listen (\(Exclusions.all.count) öğe).")
                .font(.caption)
        }
    }

    private func previewSize(_ rule: AutoRule) -> Int64? {
        guard let items = cleanup.autoPreview else { return nil }
        let size = items.filter { $0.autoRule == rule }.reduce(Int64(0)) { $0 + $1.size }
        return size > 0 ? size : nil
    }

    private var storagePreview: some View {
        Section {
            HStack {
                Button {
                    Task { await cleanup.previewAuto() }
                } label: {
                    Label(cleanup.autoPreview == nil ? "Şimdi ne silinir? (önizleme)" : "Önizlemeyi yenile", systemImage: "eye")
                }
                .disabled(cleanup.isPreviewing)
                if cleanup.isPreviewing { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    Task {
                        await cleanup.quickClean()
                        await cleanup.previewAuto()
                    }
                } label: {
                    Label("Şimdi çalıştır", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(cleanup.isBusy)
            }
            if let items = cleanup.autoPreview {
                let total = items.reduce(Int64(0)) { $0 + $1.size }
                Text(items.isEmpty ? "Şu an otomatik temizlenecek bir şey yok."
                     : "Otomatik temizlik şu an \(items.count) öğeden \(Fmt.bytes(total)) silerdi:")
                    .font(.callout.weight(.semibold))
                ForEach(items.prefix(12)) { item in
                    HStack {
                        Image(systemName: item.autoRule?.symbol ?? "circle").foregroundStyle(.purple).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Asla dokunma: \(item.urls.first?.lastPathComponent ?? "")") {
                            item.urls.forEach { cleanup.exclude(path: $0.path) }
                            Task { await cleanup.previewAuto() }
                        }
                    }
                }
                if items.count > 12 {
                    Text("…ve \(items.count - 12) öğe daha").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Depolama: önizleme", systemImage: "eye")
        } footer: {
            Text("Önizleme hiçbir şey silmez. Bir öğeye sağ tıklayıp \"Asla dokunma\" diyerek otomatik temizlikten çıkarabilirsin.")
                .font(.caption)
        }
    }

    // MARK: RAM

    private var ramSection: some View {
        Section {
            Toggle("Bellek sıkışınca seçtiğim uygulamaları otomatik kapat", isOn: $ramEnabled)
            Picker("Ne zaman", selection: $ramTrigger) {
                ForEach(MemoryRelief.Trigger.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!ramEnabled)
            if ramTrigger == MemoryRelief.Trigger.swap.rawValue {
                Stepper("Swap eşiği: %\(ramSwap)", value: $ramSwap, in: 20...100, step: 5)
                    .disabled(!ramEnabled)
            }
            Stepper("Koşul en az \(ramSustain) dakika sürsün", value: $ramSustain, in: 0...30)
                .disabled(!ramEnabled)
            Stepper("Uygulama en az \(ramIdle) dakikadır arka planda olsun", value: $ramIdle, in: 0...480, step: 5)
                .disabled(!ramEnabled)
            Stepper("İki işlem arasında en az \(ramCooldown) dakika", value: $ramCooldown, in: 5...240, step: 5)
                .disabled(!ramEnabled)
            Toggle("Kapattıktan sonra bildirim göster", isOn: $ramNotify)
        } header: {
            Label("RAM: otomatik rahatlatma", systemImage: "memorychip")
        } footer: {
            Text("Neden \"RAM temizleyici\" değil? `purge` gibi komutlar yalnızca macOS'un zaten kendisi boşalttığı dosya önbelleğini siler, root ister ve sistemi geçici olarak yavaşlatır; Mole da swap/bellek müdahalesini \"sistem çökmesi riski\" diye kaldırmış. Gerçekten RAM açan tek güvenli yol kullanılmayan uygulamaları kapatmak. Bu kural bunu senin listen ve kuralların ile yapar; uygulamalar düzgünce kapatılır, kaydedilmemiş belge varsa soru sorarlar. Öndeki uygulama ve Korunan uygulamalar asla kapatılmaz.")
                .font(.caption)
        }
    }

    private var runningAppNames: [String] {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName))
            .subtracting(ramApps)
            .subtracting(Prefs.list(Prefs.protectedApps))
            .sorted()
    }

    private var ramApplist: some View {
        Section {
            if ramApps.isEmpty {
                Text("Liste boş. Örneğin Spotify, Telegram, Discord, Slack gibi arka planda RAM tutan ama hemen gerekmeyen uygulamaları ekle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ramApps, id: \.self) { name in
                HStack {
                    Image(systemName: "app.fill").foregroundStyle(.blue)
                    Text(name)
                    Spacer()
                    Button(role: .destructive) {
                        ramApps.removeAll { $0 == name }
                        Prefs.setList(MemoryRelief.appsKey, ramApps)
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            Menu("Açık bir uygulamayı ekle") {
                ForEach(runningAppNames, id: \.self) { name in
                    Button(name) {
                        ramApps.append(name)
                        Prefs.setList(MemoryRelief.appsKey, ramApps)
                    }
                }
            }
        } header: {
            Label("RAM: kapatılabilecek uygulamalar", systemImage: "list.bullet")
        }
    }

    private var ramStatus: some View {
        let m = monitor.memory
        let met = relief.conditionMet(m)
        let candidates = relief.candidates().compactMap(\.localizedName)
        return Section {
            LabeledContent("Koşul şu an") {
                if met, let since = relief.conditionSince {
                    Text("Sağlanıyor (\(Fmt.relative(since)) başladı)").foregroundStyle(.orange)
                } else {
                    Text(met ? "Sağlanıyor" : "Sağlanmıyor").foregroundStyle(met ? .orange : .green)
                }
            }
            LabeledContent("Şu an kapatılmaya uygun") {
                Text(candidates.isEmpty ? "Yok" : candidates.joined(separator: ", "))
            }
            HStack {
                Spacer()
                Button("Şimdi uygula…") { confirmRelief = true }
                    .disabled(ramApps.isEmpty)
            }
            ForEach(relief.history) { a in
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.apps.joined(separator: ", ")).lineLimit(2)
                        Text("\(Fmt.relative(a.date)) · ~\(Fmt.bytes(a.freed)) · \(a.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("RAM: durum ve geçmiş", systemImage: "waveform.path.ecg")
        }
    }
}
