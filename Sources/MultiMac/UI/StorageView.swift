import SwiftUI
import AppKit

struct StorageView: View {
    @EnvironmentObject private var storage: StorageStore
    /// @State içinde sınıf: StorageView bu nesneyi izlemez, böylece fare her hareket ettiğinde
    /// bütün ekran (sağdaki 400 satırlık liste dahil) yeniden çizilmez; yalnızca treemap ve durum çubuğu.
    @State private var hover = HoverModel()
    @State private var pendingDelete: FileNode?
    @State private var hasFDA = FullDiskAccess.isGranted

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if storage.isScanning {
                scanning
            } else if let focus = storage.focus {
                if let root = storage.root, root.inaccessibleCount > 0, !hasFDA {
                    fdaBanner(count: root.inaccessibleCount)
                }
                breadcrumb(focus)
                HSplitView {
                    TreemapView(focus: focus, version: storage.version,
                                selection: $storage.selection, hover: hover,
                                onOpen: { storage.open($0) })
                        .frame(minWidth: 420, minHeight: 300)
                        .overlay(alignment: .center) {
                            if storage.expanding { ProgressView().controlSize(.large) }
                        }
                    StorageInspector(focus: focus, pendingDelete: $pendingDelete)
                        .frame(minWidth: 290, idealWidth: 330, maxWidth: 460)
                }
                StorageStatusBar(hover: hover)
            } else {
                empty
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { node in
            Button(L("Çöp Kutusuna Taşı", "Move to Trash")) { storage.delete(node, permanently: false) }
            Button(L("Kalıcı Olarak Sil", "Delete Permanently"), role: .destructive) { storage.delete(node, permanently: true) }
            Button(L("Vazgeç", "Cancel"), role: .cancel) {}
        } message: { node in
            Text(deleteMessage(node))
        }
        .alert(L("Silinemedi", "Couldn't Delete"), isPresented: Binding(get: { storage.lastError != nil },
                                                  set: { if !$0 { storage.lastError = nil } })) {
            Button(L("Tamam", "OK"), role: .cancel) {}
        } message: {
            Text(storage.lastError ?? "")
        }
        .onAppear { hasFDA = FullDiskAccess.isGranted }
    }

    // MARK: Parçalar

    private var toolbar: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "square.grid.3x3.square", color: .orange, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Depolama Haritası", "Storage Map")).font(.title2.bold())
                Text(storage.scannedAt.map { L("Taranma: \(Fmt.relative($0))", "Scanned \(Fmt.relative($0))") } ?? L("Neyin ne kadar yer kapladığını gör", "See what takes up how much space"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $storage.scope) {
                ForEach(StorageStore.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .onChange(of: storage.scope) { _, new in
                if new == .custom && storage.customURL == nil { storage.chooseFolder() }
            }
            if storage.scope == .custom {
                Button(L("Seç…", "Choose…")) { storage.chooseFolder() }
            }
            if storage.isScanning {
                Button(L("Durdur", "Stop"), role: .cancel) { storage.cancel() }
            } else {
                Button {
                    storage.startScan()
                } label: {
                    Label(storage.root == nil ? L("Taramayı Başlat", "Start Scan") : L("Yeniden Tara", "Rescan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L("\(storage.progress.files.formatted(.number.locale(Lang.locale))) dosya · \(Fmt.bytes(storage.progress.bytes))", "\(storage.progress.files.formatted(.number.locale(Lang.locale))) files · \(Fmt.bytes(storage.progress.bytes))"))
                .font(.title3.monospacedDigit())
            Text(Fmt.displayPath(storage.progress.current))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        let home = NSHomeDirectory()
        let quick: [(String, String, String, Color, String?)] = [
            (L("Tüm Disk", "Entire Disk"), L("Her şey; birkaç dakika sürebilir", "Everything; may take a few minutes"), "internaldrive.fill", .orange, nil),
            (L("Ev Klasörü", "Home Folder"), L("~ altındaki tüm dosyalar", "Everything under ~"), "house.fill", .blue, home),
            (L("Projeler", "Projects"), Prefs.roots.first.map(Fmt.displayPath) ?? L("Proje klasörü", "Project folder"), "hammer.fill", .purple, Prefs.roots.first),
            (L("İndirilenler", "Downloads"), "~/Downloads", "arrow.down.circle.fill", .green, home + "/Downloads"),
        ]
        return VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.square.fill").font(.system(size: 52)).foregroundStyle(.orange)
                Text(L("Neyin ne kadar yer kapladığını gör", "See what takes up how much space")).font(.title2.bold())
                Text(L("Her blok bir klasör veya dosya; büyüklüğü kapladığı alanla orantılı. Çift tıklayarak içine gir.", "Each block is a folder or file, sized by the space it takes. Double-click to go inside."))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                ForEach(quick, id: \.0) { q in
                    VStack(alignment: .leading, spacing: 8) {
                        IconTile(symbol: q.2, color: q.3, size: 34)
                        Text(q.0).font(.headline)
                        Text(q.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(width: 150, height: 110, alignment: .topLeading)
                    .card(padding: 14)
                    .hoverHighlight(cornerRadius: 14)
                    .onTapGesture {
                        if let path = q.4 { storage.scan(path: path) } else { storage.scope = .disk; storage.startScan() }
                    }
                }
            }
            HStack(spacing: 14) { legend }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var legend: some View {
        ForEach([SafetyLevel.junk, .normal, .caution, .protected], id: \.self) { level in
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(level.color).frame(width: 10, height: 10)
                Text(level.title).font(.caption)
            }
        }
    }

    private func fdaBanner(count: Int) -> some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text(L("\(count) klasör okunamadı. Tüm diski görmek için MultiMac'e Tam Disk Erişimi ver.", "\(count) folders couldn't be read. Give MultiMac Full Disk Access to see the whole disk."))
            Spacer()
            Button(L("Sistem Ayarlarını Aç", "Open System Settings")) { FullDiskAccess.openSettings() }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    private func breadcrumb(_ focus: FileNode) -> some View {
        HStack(spacing: 4) {
            Button { storage.goUp() } label: { Label(L("Yukarı", "Up"), systemImage: "chevron.up") }
                .disabled(focus.parent == nil)
                .help(L("Üst klasör", "Parent folder"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(focus.ancestors.enumerated()), id: \.element.id) { i, node in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(node.displayName) {
                            storage.focus = node
                            storage.selection = nil
                        }
                        .buttonStyle(.borderless)
                        .fontWeight(node === focus ? .semibold : .regular)
                    }
                }
            }
            Spacer()
            HStack(spacing: 10) { legend }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

}

final class HoverModel: ObservableObject {
    @Published var node: FileNode?
}

private struct StorageStatusBar: View {
    @ObservedObject var hover: HoverModel

    var body: some View {
        HStack {
            if let h = hover.node {
                Image(systemName: h.safety.level.symbol).foregroundStyle(h.safety.level.color)
                Text(Fmt.displayPath(h.path)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Fmt.bytes(h.size)).monospacedDigit()
            } else {
                Text(L("Tıkla: seç · Çift tıkla: klasöre gir", "Click: select · Double-click: open folder")).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

extension StorageView {

    private var deleteTitle: String {
        guard let n = pendingDelete else { return "" }
        switch n.safety.level {
        case .protected: return L("⚠️ Sistem öğesi: \(n.displayName)", "⚠️ System item: \(n.displayName)")
        case .caution: return L("Dikkat: \(n.displayName) silinsin mi?", "Careful: delete \(n.displayName)?")
        default: return L("\(n.displayName) silinsin mi?", "Delete \(n.displayName)?")
        }
    }

    private func deleteMessage(_ n: FileNode) -> String {
        var lines: [String] = []
        switch n.safety.level {
        case .protected:
            lines.append(L("BU BİR SİSTEM / KORUNAN ÖĞE. \(n.safety.reason).", "THIS IS A SYSTEM / PROTECTED ITEM. \(n.safety.reason)."))
            lines.append(L("Silmek macOS'u, uygulamaları veya kişisel verilerini bozabilir. Ne yaptığından emin değilsen vazgeç.", "Deleting it can break macOS, apps or your personal data. If you're not sure what you're doing, cancel."))
        case .caution:
            lines.append("\(n.safety.reason).")
        case .junk:
            lines.append("\(n.safety.reason).")
        case .normal:
            break
        }
        lines.append("\(Fmt.displayPath(n.path)) · \(Fmt.bytes(n.size))")
        lines.append(L("Not: Çöp Kutusuna taşımak yer açmaz, Çöp Kutusu boşaltılınca açılır.", "Note: moving to the Trash doesn't free space until the Trash is emptied."))
        return lines.joined(separator: "\n\n")
    }
}

struct StorageInspector: View {
    @EnvironmentObject private var storage: StorageStore
    let focus: FileNode
    @Binding var pendingDelete: FileNode?

    var body: some View {
        let node = storage.selection ?? focus
        VStack(alignment: .leading, spacing: 0) {
            detail(node)
                .padding(14)
            Divider()
            HStack {
                Text(L("İçindekiler", "Contents")).font(.headline)
                Spacer()
                Text(L("\(focus.children.count) öğe", "\(focus.children.count) items")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            List(focus.children) { child in
                ChildRow(node: child, parentSize: focus.size, selected: child === storage.selection)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { storage.open(child) }
                    .simultaneousGesture(TapGesture().onEnded { storage.selection = child })
                    .contextMenu {
                        if child.canOpen { Button(L("Aç", "Open")) { storage.open(child) } }
                        if child.isDeletable {
                            Button(L("Finder'da Göster", "Show in Finder")) { storage.reveal(child) }
                            Divider()
                            Button(L("Sil…", "Delete…"), role: .destructive) { pendingDelete = child }
                        }
                    }
            }
            .listStyle(.plain)
            .id(storage.version)
        }
    }

    private func detail(_ node: FileNode) -> some View {
        let safety = node.safety
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if node.kind == .file || node.kind == .directory {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: node.path)).resizable()
                    } else {
                        Image(systemName: node.kind == .unscanned ? "questionmark.folder" : "doc.on.doc")
                            .resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayName).font(.headline).lineLimit(2)
                    Text(Fmt.bytes(node.size)).font(.title2.bold()).monospacedDigit()
                }
            }
            if node.kind != .unscanned {
                Text(Fmt.displayPath(node.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                Badge(text: safety.level.title, color: safety.level.color, symbol: safety.level.symbol)
                if node.fileCount > 0 {
                    Text(L("\(node.fileCount.formatted(.number.locale(Lang.locale))) dosya", "\(node.fileCount.formatted(.number.locale(Lang.locale))) files")).font(.caption).foregroundStyle(.secondary)
                }
                if node.isInaccessible {
                    Badge(text: L("Okunamadı", "Unreadable"), color: .orange, symbol: "lock.fill")
                }
            }
            Text(safety.reason).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if node.canOpen && node !== focus {
                    Button { storage.open(node) } label: { Label(L("Aç", "Open"), systemImage: "arrow.down.right.and.arrow.up.left") }
                }
                if node.isDeletable {
                    Button { storage.reveal(node) } label: { Label("Finder", systemImage: "folder") }
                    Spacer()
                    Button(role: .destructive) { pendingDelete = node } label: {
                        Label(L("Sil…", "Delete…"), systemImage: "trash")
                    }
                    .tint(safety.level == .protected ? .red : nil)
                }
            }
            .controlSize(.small)
        }
    }
}

private struct ChildRow: View {
    let node: FileNode
    let parentSize: Int64
    let selected: Bool

    var body: some View {
        let fraction = parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(TreemapPalette.color(node, depth: 2))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if node.safety.level == .protected {
                        Image(systemName: "lock.shield.fill").foregroundStyle(.red).font(.caption2)
                    }
                    Spacer()
                    Text(Fmt.bytes(node.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(node.safety.level.color.opacity(0.7))
                                .frame(width: max(2, g.size.width * fraction))
                        }
                }
                .frame(height: 3)
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
