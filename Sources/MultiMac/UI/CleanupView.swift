import SwiftUI
import AppKit

struct CleanupView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case categories, projects
        var id: String { rawValue }
        var title: String { self == .categories ? L("Kategoriler", "Categories", "Категории") : L("Projeler", "Projects", "Проекты") }
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
            PageHeader(title: L("Detaylı Temizlik", "Detailed Cleanup", "Подробная очистка"), subtitle: subtitle, symbol: "sparkles", color: .green) {
                HStack {
                    Button {
                        Task { await cleanup.scanAll() }
                    } label: {
                        Label(L("Yeniden Tara", "Rescan", "Сканировать снова"), systemImage: "arrow.clockwise")
                    }
                    .disabled(cleanup.isBusy)

                    Button {
                        confirm = true
                    } label: {
                        Label(L("\(toTrash ? "Çöpe Taşı" : "Temizle") (\(Fmt.bytes(cleanup.selectedSize)))", "\(toTrash ? "Move to Trash" : "Clean") (\(Fmt.bytes(cleanup.selectedSize)))", "\(toTrash ? "В Корзину" : "Очистить") (\(Fmt.bytes(cleanup.selectedSize)))"),
                              systemImage: toTrash ? "trash" : "trash.slash")
                    }
                    .buttonStyle(.glassProminent)
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
        .alert(toTrash ? L("Seçilenler Çöp Kutusuna taşınsın mı?", "Move the selected items to the Trash?", "Переместить выбранное в Корзину?") : L("Seçilenler kalıcı olarak silinsin mi?", "Permanently delete the selected items?", "Удалить выбранное навсегда?"),
               isPresented: $confirm) {
            Button(toTrash ? L("Çöpe Taşı", "Move to Trash", "Переместить в Корзину") : L("Kalıcı Olarak Sil", "Delete Permanently", "Удалить навсегда"), role: .destructive) {
                Task { await cleanup.cleanSelected() }
            }
            Button(L("Vazgeç", "Cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let base = L("\(cleanup.selectedCount) öğe, toplam \(Fmt.bytes(cleanup.selectedSize)).", "\(cleanup.selectedCount) items, \(Fmt.bytes(cleanup.selectedSize)) in total.", "Объектов: \(cleanup.selectedCount), всего \(Fmt.bytes(cleanup.selectedSize)).")
        if toTrash {
            return base + L(" Çöp Kutusu'ndan geri alınabilir, ancak Çöp Kutusu boşaltılana kadar yer açılmaz.", " They can be restored from the Trash, but no space is freed until the Trash is emptied.", " Их можно восстановить из Корзины, но место освободится только после её очистки.")
        }
        let risky = cleanup.selectedItems.filter { $0.category == .largeFiles || $0.category == .downloads || $0.category == .trash || $0.sensitive }
        var msg = base + L(" Önbellekler ve build kalıntıları gerektiğinde yeniden oluşturulur.", " Caches and build leftovers are recreated when needed.", " Кэши и остатки сборок создаются заново по необходимости.")
        if !risky.isEmpty {
            msg += L("\n\n⚠️ Seçimde geri getirilemeyecek \(risky.count) kişisel dosya/veri var (\(Fmt.bytes(risky.reduce(0) { $0 + $1.size }))). Emin değilsen silme yöntemini \"Çöp Kutusuna taşı\" yap.", "\n\n⚠️ The selection includes \(risky.count) personal files or data that can't be recovered (\(Fmt.bytes(risky.reduce(0) { $0 + $1.size }))). If you're not sure, set the delete method to \"Move to Trash\".", "\n\n⚠️ В выборе есть личные файлы или данные, которые нельзя восстановить (\(risky.count), \(Fmt.bytes(risky.reduce(0) { $0 + $1.size }))). Если не уверены, выберите способ удаления «Переместить в Корзину».")
        }
        return msg
    }

    private var subtitle: String {
        if cleanup.isScanning { return L("Taranıyor… (büyük dosya araması biraz sürebilir)", "Scanning… (the large file search may take a while)", "Сканирование… (поиск больших файлов может занять время)") }
        if cleanup.isCleaning { return toTrash ? L("Çöpe taşınıyor…", "Moving to Trash…", "Перемещение в Корзину…") : L("Temizleniyor…", "Cleaning…", "Очистка…") }
        return L("Bulunan: \(Fmt.bytes(cleanup.totalSize)) · Seçili: \(cleanup.selectedCount) öğe", "Found: \(Fmt.bytes(cleanup.totalSize)) · Selected: \(cleanup.selectedCount) items", "Найдено: \(Fmt.bytes(cleanup.totalSize)) · Выбрано объектов: \(cleanup.selectedCount)")
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
            Text(L("Kip", "Preset", "Режим")).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { cleanup.preset }, set: { cleanup.apply($0) })) {
                ForEach(CleanupPreset.allCases.filter { $0 != .custom || cleanup.preset == .custom }) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Sabit genişlik yok: uzun dillerde (Rusça) etiketler sığmayıp yanındaki metne biniyordu.
            .fixedSize()
            Text(cleanup.preset.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Picker(L("Silme", "Delete", "Удаление"), selection: $toTrash) {
                Text(L("Kalıcı sil", "Delete permanently", "Удалить навсегда")).tag(false)
                Text(L("Çöp Kutusuna taşı", "Move to Trash", "Переместить в Корзину")).tag(true)
            }
            .frame(width: 210)
            .help(L("Çöp Kutusuna taşınanlar geri alınabilir ama yer açmaz", "Items moved to the Trash can be restored but don't free space", "Перемещённое в Корзину можно восстановить, но место не освобождается"))
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

            TextField(L("Ara (ad, yol, not)", "Search (name, path, note)", "Поиск (имя, путь, заметка)"), text: $filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 220)

            Picker(L("Boyut", "Size", "Размер"), selection: $filter.minSize) {
                Text(L("Tüm boyutlar", "All sizes", "Любой размер")).tag(Int64(0))
                Text("> 10 MB").tag(Int64(10_000_000))
                Text("> 100 MB").tag(Int64(100_000_000))
                Text("> 500 MB").tag(Int64(500_000_000))
                Text("> 1 GB").tag(Int64(1_000_000_000))
            }
            .frame(width: 150)

            Picker(L("Yaş", "Age", "Возраст"), selection: $filter.minAgeDays) {
                Text(L("Tüm tarihler", "Any date", "Любая дата")).tag(0)
                Text(L("30+ gün", "30+ days", "30+ дней")).tag(30)
                Text(L("90+ gün", "90+ days", "90+ дней")).tag(90)
                Text(L("180+ gün", "180+ days", "180+ дней")).tag(180)
                Text(L("1+ yıl", "1+ year", "1+ год")).tag(365)
            }
            .frame(width: 140)
            .help(L("Son kullanım tarihi bilinen öğeler arasında filtreler", "Filters among items with a known last-used date", "Фильтрует объекты с известной датой последнего использования"))

            Picker(L("Sırala", "Sort", "Сортировка"), selection: $filter.sort) {
                ForEach(CleanupFilter.Sort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 160)

            Toggle(L("Seçililer", "Selected", "Выбранные"), isOn: $filter.onlySelected).toggleStyle(.checkbox)
            if filter.isActive {
                Button(L("Sıfırla", "Reset", "Сбросить")) { filter = CleanupFilter(sort: filter.sort) }.buttonStyle(.link)
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
                Text(L("\(Fmt.bytes(r.freed)) Çöp Kutusuna taşındı · \(r.cleanedItems) öğe. Yer açmak için Çöp Kutusu'nu boşalt.", "Moved \(Fmt.bytes(r.freed)) to the Trash · \(r.cleanedItems) items. Empty the Trash to free the space.", "В Корзину перемещено \(Fmt.bytes(r.freed)) · объектов: \(r.cleanedItems). Очистите Корзину, чтобы освободить место."))
            } else {
                Text(L("\(Fmt.bytes(r.freed)) yer açıldı · \(r.cleanedItems) öğe temizlendi", "Freed \(Fmt.bytes(r.freed)) · cleaned \(r.cleanedItems) items", "Освобождено \(Fmt.bytes(r.freed)) · очищено объектов: \(r.cleanedItems)"))
            }
            if !r.failedPaths.isEmpty {
                Text(L("· \(r.failedPaths.count) öğe silinemedi (izin, kullanımda veya hariç tutulan içerik)", "· \(r.failedPaths.count) items couldn't be deleted (permissions, in use or excluded content)", "· не удалось удалить объектов: \(r.failedPaths.count) (права доступа, используются или исключены)"))
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
                Text(L("Önbellekler, build kalıntıları, indirilenler ve büyük dosyalar taranıyor…", "Scanning caches, build leftovers, downloads and large files…", "Сканирование кэшей, остатков сборок, загрузок и больших файлов…")).foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                Text(L("Temizlenecek bir şey bulunamadı", "Nothing to clean", "Нечего очищать")).foregroundStyle(.secondary)
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
            .scrollContentBackground(.hidden)
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
                Text(L("Proje klasörlerinde build kalıntısı bulunamadı. Proje klasörlerini Ayarlar'dan ekleyebilirsin.", "No build leftovers in your project folders. You can add project folders in Settings.", "В папках проектов нет остатков сборок. Папки проектов можно добавить в Настройках."))
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
                                subtitle: L("\(Fmt.displayPath(project.path))\(days.map { " · \($0) gündür dokunulmadı" } ?? "")\(project.inUse ? " · çalışan süreç var" : "")", "\(Fmt.displayPath(project.path))\(days.map { " · untouched for \($0) days" } ?? "")\(project.inUse ? " · process running" : "")", "\(Fmt.displayPath(project.path))\(days.map { " · не трогали дней: \($0)" } ?? "")\(project.inUse ? " · запущен процесс" : "")"),
                                items: project.items)
                }
                .contextMenu {
                    Button(L("Finder'da Göster", "Show in Finder", "Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                    }
                    Button(L("Bu projeye asla dokunma", "Never touch this project", "Никогда не трогать этот проект")) { cleanup.exclude(path: project.path) }
                }
            }
        }
        .listStyle(.inset)
            .scrollContentBackground(.hidden)
        .disabled(cleanup.isCleaning)
    }

    @ViewBuilder private var emptyFilterNote: some View {
        if filter.isActive && CleanupCategory.allCases.allSatisfy({ cleanup.items(in: $0, filter: filter).isEmpty }) {
            Text(L("Filtreyle eşleşen öğe yok", "No items match the filter", "Нет объектов, подходящих под фильтр")).foregroundStyle(.secondary)
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
                Text(L("\(items.count) öğe · \(Fmt.bytes(selectedSize)) seçili", "\(items.count) items · \(Fmt.bytes(selectedSize)) selected", "Объектов: \(items.count) · выбрано \(Fmt.bytes(selectedSize))"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.07))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color)
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
                HStack { ProgressView().controlSize(.small); Text(L("İçerik ölçülüyor…", "Measuring contents…", "Измерение содержимого…")).font(.caption) }
                    .padding(.leading, 60)
            } else if let subs = cleanup.subItems[item.id] {
                if subs.isEmpty {
                    Text(L("Boş", "Empty", "Пусто")).font(.caption).foregroundStyle(.secondary).padding(.leading, 60)
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
            .help(L("İçeriğini göster ve tek tek seç", "Show contents and pick items one by one", "Показать содержимое и выбрать по одному"))

            Checkbox(state: state, action: toggle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    if item.autoEligible { Badge(text: L("Otomatik", "Auto", "Авто"), color: .green, symbol: "bolt.fill") }
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
                Label(L("Göster", "Show", "Показать"), systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(L("Finder'da göster", "Show in Finder", "Показать в Finder"))
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button(L("Finder'da Göster", "Show in Finder", "Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting(item.urls) }
            if expandable { Button(isOpen ? L("İçeriği gizle", "Hide contents", "Скрыть содержимое") : L("İçeriğini göster", "Show contents", "Показать содержимое"), action: toggleOpen) }
            Divider()
            if item.urls.count == 1 {
                Button(L("Asla dokunma: \(item.urls[0].lastPathComponent)", "Never touch: \(item.urls[0].lastPathComponent)", "Никогда не трогать: \(item.urls[0].lastPathComponent)")) { exclude(item.urls[0].path) }
            } else {
                Button(L("Asla dokunma: bu öğe", "Never touch: this item", "Никогда не трогать: этот объект")) { item.urls.forEach { exclude($0.path) } }
            }
            if let project = item.project {
                Button(L("Asla dokunma: \((project as NSString).lastPathComponent) projesinin tamamı", "Never touch: the whole \((project as NSString).lastPathComponent) project", "Никогда не трогать: весь проект \((project as NSString).lastPathComponent)")) { exclude(project) }
            }
        }
    }
}
