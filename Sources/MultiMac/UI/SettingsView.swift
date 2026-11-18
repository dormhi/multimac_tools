import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var appState: AppState
    @AppStorage(Prefs.autoCleanEnabled) private var autoClean = true
    @AppStorage(Prefs.autoCleanIntervalHours) private var interval = 6
    @AppStorage(Prefs.lowDiskEnabled) private var lowDisk = true
    @AppStorage(Prefs.lowDiskThresholdGB) private var threshold = 10
    @AppStorage(Prefs.staleDays) private var staleDays = 30
    @AppStorage(Prefs.menuBarStyle) private var menuBarStyle = 0
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
            Section("Otomatik temizlik") {
                HStack {
                    Text("Otomatik depolama ve RAM temizliğinin tüm kuralları artık Otomasyon sekmesinde.")
                    Spacer()
                    Button("Otomasyon'u Aç") { appState.tab = .automation }
                }
            }

            Section("Proje klasörleri") {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        Text(Fmt.displayPath(root))
                        Spacer()
                        Button(role: .destructive) {
                            roots.removeAll { $0 == root }
                            Prefs.roots = roots
                        } label: { Label("Kaldır", systemImage: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Klasör Ekle…") { addRoot() }
                Stepper("\(staleDays) gündür dokunulmayan projelerin node_modules'u önceden seçilsin",
                        value: $staleDays, in: 7...365, step: 7)
            }

            Section("Büyük ve eski dosyalar") {
                Stepper("Büyük dosya: \(largeMB) MB ve üzeri", value: $largeMB, in: 50...10_000, step: 50)
                Stepper("Eski dosya: \(oldDays) gündür açılmamış", value: $oldDays, in: 30...1_095, step: 30)
                Stepper("…ve en az \(oldMB) MB olanlar", value: $oldMB, in: 1...1_000, step: 10)
                Text("Ev klasöründe aranır; ~/Library, gizli klasörler, node_modules ve uygulama/Fotoğraflar arşivleri atlanır. Bu dosyalar hiçbir kipte otomatik seçilmez.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Asla dokunulmayacaklar") {
                if exclusions.isEmpty {
                    Text("Liste boş. Temizlik listesinde bir öğeye sağ tıklayıp \"Asla dokunma\" diyerek ekleyebilirsin.")
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
                        } label: { Label("Kaldır", systemImage: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Klasör veya Dosya Ekle…") { addExclusion() }
            }

            Section("Bellek uyarıları") {
                Toggle("Swap dolunca uyar", isOn: $alertSwap)
                Stepper("Swap eşiği: %\(alertSwapPercent)", value: $alertSwapPercent, in: 30...100, step: 5)
                    .disabled(!alertSwap)
                Toggle("Bellek baskısı kritik olunca uyar", isOn: $alertPressure)
                Toggle("Baskı \"yüksek\" seviyesinde de uyar", isOn: $alertPressureWarning)
                    .disabled(!alertPressure)
                Toggle("Bir uygulama çok bellek kullanınca uyar", isOn: $alertApp)
                Stepper("Uygulama sınırı: \(alertAppGB) GB", value: $alertAppGB, in: 1...16)
                    .disabled(!alertApp)
                Picker("Aynı uyarıyı tekrar etme süresi", selection: $cooldown) {
                    Text("15 dakika").tag(15)
                    Text("30 dakika").tag(30)
                    Text("1 saat").tag(60)
                    Text("3 saat").tag(180)
                    Text("Günde bir").tag(1440)
                }
            }

            Section("Korunan uygulamalar") {
                if protectedApps.isEmpty {
                    Text("Korunan uygulamalar için kapatma butonu gösterilmez, öneri ve uyarılarda yer almaz. Bellek sekmesinde bir uygulamaya sağ tıklayarak da ekleyebilirsin.")
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
                        } label: { Label("Kaldır", systemImage: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Açık bir uygulamayı ekle") {
                    ForEach(runningAppNames, id: \.self) { name in
                        Button(name) {
                            protectedApps.append(name)
                            Prefs.setList(Prefs.protectedApps, protectedApps)
                        }
                    }
                }
            }

            Section("Genel") {
                Stepper("Menüde gösterilen uygulama sayısı: \(topCount)", value: $topCount, in: 3...12)
                Toggle("Girişte başlat", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Picker("Menü çubuğu görünümü", selection: $menuBarStyle) {
                    Text("Yalnızca simge").tag(0)
                    Text("Simge + RAM %").tag(1)
                    Text("Simge + RAM % + boş disk").tag(2)
                }
                Text("Çentikli ekranlarda menü çubuğu dolunca geniş ikonlar çentiğin arkasında gizlenir. Görünmüyorsa \"Yalnızca simge\" seç veya ⌘ tuşuna basılı tutup diğer ikonları sürükleyerek yer aç.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("İzinler") {
                LabeledContent("Tam Disk Erişimi") {
                    HStack {
                        Badge(text: hasFDA ? "Verildi" : "Verilmedi", color: hasFDA ? .green : .orange)
                        Button("Sistem Ayarlarını Aç") { FullDiskAccess.openSettings() }
                    }
                }
                Text("Depolama haritasının tüm diski okuyabilmesi için gerekir. Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi listesine MultiMac'i ekle, sonra uygulamayı yeniden başlat.")
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
        panel.prompt = "Hariç Tut"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { Exclusions.add($0.path) }
        exclusions = Exclusions.all
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ekle"
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
            loginError = "Ayarlanamadı: \(error.localizedDescription). Uygulamayı /Applications içine kurmayı dene."
        }
    }
}
