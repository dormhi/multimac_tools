import Foundation
import SwiftUI

import AppKit

/// `MultiMac --snapshot <klasör>` : ana pencerenin her sekmesini PNG olarak kaydeder (görsel kontrol için).
enum Snapshot {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func run(to dir: String) async {
        let state = AppState.shared
        // Depolama haritası dolu görünsün: proje klasörünü (yoksa ev klasörünü) taramaya başla.
        state.storage.scan(path: Prefs.roots.first ?? NSHomeDirectory())
        Task { await state.processes.autoRefresh(every: 3) }
        Task { await state.servers.refresh() }
        try? await Task.sleep(nanoseconds: 45_000_000_000)  // taramalar bitsin
        if let root = state.storage.root {
            state.storage.selection = root.children.first { $0.kind == .directory }
        }
        for tab in MainTab.allCases {
            state.tab = tab
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
                  let view = window.contentView else { continue }
            save(view, to: "\(dir)/\(tab.rawValue).png")
        }
        renderMenuPanel(state, to: "\(dir)/menubar.png")
        exit(0)
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Menü çubuğu panelini ekran dışı bir pencerede çizip kaydeder.
    @MainActor
    private static func renderMenuPanel(_ state: AppState, to path: String) {
        let root = MenuBarPanel()
            .withStores(state)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        save(host, to: path)
        window.orderOut(nil)
    }
}

/// `MultiMac --selftest [klasör]` : hiçbir şey silmeden ölçümleri ve taramaları konsola yazar.
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    @MainActor
    static func run() async {
        let m = MemoryReader.read()
        print("== Bellek")
        print("  kullanılan \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))  app \(Fmt.bytes(m.app))  wired \(Fmt.bytes(m.wired))  sıkıştırılmış \(Fmt.bytes(m.compressed))  önbellek \(Fmt.bytes(m.cached))")
        print("  swap \(Fmt.bytes(m.swapUsed)) / \(Fmt.bytes(m.swapTotal))  baskı \(m.pressure.title)")

        let d = DiskReader.read()
        print("== Disk\n  boş \(Fmt.bytes(d.available)) / \(Fmt.bytes(d.total))  (purgeable dahil \(Fmt.bytes(d.importantAvailable)))")

        let t0 = Date()
        let groups = ProcessInspector.snapshot()
        print("== Süreçler (\(groups.count) grup, \(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        for g in groups.prefix(8) {
            let cwd = g.processes.first?.cwd.map { " cwd=\(Fmt.displayPath($0))" } ?? ""
            print("  \(Fmt.bytes(g.total).padding(toLength: 10, withPad: " ", startingAt: 0)) \(g.name) ×\(g.processes.count)\(g.isProtected ? " [korumalı]" : "")\(g.isDeveloperTool ? " [dev]" : "")\(cwd)")
        }

        let t1 = Date()
        let ctx = await CleanupContext.current()
        let items = await CleanupScanner.scan(context: ctx, autoOnly: false)
        print("== Temizlik taraması (\(items.count) öğe, \(String(format: "%.1f", Date().timeIntervalSince(t1))) sn)")
        for c in CleanupCategory.allCases {
            let list = items.filter { $0.category == c }
            guard !list.isEmpty else { continue }
            let total = list.reduce(Int64(0)) { $0 + $1.size }
            let auto = list.filter(\.autoEligible).reduce(Int64(0)) { $0 + $1.size }
            print("  [\(c.title)] toplam \(Fmt.bytes(total)) · otomatik \(Fmt.bytes(auto))")
            for i in list.prefix(6) {
                print("     \(Fmt.bytes(i.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(i.autoEligible ? "A" : "-")\(i.defaultSelected ? "S" : "-") \(i.title)\(i.note.map { "  (\($0))" } ?? "")")
            }
        }

        print("== Kipler")
        for p in [CleanupPreset.safe, .balanced, .aggressive] {
            let sel = items.filter(p.includes)
            print("  \(p.title.padding(toLength: 8, withPad: " ", startingAt: 0)) \(sel.count) öğe · \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))")
        }
        let autoItems = await CleanupScanner.scan(context: ctx, autoOnly: true)
        print("== Otomatik temizlik (silmeden önizleme): \(autoItems.count) öğe · \(Fmt.bytes(autoItems.reduce(0) { $0 + $1.size }))")
        for rule in AutoRule.allCases {
            let list = autoItems.filter { $0.autoRule == rule }
            guard !list.isEmpty else { continue }
            print("  [\(rule.title)] \(Fmt.bytes(list.reduce(0) { $0 + $1.size }))")
            for i in list.prefix(4) { print("     \(Fmt.bytes(i.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(i.title)\(i.minAgeDays.map { " (\($0)+ gün)" } ?? "")") }
        }
        let skipped = items.filter { $0.autoRule != nil && $0.inUse }
        print("  kullanımda olduğu için atlanan: \(skipped.map(\.title).joined(separator: ", "))")
        let store = CleanupStore()
        await store.scanAll()
        print("  store.summary: total=\(Fmt.bytes(store.summary.total)) presets=\(store.summary.presetSizes.map { "\($0.key.rawValue)=\(Fmt.bytes($0.value))" })")
        let projects = Set(items.compactMap(\.project))
        print("  proje sayısı: \(projects.count)")

        print("== Dev server'lar")
        for s in DevServerFinder.scan().prefix(10) {
            print("  \(s.name) pid=\(s.pid) portlar=\(s.ports) \(s.isApp ? "[uygulama]" : "") cwd=\(s.cwd.map(Fmt.displayPath) ?? "-") süre=\(s.uptime)")
        }

        let args = CommandLine.arguments
        let target = args.firstIndex(of: "--selftest").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? NSHomeDirectory()
        let t2 = Date()
        let root = DiskScanner.scan(path: target, token: CancelToken()) { _ in }
        print("== Disk haritası: \(Fmt.displayPath(target)) (\(String(format: "%.1f", Date().timeIntervalSince(t2))) sn)")
        if let root {
            var nodes = 0
            func count(_ n: FileNode) { nodes += 1; n.children.forEach(count) }
            count(root)
            print("  toplam \(Fmt.bytes(root.size)), \(root.fileCount) dosya, bellekte \(nodes) düğüm, okunamayan \(root.inaccessibleCount)")
            for c in root.children.prefix(10) {
                let s = c.safety
                print("     \(Fmt.bytes(c.size).padding(toLength: 10, withPad: " ", startingAt: 0)) [\(s.level.title)] \(c.name)")
            }
        }
        exit(0)
    }
}
