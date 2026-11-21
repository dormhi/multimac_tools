import SwiftUI
import AppKit

/// Akıllı Temizlik: kullanım geçmişinden öğrenen küçük modelin önerileri.
struct SmartCleanupView: View {
    @EnvironmentObject private var smart: SmartStore
    @AppStorage(Prefs.deleteToTrash) private var toTrash = false
    @State private var confirm = false
    @State private var confirmReset = false
    @State private var showAllKeep = false

    private let tint = Color.smartAccent

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Akıllı Temizlik", "Smart Cleanup", "Умная очистка"), subtitle: subtitle) {
                HStack {
                    Button {
                        Task { await smart.analyze() }
                    } label: {
                        Label(L("Yeniden analiz et", "Analyze again", "Проанализировать снова"), systemImage: "sparkles")
                    }
                    .disabled(smart.isAnalyzing || smart.isCleaning)

                    Button {
                        confirm = true
                    } label: {
                        Label(L("Seçilenleri temizle (\(Fmt.bytes(smart.selectedSize)))", "Clean selected (\(Fmt.bytes(smart.selectedSize)))", "Очистить выбранное (\(Fmt.bytes(smart.selectedSize)))"),
                              systemImage: "wand.and.sparkles")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .disabled(smart.selectedItems.isEmpty || smart.isAnalyzing || smart.isCleaning)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ModelCard(tint: tint, confirmReset: $confirmReset)
                    if let r = smart.lastResult { resultBanner(r) }
                    if smart.items.isEmpty && smart.isAnalyzing {
                        analyzingPlaceholder
                    } else {
                        suggestionsCard
                        if !smart.regrowing.isEmpty { regrowCard }
                        if !smart.keep.isEmpty { keepCard }
                    }
                    footerNote
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .task { await smart.analyzeIfNeeded() }
        .alert(toTrash ? L("Seçilenler Çöp Kutusuna taşınsın mı?", "Move the selected items to the Trash?", "Переместить выбранное в Корзину?")
                       : L("Seçilenler kalıcı olarak silinsin mi?", "Permanently delete the selected items?", "Удалить выбранное навсегда?"),
               isPresented: $confirm) {
            Button(toTrash ? L("Çöpe Taşı", "Move to Trash", "Переместить в Корзину") : L("Kalıcı Olarak Sil", "Delete Permanently", "Удалить навсегда"), role: .destructive) {
                Task { await smart.cleanSelected() }
            }
            Button(L("Vazgeç", "Cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("\(smart.selectedItems.count) öneri, toplam \(Fmt.bytes(smart.selectedSize)). Model bu kararından öğrenir.",
                   "\(smart.selectedItems.count) suggestions, \(Fmt.bytes(smart.selectedSize)) in total. The model learns from this decision.",
                   "Предложений: \(smart.selectedItems.count), всего \(Fmt.bytes(smart.selectedSize)). Модель учится на этом решении."))
        }
        .alert(L("Öğrenilenler sıfırlansın mı?", "Reset what was learned?", "Сбросить обучение?"), isPresented: $confirmReset) {
            Button(L("Sıfırla", "Reset", "Сбросить"), role: .destructive) { Task { await smart.resetLearning() } }
            Button(L("Vazgeç", "Cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("Model başlangıç ayarlarına döner ve \"önerme\" dediğin öneriler geri gelir. Boyut geçmişi korunur.",
                   "The model returns to its starting settings and suggestions you hid come back. Size history is kept.",
                   "Модель вернётся к начальным настройкам, скрытые предложения появятся снова. История размеров сохранится."))
        }
    }

    private var subtitle: String {
        if smart.isCleaning { return L("Temizleniyor…", "Cleaning…", "Очистка…") }
        if smart.isAnalyzing { return L("Analiz ediliyor… \(Fmt.percent(smart.progress))", "Analyzing… \(Fmt.percent(smart.progress))", "Анализ… \(Fmt.percent(smart.progress))") }
        if smart.suggestions.isEmpty { return L("Mac'ini kullanma şekline göre öğrenir", "Learns from how you use your Mac", "Учится тому, как вы пользуетесь Mac") }
        return L("\(smart.suggestions.count) öneri · \(Fmt.bytes(smart.suggestedSize)) · kullanımına göre sıralandı",
                 "\(smart.suggestions.count) suggestions · \(Fmt.bytes(smart.suggestedSize)) · ranked by how you use your Mac",
                 "Предложений: \(smart.suggestions.count) · \(Fmt.bytes(smart.suggestedSize)) · по вашему использованию")
    }

    // MARK: Bölümler

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(symbol: "archivebox", color: tint,
                         title: L("Kullanılıp bırakılanlar", "Used, then left behind", "Использовано и брошено"),
                         subtitle: L("Model bunları şimdi temizlemenin işe yarayacağını düşünüyor", "The model thinks cleaning these now is worth it", "Модель считает, что их стоит очистить сейчас"))
            if smart.suggestions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal").foregroundStyle(tint)
                    Text(L("Şu an önerilecek bir şey yok. Model her taramada biraz daha öğrenir; ilk haftalarda öneri az olur.",
                           "Nothing to suggest right now. The model learns a bit more with every scan; expect few suggestions in the first weeks.",
                           "Сейчас предложить нечего. Модель учится с каждым сканированием; в первые недели предложений мало."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
            ForEach(smart.suggestions) { item in
                SuggestionRow(item: item, tint: tint, selected: smart.selected.contains(item.id),
                              toggle: { smart.toggle(item) }, dismiss: { withAnimation(.easeOut(duration: 0.2)) { smart.dismiss(item) } },
                              copy: { smart.copyCommand(item) })
                    .transition(.opacity)
            }
        }
        .card()
    }

    private var regrowCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(symbol: "arrow.triangle.2.circlepath", color: .orange,
                         title: L("Hızlı geri dolanlar · temizlemeye değmez", "Refills quickly · not worth cleaning", "Быстро заполняется · чистить не стоит"),
                         subtitle: L("Silmek yalnızca uygulamayı yavaşlatır, yer kısa sürede geri gider", "Deleting only slows the app down; the space is gone again soon", "Удаление лишь замедляет приложение; место скоро снова занято"))
            ForEach(smart.regrowing) { item in
                InfoRow(item: item, chip: nil, text: item.facts.first?.text ?? "")
            }
        }
        .card()
    }

    private var keepCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(symbol: "checkmark.shield", color: .blue,
                         title: L("Dokunulmayan ama önemli görünenler", "Untouched but looks important", "Не используется, но выглядит важным"),
                         subtitle: L("Eski olması gereksiz olduğu anlamına gelmez. Bunlar önerilmez", "Being old doesn't make it useless. These aren't suggested", "Старое не значит ненужное. Это не предлагается"))
            let list = showAllKeep ? smart.keep : Array(smart.keep.prefix(8))
            ForEach(list) { item in
                InfoRow(item: item, chip: keepChip(item), text: keepText(item))
            }
            if smart.keep.count > 8 {
                Button(showAllKeep ? L("Daha az göster", "Show less", "Показать меньше")
                                   : L("\(smart.keep.count - 8) tane daha göster", "Show \(smart.keep.count - 8) more", "Показать ещё \(smart.keep.count - 8)")) {
                    withAnimation(.easeOut(duration: 0.2)) { showAllKeep.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.leading, 6)
            }
        }
        .card()
    }

    private func keepChip(_ item: SmartItem) -> (String, Color) {
        switch item.keepReason {
        case .learned: return (L("Öğrenildi", "Learned", "Изучено"), tint)
        case .personal: return (L("Önerilmez", "Not suggested", "Не предлагается"), .blue)
        default: return (item.kind.title, .secondary)
        }
    }

    private func keepText(_ item: SmartItem) -> String {
        switch item.keepReason {
        case .personal:
            return L("Belge, fotoğraf veya kod içeriyor; yeniden oluşturulamaz", "Contains documents, photos or code; can't be recreated", "Содержит документы, фото или код; не восстановить")
        case .learned:
            return L("Bu türdeki önerileri hiç kabul etmedin", "You never accepted suggestions of this kind", "Вы ни разу не принимали такие предложения")
        default:
            return item.detail
        }
    }

    private var analyzingPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView(value: smart.progress).tint(tint).frame(maxWidth: 260)
            Text(L("Klasörler ölçülüyor ve geçmişle karşılaştırılıyor…", "Measuring folders and comparing with history…", "Измеряем папки и сравниваем с историей…"))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .card()
    }

    private func resultBanner(_ r: CleanupResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(r.trashed
                 ? L("\(Fmt.bytes(r.freed)) Çöp Kutusuna taşındı", "\(Fmt.bytes(r.freed)) moved to the Trash", "\(Fmt.bytes(r.freed)) перемещено в Корзину")
                 : L("\(Fmt.bytes(r.freed)) yer açıldı", "Freed \(Fmt.bytes(r.freed))", "Освобождено \(Fmt.bytes(r.freed))"))
            if !r.failedPaths.isEmpty {
                Text(L("· \(r.failedPaths.count) öğe silinemedi", "· \(r.failedPaths.count) items couldn't be deleted", "· не удалось удалить: \(r.failedPaths.count)"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .card(padding: 12)
    }

    private var footerNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
            Text(L("Hiçbir şey kendiliğinden silinmez. Öğrenilenler yalnızca bu Mac'te kalır.",
                   "Nothing is deleted on its own. What's learned stays on this Mac.",
                   "Ничего не удаляется само. Всё изученное остаётся на этом Mac."))
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Model kartı

private struct ModelCard: View {
    @EnvironmentObject private var smart: SmartStore
    let tint: Color
    @Binding var confirmReset: Bool

    /// 30 karar ve 30 günlük gözlemde "olgun" sayılır.
    private var maturity: Double {
        min(1, Double(smart.stats.decisions) / 30 * 0.6 + Double(min(smart.stats.observedPaths, 300)) / 300 * 0.4)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle().stroke(tint.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.04, smart.isAnalyzing ? smart.progress : maturity))
                    .stroke(AngularGradient(colors: [tint, .purple, .pink, tint], center: .center),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: smart.progress)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: smart.isAnalyzing)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(stateTitle).font(.headline)
                    Badge(text: L("Cihaz üstü model", "On-device model", "Модель на устройстве"), color: tint, symbol: "lock.fill")
                }
                Text(stateText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FlowChips(chips: [
                    L("\(smart.stats.observedPaths) klasör izleniyor", "\(smart.stats.observedPaths) folders watched", "Отслеживается папок: \(smart.stats.observedPaths)"),
                    L("\(smart.stats.decisions) karardan öğrendi", "Learned from \(smart.stats.decisions) decisions", "Обучено на решениях: \(smart.stats.decisions)"),
                    L("Model 1 KB · geçmiş \(Fmt.bytes(smart.stats.diskBytes))", "Model 1 KB · history \(Fmt.bytes(smart.stats.diskBytes))", "Модель 1 КБ · история \(Fmt.bytes(smart.stats.diskBytes))"),
                ] + (smart.stats.hidden > 0 ? [L("\(smart.stats.hidden) aday elendi", "\(smart.stats.hidden) candidates filtered out", "Отсеяно кандидатов: \(smart.stats.hidden)")] : []))
            }
            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 5) {
                Text(L("Neye dikkat ediyor", "What it pays attention to", "На что обращает внимание")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(smart.stats.topWeights.prefix(5)), id: \.0) { feature, weight in
                    WeightBar(title: feature.title, weight: weight, tint: tint)
                }
                Button(L("Öğrenileni sıfırla", "Reset learning", "Сбросить обучение")) { confirmReset = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.top, 2)
            }
            .frame(width: 250)
        }
        .card()
    }

    private var stateTitle: String {
        if smart.isAnalyzing { return L("Analiz ediliyor", "Analyzing", "Анализ") }
        if smart.stats.updates == 0 { return L("Başlangıç bilgisiyle çalışıyor", "Running on starting knowledge", "Работает на начальных знаниях") }
        return L("Öğreniyor", "Learning", "Обучается")
    }

    private var stateText: String {
        if smart.isAnalyzing {
            return L("Klasörlerin boyutu ve son kullanım tarihleri geçmişle karşılaştırılıyor.", "Comparing folder sizes and last-used dates with history.", "Сравниваем размеры папок и даты использования с историей.")
        }
        if smart.stats.updates == 0 {
            return L("Temizlediğin ve \"önerme\" dediğin her öneri modele senin alışkanlığını öğretir.", "Every suggestion you clean or hide teaches the model your habits.", "Каждое очищенное или скрытое предложение учит модель вашим привычкам.")
        }
        return L("\(smart.stats.updates) kez güncellendi. Temizledikten sonra geri dolanlardan ve geri gelmeyenlerden de öğrenir.",
                 "Updated \(smart.stats.updates) times. It also learns from what refills after cleaning and what never comes back.",
                 "Обновлялась \(smart.stats.updates) раз. Учится и на том, что снова заполняется, и на том, что не возвращается.")
    }
}

private struct WeightBar: View {
    let title: String
    let weight: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).lineLimit(1).frame(width: 140, alignment: .leading)
            GeometryReader { g in
                let w = min(1, abs(weight) / 3) * g.size.width
                Capsule().fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Capsule().fill(weight >= 0 ? tint : .orange).frame(width: max(3, w))
                    }
            }
            .frame(height: 5)
            Image(systemName: weight >= 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(weight >= 0 ? tint : .orange)
        }
        .help(weight >= 0 ? L("Öneri olasılığını artırır", "Makes a suggestion more likely", "Повышает вероятность предложения")
                          : L("Öneri olasılığını düşürür", "Makes a suggestion less likely", "Понижает вероятность предложения"))
    }
}

private struct FlowChips: View {
    let chips: [String]
    var body: some View {
        // Sığmayan çip alt satıra geçer (İngilizce ve Rusçada metinler uzun).
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { c in
                Text(c)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Surface.inset))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Satırlar

private struct SectionTitle: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 6)
    }
}

private struct SuggestionRow: View {
    let item: SmartItem
    let tint: Color
    let selected: Bool
    let toggle: () -> Void
    let dismiss: () -> Void
    let copy: () -> Void
    @State private var hovering = false
    @State private var copied = false

    private var isCommand: Bool {
        if case .command = item.action { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isCommand {
                Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 16).padding(.top, 2)
            } else {
                Checkbox(state: selected ? .on : .off, action: toggle).padding(.top, 1)
            }
            IconTile(symbol: item.kind.symbol, color: tint, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Badge(text: item.kind.title, color: .secondary)
                }
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                ConfidenceBar(score: item.score, tint: tint)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Fmt.bytes(item.size)).monospacedDigit().fontWeight(.medium)
                HStack(spacing: 4) {
                    if case .command(let cmd) = item.action {
                        Button {
                            copy()
                            copied = true
                        } label: {
                            Label(copied ? L("Kopyalandı", "Copied", "Скопировано") : L("Komutu kopyala", "Copy command", "Копировать команду"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .help(cmd)
                    }
                    Button(action: dismiss) {
                        Label(L("Önerme", "Don't suggest", "Не предлагать"), systemImage: "hand.thumbsdown")
                    }
                    .help(L("Bir daha önerilmez; model benzerlerinde daha temkinli olur", "Won't be suggested again; the model gets more careful with similar items", "Больше не будет предлагаться; модель станет осторожнее с похожими"))
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(item.urls)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(L("Finder'da göster", "Show in Finder", "Показать в Finder"))
                }
                .controlSize(.small)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if !isCommand { toggle() } }
        .onHover { hovering = $0 }
    }

    private var reason: String {
        var parts = item.facts.map(\.text)
        if parts.isEmpty { parts = [item.detail] }
        return parts.joined(separator: " · ")
    }
}

private struct ConfidenceBar: View {
    let score: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                Capsule().fill(tint.opacity(0.13))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: max(3, g.size.width * score))
                    }
            }
            .frame(width: 80, height: 4)
            Text(L("Güven \(Fmt.percent(score))", "Confidence \(Fmt.percent(score))", "Уверенность \(Fmt.percent(score))"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(tint)
        }
        .help(L("Modelin bu önerinin işine yarayacağından ne kadar emin olduğu", "How sure the model is that this suggestion is useful to you", "Насколько модель уверена, что это предложение полезно"))
    }
}

private struct InfoRow: View {
    let item: SmartItem
    let chip: (String, Color)?
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: item.kind.symbol, color: .secondary, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let chip { Badge(text: chip.0, color: chip.1) }
            Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(item.urls)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(L("Finder'da göster", "Show in Finder", "Показать в Finder"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }
}
