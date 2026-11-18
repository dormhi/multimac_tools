import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var appState: AppState
    @AppStorage(Prefs.staleDays) private var staleDays = 30
    @AppStorage(Prefs.menuBarStyle) private var menuBarStyle = 0
    @AppStorage(Prefs.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(Prefs.appLanguage) private var language = AppLanguage.system.rawValue
    @AppStorage(Prefs.notifyAfterClean) private var notify = true
    @AppStorage(Prefs.largeFileMinMB) private var largeMB = 500
    @AppStorage(Prefs.oldFileDays) private var oldDays = 180
    @AppStorage(Prefs.oldFileMinMB) private var oldMB = 50
    @AppStorage(Prefs.alertSwapEnabled) private var alertSwap = true
    @AppStorage(Prefs.alertSwapPercent) private var alertSwapPercent = 90
    @AppStorage(Prefs.alertPressureEnabled) private var alertPressure = true
    @AppStorage(Prefs.alertPressureOnWarning) private var alertPressureWarning = false
    @AppStorage(Prefs.alertAppEnabled) private var alertApp = true
    @AppStorage(Prefs.alertAppGB) private var alertAppGB = 3
    @AppStorage(Prefs.alertCooldownMinutes) private var cooldown = 60
    @AppStorage(Prefs.menuTopCount) private var topCount = 6
    @State private var exclusions: [String] = Exclusions.all
    @State private var protectedApps: [String] = Prefs.list(Prefs.protectedApps)
    @State private var roots: [String] = Prefs.roots
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var hasFDA = FullDiskAccess.isGranted

    var body: some View {
        Form {
            Section(L("Görünüm ve dil", "Appearance and language")) {
                Picker(L("Tema", "Theme"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { a in
                        Label(a.title, systemImage: a.symbol).tag(a.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { AppAppearance.apply() }
                Picker(L("Dil", "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { l in Text(l.title).tag(l.rawValue) }
                }
                Text(L("Sistem seçiliyken macOS dili Türkçeyse Türkçe, değilse İngilizce kullanılır.",
                       "With System selected, MultiMac uses Turkish if macOS is in Turkish and English otherwise."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Otomatik temizlik", "Automatic cleanup")) {
                HStack {
                    Text(L("Otomatik depolama ve RAM temizliğinin tüm kuralları artık Otomasyon sekmesinde.", "All rules for automatic storage and RAM cleanup now live in the Automation tab."))
                    Spacer()
                    Button(L("Otomasyon'u Aç", "Open Automation")) { appState.tab = .automation }
                }
            }

            Section(L("Proje klasörleri", "Project folders")) {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        Text(Fmt.displayPath(root))
                        Spacer()
                        Button(role: .destructive) {
                            roots.removeAll { $0 == root }
                            Prefs.roots = roots
                        } label: { Label(L("Kaldır", "Remove"), systemImage: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button(L("Klasör Ekle…", "Add Folder…")) { addRoot() }
                Stepper(L("\(staleDays) gündür dokunulmayan projelerin node_modules'u önceden seçilsin", "Preselect node_modules of projects untouched for \(staleDays) days"),
                        value: $staleDays, in: 7...365, step: 7)
            }

            Section(L("Büyük ve eski dosyalar", "Large and old files")) {
                Stepper(L("Büyük dosya: \(largeMB) MB ve üzeri", "Large file: \(largeMB) MB or more"), value: $largeMB, in: 50...10_000, step: 50)
                Stepper(L("Eski dosya: \(oldDays) gündür açılmamış", "Old file: not opened for \(oldDays) days"), value: $oldDays, in: 30...1_095, step: 30)
                Stepper(L("…ve en az \(oldMB) MB olanlar", "…and at least \(oldMB) MB"), value: $oldMB, in: 1...1_000, step: 10)
                Text(L("Ev klasöründe aranır; ~/Library, gizli klasörler, node_modules ve uygulama/Fotoğraflar arşivleri atlanır. Bu dosyalar hiçbir kipte otomatik seçilmez.", "Searched in your home folder, skipping ~/Library, hidden folders, node_modules and app/Photos libraries. These files are never preselected by any preset."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Asla dokunulmayacaklar", "Never touch")) {
                if exclusions.isEmpty {
                    Text(L("Liste boş. Temizlik listesinde bir öğeye sağ tıklayıp \"Asla dokunma\" diyerek ekleyebilirsin.", "The list is empty. Right-click an item in the cleanup list and choose \"Never touch\" to add it."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(exclusions, id: \.self) { path in
                    HStack {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        Text(Fmt.displayPath(path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            Exclusions.remove(path)
                            exclusions = Exclusions.all
                        } label: { Label(L("Kaldır", "Remove"), systemImage: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button(L("Klasör veya Dosya Ekle…", "Add Folder or File…")) { addExclusion() }
            }

            Section(L("Bellek uyarıları", "Memory alerts")) {
                Toggle(L("Swap dolunca uyar", "Alert when swap fills up"), isOn: $alertSwap)
                Stepper(L("Swap eşiği: %\(alertSwapPercent)", "Swap threshold: \(alertSwapPercent)%"), value: $alertSwapPercent, in: 30...100, step: 5)
                    .disabled(!alertSwap)
                Toggle(L("Bellek baskısı kritik olunca uyar", "Alert when memory pressure is critical"), isOn: $alertPressure)
                Toggle(L("Baskı \"yüksek\" seviyesinde de uyar", "Also alert when pressure is \"high\""), isOn: $alertPressureWarning)
                    .disabled(!alertPressure)
                Toggle(L("Bir uygulama çok bellek kullanınca uyar", "Alert when an app uses a lot of memory"), isOn: $alertApp)
                Stepper(L("Uygulama sınırı: \(alertAppGB) GB", "App limit: \(alertAppGB) GB"), value: $alertAppGB, in: 1...16)
                    .disabled(!alertApp)
                Picker(L("Aynı uyarıyı tekrar etme süresi", "Don't repeat the same alert for"), selection: $cooldown) {
                    Text(L("15 dakika", "15 minutes")).tag(15)
                    Text(L("30 dakika", "30 minutes")).tag(30)
                    Text(L("1 saat", "1 hour")).tag(60)
                    Text(L("3 saat", "3 hours")).tag(180)
                    Text(L("Günde bir", "A day")).tag(1440)
                }
            }

            Section(L("Korunan uygulamalar", "Protected apps")) {
                if protectedApps.isEmpty {
                    Text(L("Korunan uygulamalar için kapatma butonu gösterilmez, öneri ve uyarılarda yer almaz. Bellek sekmesinde bir uygulamaya sağ tıklayarak da ekleyebilirsin.", "Protected apps get no quit button and never appear in suggestions or alerts. You can also add one by right-clicking it in the Memory tab."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(protectedApps, id: \.self) { name in
                    HStack {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        Button(role: .destructive) {
                            protectedApps.removeAll { $0 == name }
                            Prefs.setList(Prefs.protectedApps, protectedApps)
                        } label: { Label(L("Kaldır", "Remove"), systemImage: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Menu(L("Açık bir uygulamayı ekle", "Add a running app")) {
                    ForEach(runningAppNames, id: \.self) { name in
                        Button(name) {
                            protectedApps.append(name)
                            Prefs.setList(Prefs.protectedApps, protectedApps)
                        }
                    }
                }
            }

            Section(L("Genel", "General")) {
                Stepper(L("Menüde gösterilen uygulama sayısı: \(topCount)", "Apps shown in the menu: \(topCount)"), value: $topCount, in: 3...12)
                Toggle(L("Girişte başlat", "Open at login"), isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Picker(L("Menü çubuğu görünümü", "Menu bar style"), selection: $menuBarStyle) {
                    Text(L("Yalnızca simge", "Icon only")).tag(0)
                    Text(L("Simge + RAM %", "Icon + RAM %")).tag(1)
                    Text(L("Simge + RAM % + boş disk", "Icon + RAM % + free disk")).tag(2)
                }
                Text(L("Çentikli ekranlarda menü çubuğu dolunca geniş ikonlar çentiğin arkasında gizlenir. Görünmüyorsa \"Yalnızca simge\" seç veya ⌘ tuşuna basılı tutup diğer ikonları sürükleyerek yer aç.", "On displays with a notch, wide icons hide behind the notch when the menu bar is full. If you can't see it, choose \"Icon only\" or hold ⌘ and drag other icons to make room."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("İzinler", "Permissions")) {
                LabeledContent(L("Tam Disk Erişimi", "Full Disk Access")) {
                    HStack {
                        Badge(text: hasFDA ? L("Verildi", "Granted") : L("Verilmedi", "Not granted"), color: hasFDA ? .green : .orange)
                        Button(L("Sistem Ayarlarını Aç", "Open System Settings")) { FullDiskAccess.openSettings() }
                    }
                }
                Text(L("Depolama haritasının tüm diski okuyabilmesi için gerekir. Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi listesine MultiMac'i ekle, sonra uygulamayı yeniden başlat.", "Needed for the storage map to read the whole disk. Add MultiMac to System Settings › Privacy & Security › Full Disk Access, then restart the app."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasFDA = FullDiskAccess.isGranted
            exclusions = Exclusions.all
            protectedApps = Prefs.list(Prefs.protectedApps)
        }
    }

    private var runningAppNames: [String] {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName))
            .subtracting(protectedApps)
            .sorted()
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Hariç Tut", "Exclude")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { Exclusions.add($0.path) }
        exclusions = Exclusions.all
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Ekle", "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
        Prefs.roots = roots
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            loginError = nil
        } catch {
            loginError = L("Ayarlanamadı: \(error.localizedDescription). Uygulamayı /Applications içine kurmayı dene.", "Couldn't change this: \(error.localizedDescription). Try installing the app in /Applications.")
        }
    }
}
