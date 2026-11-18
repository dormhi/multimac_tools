import AppKit
import Darwin

struct ProcessEntry: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    let path: String
    let footprint: UInt64
    var cwd: String?
    var id: pid_t { pid }
}

struct ProcessGroup: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    var processes: [ProcessEntry]
    let isProtected: Bool
    let isDeveloperTool: Bool
    /// Ana sürecin (en eski sürecin) başlama zamanı
    var started: Date?

    var total: UInt64 { processes.reduce(0) { $0 + $1.footprint } }
    var uptime: TimeInterval? { started.map { Date().timeIntervalSince($0) } }
    var isApp: Bool { bundlePath != nil }
}

enum ProcessInspector {
    static let protectedNames: Set<String> = [
        "Finder", "Dock", "WindowServer", "loginwindow", "SystemUIServer", "ControlCenter",
        "NotificationCenter", "Spotlight", "launchd", "MultiMac",
    ]

    static let developerNames: Set<String> = [
        "node", "python", "python3", "java", "ruby", "deno", "bun", "esbuild", "postgres",
        "mysqld", "redis-server", "mongod", "gopls", "rust-analyzer", "tsserver", "php",
        "dotnet", "gradle", "kotlin-daemon", "sourcekit-lsp", "clangd", "cargo", "go",
        "uvicorn", "gunicorn", "docker", "com.docker.backend", "qemu-system-aarch64",
    ]

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    /// Activity Monitor'deki "Bellek" sütunu (phys_footprint). Başka kullanıcıların süreçleri için nil.
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    static func cwd(_ pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        let path = withUnsafePointer(to: vpi.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty || path == "/" ? nil : path
    }

    static func outerAppBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func appName(forBundle bundle: String) -> String {
        let n = FileManager.default.displayName(atPath: bundle)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    /// Tüm (bu kullanıcıya ait) süreçleri uygulama bazında gruplar.
    static func snapshot() -> [ProcessGroup] {
        let userProtected = Set(Prefs.list(Prefs.protectedApps))
        var groups: [String: ProcessGroup] = [:]
        for pid in allPIDs() {
            guard let fp = footprint(pid) else { continue }
            let path = executablePath(pid) ?? ""
            let name = path.isEmpty ? processName(pid) : (path as NSString).lastPathComponent

            var bundle = outerAppBundle(path)
            // XPC servisleri (ör. WebKit sekmeleri) asıl sahibi olan uygulamaya yazılır.
            if bundle == nil, path.contains(".xpc/"), let fn = responsibleFn {
                let owner = fn(pid)
                if owner > 0, owner != pid, let ownerPath = executablePath(owner) {
                    bundle = outerAppBundle(ownerPath)
                }
            }

            var entry = ProcessEntry(pid: pid, name: name, path: path, footprint: fp)
            if bundle == nil { entry.cwd = cwd(pid) }

            let key = bundle ?? "proc:" + name
            if groups[key] == nil {
                let display = bundle.map(appName(forBundle:)) ?? name
                groups[key] = ProcessGroup(
                    id: key, name: display, bundlePath: bundle, processes: [],
                    isProtected: protectedNames.contains(display) || protectedNames.contains(name)
                        || userProtected.contains(display) || userProtected.contains(key)
                        || (bundle == nil && path.hasPrefix("/System/")) || bundle == Bundle.main.bundlePath,
                    isDeveloperTool: bundle == nil && developerNames.contains(name))
            }
            groups[key]!.processes.append(entry)
        }
        return groups.values
            .map { g in
                var g = g
                g.processes.sort { $0.footprint > $1.footprint }
                g.started = g.processes.compactMap { DevServerFinder.startDate($0.pid) }.min()
                return g
            }
            .sorted { $0.total > $1.total }
    }

    /// Belirli bir dizinin altında çalışan süreç var mı (ör. dev server)?
    static func busyDirectories() -> [String] {
        allPIDs().compactMap { pid in
            guard footprint(pid) != nil, outerAppBundle(executablePath(pid) ?? "") == nil else { return nil }
            return cwd(pid)
        }
    }

    static func terminate(_ group: ProcessGroup, force: Bool) {
        if let bundle = group.bundlePath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle }) {
            _ = force ? app.forceTerminate() : app.terminate()
            return
        }
        for p in group.processes { kill(p.pid, force ? SIGKILL : SIGTERM) }
    }

    static func terminate(pid: pid_t, force: Bool) {
        kill(pid, force ? SIGKILL : SIGTERM)
    }
}

@MainActor
final class ProcessStore: ObservableObject {
    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var lastUpdate: Date?
    private var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let result = await Task.detached(priority: .utility) { ProcessInspector.snapshot() }.value
        groups = result
        lastUpdate = Date()
        refreshing = false
    }

    /// Görünüm açık kaldığı sürece yeniler; görünüm kapanınca .task iptal edilir.
    func autoRefresh(every seconds: Double = 3) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    func quit(_ group: ProcessGroup, force: Bool = false) {
        ProcessInspector.terminate(group, force: force)
        scheduleRefresh()
    }

    @Published private(set) var restarting: Set<String> = []

    /// Uygulamayı düzgünce kapatıp arka planda yeniden açar: swap'te ve RAM'de tuttuğu her şey bırakılır.
    /// Kullanıcı kapanmayı iptal ederse (kaydedilmemiş belge) yeniden açma denenmez.
    func restart(_ group: ProcessGroup) {
        guard let bundle = group.bundlePath, !group.isProtected,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle })
        else { return }
        let url = URL(fileURLWithPath: bundle)
        restarting.insert(group.id)
        app.terminate()
        Task {
            for _ in 0..<60 where !app.isTerminated {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if app.isTerminated {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            restarting.remove(group.id)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refresh()
        }
    }

    func kill(_ pid: pid_t, force: Bool = false) {
        ProcessInspector.terminate(pid: pid, force: force)
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            await refresh()
        }
    }
}
