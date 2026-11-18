import AppKit
import Darwin

/// TCP portu dinleyen bir süreç (ör. unutulmuş `npm run dev`).
struct ListeningServer: Identifiable {
    let pid: pid_t
    let name: String
    let ports: [Int]
    let cwd: String?
    let footprint: UInt64
    let started: Date?
    let bundlePath: String?
    let isSystem: Bool
    var id: pid_t { pid }

    /// Uygulama veya macOS sistem süreci: varsayılan olarak gizlenir
    var isApp: Bool { bundlePath != nil || isSystem }
    var isDeveloperTool: Bool { ProcessInspector.developerNames.contains(name) }

    var uptime: String {
        guard let started else { return "?" }
        let s = Int(Date().timeIntervalSince(started))
        if s < 3600 { return "\(s / 60) dk" }
        if s < 86_400 { return "\(s / 3600) sa \(s % 3600 / 60) dk" }
        return "\(s / 86_400) gün"
    }
}

enum DevServerFinder {
    /// lsof kullanmadan, proc_pidinfo ile dinleyen TCP soketlerini bulur.
    static func scan() -> [ListeningServer] {
        var result: [ListeningServer] = []
        for pid in ProcessInspector.allPIDs() {
            guard let fp = ProcessInspector.footprint(pid) else { continue }
            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { continue }
            let path = ProcessInspector.executablePath(pid) ?? ""
            let name = path.isEmpty ? ProcessInspector.processName(pid) : (path as NSString).lastPathComponent
            result.append(ListeningServer(
                pid: pid, name: name, ports: ports.sorted(), cwd: ProcessInspector.cwd(pid),
                footprint: fp, started: startDate(pid), bundlePath: ProcessInspector.outerAppBundle(path),
                isSystem: ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { path.hasPrefix($0) }))
        }
        return result.sorted { ($0.isApp ? 1 : 0, $0.ports.first ?? 0) < ($1.isApp ? 1 : 0, $1.ports.first ?? 0) }
    }

    private static func listeningPorts(_ pid: pid_t) -> Set<Int> {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufSize) / stride + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }

        var ports = Set<Int>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard Int(info.psi.soi_kind) == Int(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports
    }

    private static func startDate(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }
}

@MainActor
final class DevServerStore: ObservableObject {
    @Published private(set) var servers: [ListeningServer] = []
    @Published private(set) var loaded = false

    func refresh() async {
        servers = await Task.detached(priority: .utility) { DevServerFinder.scan() }.value
        loaded = true
    }

    func autoRefresh(every seconds: Double = 5) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    func stop(_ server: ListeningServer, force: Bool = false) {
        kill(server.pid, force ? SIGKILL : SIGTERM)
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refresh()
        }
    }

    func openInBrowser(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }
}
