import SwiftUI
import AppKit

struct CleanupView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case categories, projects
        var id: String { rawValue }
        var title: String { self == .categories ? "Kategoriler" : "Projeler" }
    }

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var cleanup: CleanupStore
    @AppStorage(Prefs.deleteToTrash) private var toTrash = false
    @State private var mode: Mode = .categories
    @State private var filter = CleanupFilter()
    @State private var confirm = false
    @State private var expanded: Set<String> = []
    @State private var scrollTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Detaylı Temizlik", subtitle: subtitle, symbol: "sparkles", color: .green) {
                HStack {
                    Button {
                        Task { await cleanup.scanAll() }
                    } label: {
                        Label("Yeniden Tara", systemImage: "arrow.clockwise")
                    }
                    .disabled(cleanup.isBusy)

                    Button {
                        confirm = true
                    } label: {
                        Label("\(toTrash ? "Çöpe Taşı" : "Temizle") (\(Fmt.bytes(cleanup.selectedSize)))",
                              systemImage: toTrash ? "trash" : "trash.slash")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanup.selectedCount == 0 || cleanup.isBusy)
                }
            }
            summaryBar
            presetBar
            filterBar
            if let r = cleanup.lastResult { resultBanner(r) }
            Divider()

            if cleanup.items.isEmpty {
                placeholder
            } else if mode == .categories {
                categoryList
            } else {
                projectList
            }
        }
        .task {
            if cleanup.items.isEmpty && !cleanup.isScanning { await cleanup.scanAll() }
        }
        .onAppear(perform: handleRequest)
        .onChange(of: state.cleanupRequest) { _, _ in handleRequest() }
        .alert(toTrash ? "Seçilenler Çöp Kutusuna taşınsın mı?" : "Seçilenler kalıcı olarak silinsin mi?",
               isPresented: $confirm) {
            Button(toTrash ? "Çöpe Taşı" : "Kalıcı Olarak Sil", role: .destructive) {
                Task { await cleanup.cleanSelected() }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let base = "\(cleanup.selectedCount) öğe, toplam \(Fmt.bytes(cleanup.selectedSize))."
        if toTrash {
            return base + " Çöp Kutusu'ndan geri alınabilir, ancak Çöp Kutusu boşaltılana kadar yer açılmaz."
        }
        let risky = cleanup.selectedItems.filter { $0.category == .largeFiles || $0.category == .downloads || $0.category == .trash || $0.sensitive }
        var msg = base + " Önbellekler ve build kalıntıları gerektiğinde yeniden oluşturulur."
        if !risky.isEmpty {
            msg += "\n\n⚠️ Seçimde geri getirilemeyecek \(risky.count) kişisel dosya/veri var (\(Fmt.bytes(risky.reduce(0) { $0 + $1.size }))). Emin değilsen silme yöntemini \"Çöp Kutusuna taşı\" yap."
        }
        return msg
    }

    private var subtitle: String {
        if cleanup.isScanning { return "Taranıyor… (büyük dosya araması biraz sürebilir)" }
        if cleanup.isCleaning { return toTrash ? "Çöpe taşınıyor…" : "Temizleniyor…" }
        return "Bulunan: \(Fmt.bytes(cleanup.totalSize)) · Seçili: \(cleanup.selectedCount) öğe"
    }

    /// Genel Bakış'tan veya menüden gelen "şurayı aç" isteğini uygula.
    private func handleRequest() {
        guard let r = state.cleanupRequest else { return }
        state.cleanupRequest = nil
        if let p = r.preset { cleanup.apply(p) }
        mode = r.projects ? .projects : .categories
        filter = CleanupFilter(search: r.search ?? "", sort: filter.sort)
        if let c = r.category {
            expanded.insert(c.rawValue)
            scrollTarget = c.rawValue
        }
    }

    // MARK: Üst çubuklar

    /// Bulunan alanın kategorilere göre dağılımı; parçaya tıklayınca o kategori açılır.
    @ViewBuilder private var summaryBar: some View {
        let cats = CleanupCategory.allCases.compactMap { c in cleanup.summary.categoryTotals[c].map { (c, $0) } }
            .filter { $0.1 > 0 }
        if !cats.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                StackedBar(segments: cats.map { BarSegment(id: $0.0.rawValue, title: "\($0.0.title) · \(Fmt.bytes($0.1))", value: Double($0.1), color: $0.0.color) },
                           total: Double(max(1, cleanup.totalSize)), height: 10) { id in
                    mode = .categories
                    expanded.insert(id)
                    scrollTarget = id
                }
                HStack(spacing: 12) {
                    ForEach(cats, id: \.0) { c, size in
                        HStack(spacing: 4) {
                            Circle().fill(c.color).frame(width: 7, height: 7)
                            Text(c.title).foregroundStyle(.secondary)
                            Text(Fmt.percent(Double(size) / Double(max(1, cleanup.totalSize)))).fontWeight(.semibold)
                        }
                        .font(.caption2)
                        .onTapGesture {
                            mode = .categories
                            expanded.insert(c.rawValue)
                            scrollTarget = c.rawValue
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private var presetBar: some View {
        HStack(spacing: 10) {
            Text("Kip").foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { cleanup.preset }, set: { cleanup.apply($0) })) {
                ForEach(CleanupPreset.allCases.filter { $0 != .custom || cleanup.preset == .custom }) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: cleanup.preset == .custom ? 320 : 250)
            Text(cleanup.preset.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Picker("Silme", selection: $toTrash) {
                Text("Kalıcı sil").tag(false)
                Text("Çöp Kutusuna taşı").tag(true)
            }
            .frame(width: 210)
            .help("Çöp Kutusuna taşınanlar geri alınabilir ama yer açmaz")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .disabled(cleanup.isBusy)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            TextField("Ara (ad, yol, not)", text: $filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 220)

            Picker("Boyut", selection: $filter.minSize) {
                Text("Tüm boyutlar").tag(Int64(0))
                Text("> 10 MB").tag(Int64(10_000_000))
                Text("> 100 MB").tag(Int64(100_000_000))
                Text("> 500 MB").tag(Int64(500_000_000))
                Text("> 1 GB").tag(Int64(1_000_000_000))
            }
            .frame(width: 150)

            Picker("Yaş", selection: $filter.minAgeDays) {
                Text("Tüm tarihler").tag(0)
                Text("30+ gün").tag(30)
                Text("90+ gün").tag(90)
                Text("180+ gün").tag(180)
                Text("1+ yıl").tag(365)
            }
            .frame(width: 140)
            .help("Son kullanım tarihi bilinen öğeler arasında filtreler")

            Picker("Sırala", selection: $filter.sort) {
                ForEach(CleanupFilter.Sort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 160)

            Toggle("Seçililer", isOn: $filter.onlySelected).toggleStyle(.checkbox)
            if filter.isActive {
                Button("Sıfırla") { filter = CleanupFilter(sort: filter.sort) }.buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func resultBanner(_ r: CleanupResult) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            if r.trashed {
                Text("\(Fmt.bytes(r.freed)) Çöp Kutusuna taşındı · \(r.cleanedItems) öğe. Yer açmak için Çöp Kutusu'nu boşalt.")
            } else {
                Text("\(Fmt.bytes(r.freed)) yer açıldı · \(r.cleanedItems) öğe temizlendi")
            }
            if !r.failedPaths.isEmpty {
                Text("· \(r.failedPaths.count) öğe silinemedi (izin, kullanımda veya hariç tutulan içerik)")
                    .foregroundStyle(.orange)
                    .help(r.failedPaths.joined(separator: "\n"))
            }
            Spacer()
            Text(Fmt.relative(r.date)).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.green.opacity(0.08))
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            if cleanup.isScanning {
                ProgressView()
                Text("Önbellekler, build kalıntıları, indirilenler ve büyük dosyalar taranıyor…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Temizlenecek bir şey bulunamadı").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Listeler

    private var categoryList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(CleanupCategory.allCases) { category in
                    let items = cleanup.items(in: category, filter: filter)
                    if !items.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: binding(category.rawValue)) {
                                ForEach(items) { item in itemRows(item) }
                            } label: {
                                groupHeader(symbol: category.symbol, color: category.color, title: category.title,
                                            subtitle: category.subtitle, items: items)
                            }
                        }
                        .id(category.rawValue)
                    }
                }
                emptyFilterNote
            }
            .listStyle(.inset)
            .disabled(cleanup.isCleaning)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            .onAppear {
                if let target = scrollTarget {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
            }
        }
    }

    private var projectList: some View {
        let projects = cleanup.projects(filter: filter)
        return List {
            if projects.isEmpty {
                Text("Proje klasörlerinde build kalıntısı bulunamadı. Proje klasörlerini Ayarlar'dan ekleyebilirsin.")
                    .foregroundStyle(.secondary)
            }
            ForEach(projects) { project in
                DisclosureGroup(isExpanded: binding("project:" + project.path)) {
                    ForEach(project.items) { item in itemRows(item) }
                } label: {
                    let days = Fmt.days(since: project.lastUsed)
                    groupHeader(symbol: project.inUse ? "bolt.horizontal.circle.fill" : "folder.fill",
                                color: project.inUse ? .red : .orange,
                                title: project.name,
                                subtitle: "\(Fmt.displayPath(project.path))\(days.map { " · \($0) gündür dokunulmadı" } ?? "")\(project.inUse ? " · çalışan süreç var" : "")",
                                items: project.items)
                }
                .contextMenu {
                    Button("Finder'da Göster") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                    }
                    Button("Bu projeye asla dokunma") { cleanup.exclude(path: project.path) }
                }
            }
        }
        .listStyle(.inset)
        .disabled(cleanup.isCleaning)
    }

    @ViewBuilder private var emptyFilterNote: some View {
        if filter.isActive && CleanupCategory.allCases.allSatisfy({ cleanup.items(in: $0, filter: filter).isEmpty }) {
            Text("Filtreyle eşleşen öğe yok").foregroundStyle(.secondary)
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    private func groupHeader(symbol: String, color: Color, title: String, subtitle: String, items: [CleanupItem]) -> some View {
        let state = cleanup.checkState(items)
        let size = items.reduce(Int64(0)) { $0 + $1.size }
        let selectedSize = items.reduce(Int64(0)) { sum, item in
            switch cleanup.checkState(item) {
            case .on: return sum + item.size
            case .mixed: return sum + (cleanup.subItems[item.id] ?? []).filter { cleanup.selected.contains($0.id) }.reduce(0) { $0 + $1.size }
            case .off: return sum
            }
        }
        return HStack(spacing: 10) {
            Checkbox(state: state) { cleanup.set(items, selected: state != .on) }
            IconTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.bytes(size)).font(.headline).monospacedDigit()
                Text("\(items.count) öğe · \(Fmt.bytes(selectedSize)) seçili")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.07))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color.gradient)
                                .frame(width: size > 0 ? g.size.width * CGFloat(Double(selectedSize) / Double(size)) : 0)
                        }
                }
                .frame(width: 110, height: 4)
            }
        }
        .padding(.vertical, 4)
    }

    /// Öğe satırı ve açıldıysa alt öğeleri
    @ViewBuilder private func itemRows(_ item: CleanupItem) -> some View {
        let isOpen = expanded.contains("item:" + item.id)
        CleanupItemRow(
            item: item, state: cleanup.checkState(item),
            expandable: cleanup.canExpand(item), isOpen: isOpen,
            toggle: { cleanup.toggle(item) },
            toggleOpen: {
                if isOpen {
                    expanded.remove("item:" + item.id)
                } else {
                    expanded.insert("item:" + item.id)
                    Task { await cleanup.loadSubItems(item) }
                }
            },
            exclude: { cleanup.exclude(path: $0) })
        if isOpen {
            if cleanup.loadingSubs.contains(item.id) {
                HStack { ProgressView().controlSize(.small); Text("İçerik ölçülüyor…").font(.caption) }
                    .padding(.leading, 60)
            } else if let subs = cleanup.subItems[item.id] {
                if subs.isEmpty {
                    Text("Boş").font(.caption).foregroundStyle(.secondary).padding(.leading, 60)
                }
                ForEach(subs) { sub in
                    CleanupItemRow(item: sub, state: cleanup.checkState(sub) == .on || cleanup.selected.contains(item.id) ? .on : .off,
                                   expandable: false, isOpen: false,
                                   toggle: { cleanup.toggle(sub) }, toggleOpen: {},
                                   exclude: { cleanup.exclude(path: $0) })
                        .padding(.leading, 28)
                }
            }
        }
    }
}

private struct CleanupItemRow: View {
    let item: CleanupItem
    let state: Checkbox.State
    let expandable: Bool
    let isOpen: Bool
    let toggle: () -> Void
    let toggleOpen: () -> Void
    let exclude: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleOpen) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .opacity(expandable ? 1 : 0)
            .disabled(!expandable)
            .help("İçeriğini göster ve tek tek seç")

            Checkbox(state: state, action: toggle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    if item.autoEligible { Badge(text: "Otomatik", color: .green, symbol: "bolt.fill") }
                    if let note = item.note { Badge(text: note, color: item.inUse ? .red : .orange) }
                }
                if item.parentID == nil {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(Fmt.bytes(item.size)).monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(item.urls)
            } label: {
                Label("Göster", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Finder'da göster")
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting(item.urls) }
            if expandable { Button(isOpen ? "İçeriği gizle" : "İçeriğini göster", action: toggleOpen) }
            Divider()
            if item.urls.count == 1 {
                Button("Asla dokunma: \(item.urls[0].lastPathComponent)") { exclude(item.urls[0].path) }
            } else {
                Button("Asla dokunma: bu öğe") { item.urls.forEach { exclude($0.path) } }
            }
            if let project = item.project {
                Button("Asla dokunma: \((project as NSString).lastPathComponent) projesinin tamamı") { exclude(project) }
            }
        }
    }
}
