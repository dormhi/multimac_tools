import Foundation
import Darwin

final class FileNode: Identifiable {
    enum Kind { case directory, file, smallFiles, unscanned }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    let name: String
    let kind: Kind
    var size: Int64
    var fileCount: Int = 0
    var children: [FileNode] = []
    weak var parent: FileNode?
    /// Bellek tasarrufu için alt öğeleri atılmış küçük klasör; açılınca yeniden taranır.
    var isCollapsed = false
    var isInaccessible = false
    var inaccessibleCount = 0

    // Tarama sırasında geçici alanlar
    fileprivate var level = 0
    fileprivate var smallBytes: Int64 = 0
    fileprivate var smallCount = 0

    init(name: String, kind: Kind, size: Int64 = 0) {
        self.name = name
        self.kind = kind
        self.size = size
    }

    var path: String {
        guard let parent else { return name }
        return (parent.path as NSString).appendingPathComponent(name)
    }

    var displayName: String {
        if parent == nil {
            let logical = SafetyClassifier.logicalPath(name)
            return logical == "/" ? "Macintosh HD" : (logical as NSString).lastPathComponent
        }
        return name
    }

    var isDeletable: Bool { (kind == .file || kind == .directory) && parent != nil }
    var canOpen: Bool { kind == .directory && (!children.isEmpty || isCollapsed) }

    private var cachedSafety: SafetyInfo?
    var safety: SafetyInfo {
        if let cachedSafety { return cachedSafety }
        let info: SafetyInfo
        switch kind {
        case .smallFiles: info = SafetyInfo(level: .normal, reason: "Bu klasördeki küçük dosyaların toplamı")
        case .unscanned: info = SafetyInfo(level: .protected, reason: "macOS sistem birimi, APFS anlık görüntüleri, swap ve okunamayan alanlar")
        default: info = SafetyClassifier.classify(path)
        }
        cachedSafety = info
        return info
    }

    var ancestors: [FileNode] {
        var chain: [FileNode] = []
        var n: FileNode? = self
        while let x = n { chain.insert(x, at: 0); n = x.parent }
        return chain
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct ScanProgress {
    var files = 0
    var bytes: Int64 = 0
    var current = ""
}

enum DiskScanner {
    /// - pruneBelow: bu boyuttan küçük klasörlerin alt ağacı bellekte tutulmaz (8 GB RAM dostu).
    /// - fileThreshold: bundan küçük dosyalar "küçük dosyalar" bloğunda toplanır.
    static func scan(path: String, pruneBelow: Int64 = 8_000_000, fileThreshold: Int64 = 2_000_000,
                     maxChildren: Int = 400, token: CancelToken,
                     progress: @escaping (ScanProgress) -> Void) -> FileNode? {
        var stack: [FileNode] = []
        var root: FileNode?
        var seen = Set<UInt64>()
        var prog = ScanProgress()
        var lastReport = Date()
        var tick = 0

        func finalize(_ node: FileNode) {
            if node.smallCount > 0 {
                let s = FileNode(name: "\(node.smallCount) küçük dosya", kind: .smallFiles, size: node.smallBytes)
                s.fileCount = node.smallCount
                s.parent = node
                node.children.append(s)
            }
            node.children.sort { $0.size > $1.size }
            if node.children.count > maxChildren {
                let rest = node.children[maxChildren...]
                let other = FileNode(name: "Diğer \(rest.count) öğe", kind: .smallFiles,
                                     size: rest.reduce(0) { $0 + $1.size })
                other.fileCount = rest.reduce(0) { $0 + $1.fileCount }
                other.parent = node
                node.children = Array(node.children[..<maxChildren]) + [other]
            }
            if !stack.isEmpty, node.size < pruneBelow, !node.children.isEmpty {
                node.children = []
                node.isCollapsed = true
            }
            node.smallBytes = 0
            node.smallCount = 0
        }

        func attach(_ node: FileNode) {
            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
                parent.size += node.size
                parent.fileCount += node.fileCount
                parent.inaccessibleCount += node.inaccessibleCount
            } else {
                root = node
            }
        }

        FTSWalker.walk(path) { ent in
            tick += 1
            if tick & 1023 == 0 {
                if token.isCancelled { return false }
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.15 {
                    lastReport = now
                    prog.current = String(cString: ent.pointee.fts_path)
                    progress(prog)
                }
            }
            let info = Int32(ent.pointee.fts_info)
            let level = Int(ent.pointee.fts_level)

            switch info {
            case FTS_D:
                let node = FileNode(name: level == 0 ? path : FTSWalker.name(ent), kind: .directory,
                                    size: FTSWalker.allocated(ent))
                node.level = level
                stack.append(node)

            case FTS_DP:
                guard let node = stack.popLast() else { break }
                finalize(node)
                attach(node)

            case FTS_DNR, FTS_ERR:
                if let top = stack.last, top.level == level {
                    stack.removeLast()
                    top.isInaccessible = true
                    top.inaccessibleCount += 1
                    finalize(top)
                    attach(top)
                } else {
                    stack.last?.inaccessibleCount += 1
                }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let st = ent.pointee.fts_statp, st.pointee.st_nlink > 1, info == FTS_F {
                    if !seen.insert(st.pointee.st_ino).inserted { break }
                }
                let size = FTSWalker.allocated(ent)
                prog.files += 1
                prog.bytes += size
                guard let parent = stack.last else {
                    let f = FileNode(name: path, kind: .file, size: size)
                    f.fileCount = 1
                    root = f
                    break
                }
                parent.size += size
                parent.fileCount += 1
                if size >= fileThreshold {
                    let f = FileNode(name: FTSWalker.name(ent), kind: .file, size: size)
                    f.fileCount = 1
                    f.parent = parent
                    parent.children.append(f)
                } else {
                    parent.smallBytes += size
                    parent.smallCount += 1
                }

            default:
                break
            }
            return true
        }

        if token.isCancelled { return nil }
        // fts erken bittiyse yığında kalanları kapat
        while let node = stack.popLast() {
            finalize(node)
            attach(node)
        }
        return root
    }
}
