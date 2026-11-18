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
            PageHeader(title: L("Otomasyon", "Automation"), subtitle: L("MultiMac'in senin yerine yapabileceği iki iş", "Two jobs MultiMac can do for you"),
                       symbol: "wand.and.stars", color: .purple) {
                HStack(spacing: 6) {
                    Badge(text: storageOn ? L("Önbellek: açık", "Caches: on") : L("Önbellek: kapalı", "Caches: off"), color: storageOn ? .green : .secondary)
                    Badge(text: ramOn ? L("RAM: açık", "RAM: on") : L("RAM: kapalı", "RAM: off"), color: ramOn ? .green : .secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    storageCard
                    ramCard
                    Collapsible(title: L("Asla dokunulmayanlar", "Never touched"), symbol: "checkmark.shield.fill", color: .green,
                                hint: L("Otomasyonun hiçbir koşulda silmediği şeyler", "Things automation never deletes"), isOpen: $showSafety) { safetyContent }
                    Collapsible(title: L("Gelişmiş", "Advanced"), symbol: "slider.horizontal.3", color: .gray,
                                hint: L("Bildirimler, açık uygulamalar, günlük yaşı, bekleme süresi", "Notifications, running apps, log age, cooldown"), isOpen: $showAdvanced) { advancedContent }
                    Collapsible(title: L("Geçmiş", "History"), symbol: "clock.arrow.circlepath", color: .gray,
                                hint: historyHint, isOpen: $showHistory) { historyContent }
                }
                .padding(24)
            }
        }
        .task { if cleanup.autoPreview == nil { await cleanup.previewAuto() } }
        .alert(L("Listedeki uygulamalar şimdi kapatılsın mı?", "Quit the apps on the list now?"), isPresented: $confirmRelief) {
            Button(L("Kapat", "Quit"), role: .destructive) {
                Task { await relief.relieve(reason: L("Elle başlatıldı", "Started manually"), ignoreIdle: true) }
            }
            Button(L("Vazgeç", "Cancel"), role: .cancel) {}
        } message: {
            let names = relief.candidates(ignoreIdle: true).compactMap(\.localizedName)
            Text(names.isEmpty ? L("Listede şu an açık ve arka planda olan uygulama yok.", "No app on the list is open in the background right now.")
                 : L("\(names.joined(separator: ", ")) düzgünce kapatılacak. Kaydedilmemiş belge varsa uygulama soracak.", "\(names.joined(separator: ", ")) will be quit gracefully. Apps will ask about unsaved documents."))
        }
    }

    // MARK: - Önbellek kartı

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TaskHeader(title: L("Önbellekleri kendiliğinden temizle", "Clean caches automatically"),
                       subtitle: L("Uygulamaların gerektiğinde yeniden oluşturduğu çöpü siler. Belgelerine ve ayarlarına dokunmaz.", "Deletes junk that apps recreate when needed. Never touches your documents or settings."),
                       symbol: "sparkles", color: .green, isOn: $storageOn)

            VStack(alignment: .leading, spacing: 10) {
                QuestionRow(L("Ne zaman?", "When?")) {
                    PillPicker(selection: $interval, options: [
                        (1, L("Her saat", "Every hour")), (6, L("6 saatte bir", "Every 6 hours")), (12, L("12 saatte bir", "Every 12 hours")),
                        (24, L("Her gün", "Every day")), (168, L("Her hafta", "Every week")), (0, L("Zamanlama yok", "No schedule")),
                    ], custom: { L("\($0) saatte bir", "Every \($0) hours") })
                }
                QuestionRow(L("Disk dolarsa?", "If the disk fills up?")) {
                    PillPicker(selection: lowDiskBinding, options: [
                        (0, L("Bir şey yapma, zamanını bekle", "Do nothing, wait for the schedule")),
                        (5, L("Boş alan 5 GB'ın altına inince hemen temizle", "Clean right away below 5 GB free")),
                        (10, L("Boş alan 10 GB'ın altına inince hemen temizle", "Clean right away below 10 GB free")),
                        (20, L("Boş alan 20 GB'ın altına inince hemen temizle", "Clean right away below 20 GB free")),
                        (30, L("Boş alan 30 GB'ın altına inince hemen temizle", "Clean right away below 30 GB free")),
                        (50, L("Boş alan 50 GB'ın altına inince hemen temizle", "Clean right away below 50 GB free")),
                    ], custom: { L("Boş alan \($0) GB'ın altına inince hemen temizle", "Clean right away below \($0) GB free") })
                }
                if interval == 0 && !lowDisk {
                    Label(L("Bu ayarlarla otomatik temizlik hiç çalışmaz. Bir zaman ya da disk eşiği seç.", "With these settings the cleanup never runs. Pick a schedule or a disk threshold."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.leading, questionWidth + 12)
                }
                QuestionRow(L("Neler temizlensin?", "What should be cleaned?"), alignTop: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowLayout(spacing: 6) {
                            ForEach(AutoRule.allCases) { rule in ruleChip(rule) }
                        }
                        Text(hoveredRule?.detail ?? L("Bir kutunun üzerine gel, neleri kapsadığını gör. Tıklayınca açılır ya da kapanır.", "Hover a chip to see what it covers. Click it to turn it on or off."))
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
                    Label(showPreview ? L("Listeyi gizle", "Hide list") : L("Ne silinir?", "What gets deleted?"), systemImage: showPreview ? "chevron.up" : "eye")
                }
                Button {
                    Task {
                        await cleanup.quickClean()
                        await cleanup.previewAuto()
                    }
                } label: {
                    Label(cleanup.isBusy ? L("Temizleniyor…", "Cleaning…") : L("Şimdi çalıştır", "Run now"), systemImage: "sparkles")
                }
                .buttonStyle(.glassProminent)
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
                    Text(bytes > 0 ? Fmt.bytes(bytes) : L("boş", "empty"))
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
        let now = cleanup.autoPreview == nil ? "" : L(" Şu an \(Fmt.bytes(total)) temizlenebilir.", " \(Fmt.bytes(total)) can be cleaned now.")
        let last = cleanup.lastAutoDate.map { L(" Son temizlik \(Fmt.relative($0)), \(Fmt.bytes(cleanup.lastAutoBytes)).", " Last cleaned \(Fmt.relative($0)), \(Fmt.bytes(cleanup.lastAutoBytes)).") } ?? ""
        guard storageOn else { return L("Kapalı. Yalnızca \"Şimdi çalıştır\"a basınca temizler.", "Off. Cleans only when you click \"Run now\".") + now }
        if let next = cleanup.nextAutoDate {
            let when = next.timeIntervalSinceNow < 15 * 60 ? L("birkaç dakika içinde", "in a few minutes") : Fmt.relative(next)
            return L("Sonraki temizlik \(when).", "Next cleanup \(when).") + last
        }
        return lowDisk ? L("Yalnızca boş alan \(threshold) GB'ın altına inince çalışır.", "Runs only when free space drops below \(threshold) GB.") + last
            : L("Çalışmıyor: zaman ya da disk eşiği seçilmedi.", "Not running: no schedule or disk threshold selected.")
    }

    private var previewList: some View {
        let items = enabledItems
        return VStack(alignment: .leading, spacing: 6) {
            Text(items.isEmpty ? L("Şu an temizlenecek bir şey yok.", "Nothing to clean right now.")
                 : L("Şimdi çalışsa \(items.count) öğeden \(Fmt.bytes(items.reduce(Int64(0)) { $0 + $1.size })) silinir:", "Running now would delete \(Fmt.bytes(items.reduce(Int64(0)) { $0 + $1.size })) from \(items.count) items:"))
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
                        Button(L("Asla dokunma: \(item.urls.first?.lastPathComponent ?? "")", "Never touch: \(item.urls.first?.lastPathComponent ?? "")")) {
                            item.urls.forEach { cleanup.exclude(path: $0.path) }
                            Task { await cleanup.previewAuto() }
                        }
                    }
                }
            }
            if items.count > 15 {
                Text(L("…ve \(items.count - 15) öğe daha", "…and \(items.count - 15) more")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("Önizleme hiçbir şey silmez. Bir satıra sağ tıklayıp \"Asla dokunma\" dersen otomasyon onu bir daha silmez.", "The preview deletes nothing. Right-click a row and choose \"Never touch\" and automation will never delete it again."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - RAM kartı

    private var ramCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TaskHeader(title: L("Bellek sıkışınca uygulama kapat", "Quit apps when memory is tight"),
                       subtitle: L("RAM'i gerçekten açmanın tek güvenli yolu. Yalnızca senin seçtiğin uygulamalar, düzgünce kapatılır.", "The only safe way to really free RAM. Only apps you choose, quit gracefully."),
                       symbol: "memorychip", color: .blue, isOn: $ramOn)

            VStack(alignment: .leading, spacing: 10) {
                QuestionRow(L("Ne zaman?", "When?")) {
                    HStack(spacing: 6) {
                        PillPicker(selection: triggerBinding, options: [
                            ("w", L("Bellek sıkışınca", "When memory is tight")), ("c", L("Bellek kritik olunca", "When memory is critical")),
                            ("s50", L("Swap %50 dolunca", "When swap is 50% full")), ("s70", L("Swap %70 dolunca", "When swap is 70% full")), ("s80", L("Swap %80 dolunca", "When swap is 80% full")),
                            ("s90", L("Swap %90 dolunca", "When swap is 90% full")),
                        ])
                        PillPicker(selection: $ramSustain, options: [
                            (0, L("hemen", "right away")), (1, L("1 dakika sürerse", "for 1 minute")), (2, L("2 dakika sürerse", "for 2 minutes")),
                            (5, L("5 dakika sürerse", "for 5 minutes")), (10, L("10 dakika sürerse", "for 10 minutes")),
                        ], custom: { L("\($0) dakika sürerse", "for \($0) minutes") })
                    }
                }
                QuestionRow(L("Hangi uygulamalar?", "Which apps?"), alignTop: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowLayout(spacing: 6) {
                            ForEach(ramApps, id: \.self) { name in appChip(name) }
                            addAppMenu
                        }
                        if ramApps.isEmpty {
                            Text(L("Liste boş, yani hiçbir uygulama kapatılmaz. Arka planda RAM tutan ama hemen gerekmeyenleri ekle: Spotify, Discord, WhatsApp, Slack…", "The list is empty, so no app will be quit. Add apps that hold RAM in the background but aren't needed right away: Spotify, Discord, WhatsApp, Slack…"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                QuestionRow(L("Hangileri kapansın?", "Which of them?")) {
                    PillPicker(selection: $ramIdle, options: [
                        (0, L("Arka plandaki hepsi", "All in the background")), (5, L("5 dakikadır kullanmadıklarım", "Unused for 5 minutes")),
                        (10, L("10 dakikadır kullanmadıklarım", "Unused for 10 minutes")), (20, L("20 dakikadır kullanmadıklarım", "Unused for 20 minutes")),
                        (30, L("30 dakikadır kullanmadıklarım", "Unused for 30 minutes")), (60, L("1 saattir kullanmadıklarım", "Unused for 1 hour")),
                        (120, L("2 saattir kullanmadıklarım", "Unused for 2 hours")),
                    ], custom: { L("\($0) dakikadır kullanmadıklarım", "Unused for \($0) minutes") })
                }
                Text(L("Öndeki uygulama ve korunan uygulamalar asla kapatılmaz. Kaydedilmemiş belge varsa uygulama sana sorar.", "The frontmost app and protected apps are never quit. Apps will ask you about unsaved documents."))
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
                    Label(L("Şimdi kapat…", "Quit now…"), systemImage: "xmark.circle")
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
            .accessibilityLabel(L("\(name) uygulamasını listeden çıkar", "Remove \(name) from the list"))
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
            if names.isEmpty { Text(L("Eklenecek açık uygulama yok", "No running apps to add")) }
            ForEach(names, id: \.self) { name in
                Button(name) {
                    ramApps.append(name)
                    Prefs.setList(MemoryRelief.appsKey, ramApps)
                }
            }
        } label: {
            Label(L("Uygulama ekle", "Add app"), systemImage: "plus")
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
        guard ramOn else { return L("Kapalı. Yalnızca \"Şimdi kapat\"a basınca listedekileri kapatır.", "Off. Quits the listed apps only when you click \"Quit now\".") }
        guard !ramApps.isEmpty else { return L("Açık ama liste boş, bu yüzden hiçbir şey kapatılmaz.", "On, but the list is empty, so nothing will be quit.") }
        guard relief.conditionMet(monitor.memory) else { return L("Bellek şu an rahat, kapatılacak bir şey yok.", "Memory is fine right now, nothing to quit.") }
        let names = relief.candidates().compactMap(\.localizedName)
        let since = relief.conditionSince.map { L(" (\(Fmt.relative($0)) başladı)", " (started \(Fmt.relative($0)))") } ?? ""
        return names.isEmpty
            ? L("Koşul sağlanıyor\(since) ama listeden kapatılmaya uygun uygulama yok.", "Condition met\(since), but no app on the list can be quit.")
            : L("Koşul sağlanıyor\(since). Sırada: \(names.joined(separator: ", ")).", "Condition met\(since). Next up: \(names.joined(separator: ", ")).")
    }

    // MARK: - Katlanan bölümler

    private var safetyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([
                ("internaldrive", L("Sistem dosyaları: /System, /Library, /private", "System files: /System, /Library, /private")),
                ("apple.logo", L("Apple'ın kendi önbellekleri", "Apple's own caches")),
                ("person.crop.circle", L("Uygulama verileri ve ayarları", "App data and settings")),
                ("lock.fill", L("Tarayıcı geçmişi, çerezler ve şifreler", "Browser history, cookies and passwords")),
                ("folder.fill", L("node_modules, .venv, İndirilenler, büyük dosyalar ve Çöp Kutusu", "node_modules, .venv, Downloads, large files and the Trash")),
                ("hammer.fill", L("Açık Xcode'un DerivedData'sı ve içinde dev server çalışan projelerin önbellekleri", "DerivedData of a running Xcode and caches of projects with a running dev server")),
            ], id: \.1) { symbol, text in
                Label(text, systemImage: symbol).font(.callout)
            }
            HStack {
                Label(L("\"Asla dokunma\" listende \(Exclusions.all.count) öğe var", "Your \"Never touch\" list has \(Exclusions.all.count) items"), systemImage: "hand.raised.fill")
                    .font(.callout)
                Spacer()
                Button(L("Listeyi düzenle", "Edit list")) { appState.tab = .settings }
            }
            .padding(.top, 4)
        }
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Önbellek temizliği", "Cache cleanup")).font(.subheadline.weight(.semibold))
            Toggle(L("Temizlikten sonra bildirim göster", "Notify after cleaning"), isOn: $notify)
            VStack(alignment: .leading, spacing: 2) {
                Toggle(L("Açık uygulamaların önbelleklerini atla", "Skip caches of running apps"), isOn: $skipRunning)
                Text(L("Kapatırsan açık uygulamaların (ör. Chrome) önbellekleri de silinir; uygulama bir süre yavaşlayabilir.", "If off, caches of running apps (e.g. Chrome) are deleted too; the app may be slower for a while."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper(L("Günlükler \(logDays) günden eskiyse silinsin", "Delete logs older than \(logDays) days"), value: $logDays, in: 1...90)
            Divider()
            Text(L("Bellek", "Memory")).font(.subheadline.weight(.semibold))
            Toggle(L("Uygulama kapattıktan sonra bildirim göster", "Notify after quitting apps"), isOn: $ramNotify)
            VStack(alignment: .leading, spacing: 2) {
                Stepper(L("İki kapatma arasında en az \(ramCooldown) dakika bekle", "Wait at least \(ramCooldown) minutes between runs"), value: $ramCooldown, in: 5...240, step: 5)
                Text(L("Bellek sıkışık kalmaya devam ederse uygulamaları art arda kapatmasın diye.", "So it doesn't keep quitting apps one after another while memory stays tight."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: logDays) { Task { await cleanup.previewAuto() } }
        .onChange(of: skipRunning) { Task { await cleanup.previewAuto() } }
    }

    private var historyHint: String {
        cleanup.lastAutoDate == nil && relief.history.isEmpty
            ? L("Henüz bir şey yapılmadı", "Nothing done yet") : L("Son temizlik ve kapatılan uygulamalar", "Last cleanup and quit apps")
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let date = cleanup.lastAutoDate {
                HStack(alignment: .top) {
                    Image(systemName: "sparkles").foregroundStyle(.green).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Önbellek temizliği: \(Fmt.bytes(cleanup.lastAutoBytes)) yer açıldı", "Cache cleanup: freed \(Fmt.bytes(cleanup.lastAutoBytes))"))
                        Text(Fmt.relative(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(relief.history) { a in
                HStack(alignment: .top) {
                    Image(systemName: "memorychip").foregroundStyle(.blue).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Kapatıldı: \(a.apps.joined(separator: ", "))", "Quit: \(a.apps.joined(separator: ", "))")).lineLimit(2)
                        Text("\(Fmt.relative(a.date)) · ~\(Fmt.bytes(a.freed)) · \(a.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if cleanup.lastAutoDate == nil && relief.history.isEmpty {
                Text(L("Otomasyon henüz bir şey yapmadı.", "Automation hasn't done anything yet.")).font(.callout).foregroundStyle(.secondary)
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
            Text(isOn ? L("Açık", "On") : L("Kapalı", "Off"))
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
