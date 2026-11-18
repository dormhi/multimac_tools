import AppKit

@MainActor
final class StorageStore: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case disk, home, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .disk: L("Tüm Disk", "Entire Disk", "Весь диск")
            case .home: L("Ev Klasörü", "Home Folder", "Домашняя папка")
            case .custom: L("Klasör…", "Folder…", "Папка…")
            }
        }
    }

    @Published var scope: Scope = .disk
    @Published var customURL: URL?
    @Published private(set) var root: FileNode?
    @Published var focus: FileNode?
    @Published var selection: FileNode?
    @Published private(set) var isScanning = false
    @Published private(set) var expanding = false
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var version = 0
    @Published var lastError: String?
    @Published private(set) var scannedAt: Date?

    private var token: CancelToken?

    var scanPath: String? {
        switch scope {
        case .disk:
            let data = SafetyClassifier.dataPrefix
            return FileManager.default.fileExists(atPath: data) ? data : "/"
        case .home: return NSHomeDirectory()
        case .custom: return customURL?.path
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Tara", "Scan", "Сканировать")
        if panel.runModal() == .OK, let url = panel.url {
            customURL = url
            scope = .custom
            startScan()
        }
    }

    func startScan() {
        guard let path = scanPath else { chooseFolder(); return }
        cancel()
        let token = CancelToken()
        self.token = token
        isScanning = true
        progress = ScanProgress()
        selection = nil
        focus = nil
        root = nil
        let isDisk = scope == .disk

        Task.detached(priority: .userInitiated) {
            let result = DiskScanner.scan(path: path, token: token) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.token === token else { return }
                    self.progress = p
                }
            }
            if let result, isDisk {
                // Taranan toplam ile birimin dolu alanı arasındaki fark: sistem birimi, snapshot'lar, swap vs.
                let used = DiskReader.read().used
                let hidden = used - result.size
                if hidden > 500_000_000 {
                    let pseudo = FileNode(name: L("Sistem ve gizli veriler", "System and hidden data", "Системные и скрытые данные"), kind: .unscanned, size: hidden)
                    pseudo.parent = result
                    result.children.append(pseudo)
                    result.children.sort { $0.size > $1.size }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.token === token else { return }
                self.isScanning = false
                self.root = result
                self.focus = result
                self.scannedAt = Date()
                self.version += 1
            }
        }
    }

    /// Belirli bir klasörü tarar (Genel Bakış'tan gelen istekler için).
    func scan(path: String) {
        if path == NSHomeDirectory() {
            scope = .home
        } else {
            customURL = URL(fileURLWithPath: path)
            scope = .custom
        }
        startScan()
    }

    func cancel() {
        token?.cancel()
        token = nil
        isScanning = false
    }

    func open(_ node: FileNode) {
        guard node.kind == .directory else { return }
        if node.isCollapsed {
            expand(node)
        } else if !node.children.isEmpty {
            focus = node
            selection = nil
        }
    }

    func goUp() {
        if let parent = focus?.parent {
            selection = focus
            focus = parent
        }
    }

    /// Bellekten atılmış küçük klasörü ayrıntılı olarak yeniden tarar.
    private func expand(_ node: FileNode) {
        guard !expanding else { return }
        expanding = true
        let path = node.path
        Task.detached(priority: .userInitiated) {
            let fresh = DiskScanner.scan(path: path, pruneBelow: 0, fileThreshold: 0,
                                         token: CancelToken()) { _ in }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.expanding = false
                guard let fresh else { return }
                node.children = fresh.children
                node.children.forEach { $0.parent = node }
                node.isCollapsed = false
                self.version += 1
                if !node.children.isEmpty {
                    self.focus = node
                    self.selection = nil
                }
            }
        }
    }

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func delete(_ node: FileNode, permanently: Bool) {
        guard node.isDeletable else { return }
        let url = URL(fileURLWithPath: node.path)
        do {
            if permanently {
                try FileManager.default.removeItem(at: url)
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            removeFromTree(node)
        } catch {
            lastError = L("\(node.displayName) silinemedi: \(error.localizedDescription)", "Couldn't delete \(node.displayName): \(error.localizedDescription)", "Не удалось удалить \(node.displayName): \(error.localizedDescription)")
        }
    }

    private func removeFromTree(_ node: FileNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var p: FileNode? = parent
        while let x = p {
            x.size -= node.size
            x.fileCount -= node.fileCount
            p = x.parent
        }
        if selection === node { selection = nil }
        if let f = focus, f.ancestors.contains(where: { $0 === node }) { focus = parent }
        version += 1
    }
}

enum FullDiskAccess {
    static var isGranted: Bool {
        let probes = [NSHomeDirectory() + "/Library/Safari", "/Library/Application Support/com.apple.TCC"]
        return probes.contains { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
