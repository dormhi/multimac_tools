import Foundation
import Darwin
import SwiftUI

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: L("Yüksek", "High")
        case .critical: L("Kritik", "Critical")
        }
    }

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct MemorySnapshot {
    var date = Date()
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal

    /// Activity Monitor'deki "Kullanılan Bellek" ile aynı formül.
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
    var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
}

enum MemoryReader {
    private static let host = mach_host_self()
    private static let pageSize = UInt64(getpagesize())

    static func read() -> MemorySnapshot {
        var snap = MemorySnapshot()
        snap.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            snap.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            snap.wired = UInt64(stats.wire_count) * pageSize
            snap.compressed = UInt64(stats.compressor_page_count) * pageSize
            snap.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snap.swapTotal = swap.xsu_total
            snap.swapUsed = swap.xsu_used
        }

        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0) == 0 {
            snap.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        return snap
    }
}

struct DiskSnapshot {
    var total: Int64 = 0
    var available: Int64 = 0
    /// macOS'un gerekirse boşaltabileceği (purgeable) alan dahil.
    var importantAvailable: Int64 = 0

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum DiskReader {
    static func read() -> DiskSnapshot {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return DiskSnapshot() }
        return DiskSnapshot(
            total: Int64(v.volumeTotalCapacity ?? 0),
            available: Int64(v.volumeAvailableCapacity ?? 0),
            importantAvailable: v.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}

struct HistoryPoint: Identifiable {
    let date: Date
    let usedGB: Double
    let swapGB: Double
    var id: Date { date }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var memory = MemorySnapshot()
    @Published private(set) var disk = DiskSnapshot()
    @Published private(set) var history: [HistoryPoint] = []

    private var timer: Timer?

    func start() {
        tick()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshDisk() { disk = DiskReader.read() }

    private func tick() {
        let m = MemoryReader.read()
        memory = m
        disk = DiskReader.read()
        history.append(HistoryPoint(
            date: m.date,
            usedGB: Double(m.used) / 1_073_741_824,
            swapGB: Double(m.swapUsed) / 1_073_741_824))
        if history.count > 600 { history.removeFirst(history.count - 600) }
    }
}
