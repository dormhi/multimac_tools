import Foundation
import Darwin

/// fts(3) tabanlı hızlı dizin gezgini. FileManager.enumerator'dan belirgin şekilde hızlıdır.
enum FTSWalker {
    static let defaultFlags = FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR
    private static let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!

    /// body false dönerse gezinti durur.
    static func walk(_ path: String, flags: Int32 = defaultFlags,
                     _ body: (UnsafeMutablePointer<FTSENT>) -> Bool) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, flags, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            if !body(ent) { break }
        }
    }

    enum Action { case `continue`, skip, stop }

    /// Klasör atlamayı destekleyen gezinti: FTS_D anında .skip dönülürse içine girilmez.
    static func walkSkipping(_ path: String, flags: Int32 = defaultFlags,
                             _ body: (UnsafeMutablePointer<FTSENT>) -> Action) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, flags, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            switch body(ent) {
            case .continue: break
            case .skip: fts_set(fts, ent, FTS_SKIP)
            case .stop: return
            }
        }
    }

    static func name(_ ent: UnsafeMutablePointer<FTSENT>) -> String {
        let base = UnsafeRawPointer(ent) + nameOffset
        let buf = UnsafeRawBufferPointer(start: base, count: Int(ent.pointee.fts_namelen))
        return String(decoding: buf, as: UTF8.self)
    }

    /// Diskte gerçekten kapladığı alan (APFS sıkıştırma/seyrek dosyalar dahil).
    @inline(__always)
    static func allocated(_ ent: UnsafeMutablePointer<FTSENT>) -> Int64 {
        guard let st = ent.pointee.fts_statp else { return 0 }
        return Int64(st.pointee.st_blocks) * 512
    }
}

enum DirectorySizer {
    /// olderThanDays verilirse yalnızca o kadar günden eski dosyalar sayılır.
    static func allocatedSize(_ path: String, olderThanDays: Int?) -> Int64 {
        guard let days = olderThanDays else { return allocatedSize(path) }
        let cutoff = Int(Date().timeIntervalSince1970) - days * 86_400
        var total: Int64 = 0
        FTSWalker.walk(path) { ent in
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_F, let st = ent.pointee.fts_statp, Int(st.pointee.st_mtimespec.tv_sec) < cutoff {
                total += FTSWalker.allocated(ent)
            }
            return true
        }
        return total
    }

    /// Belirtilen günden eski dosyaları siler (klasörler kalır). Silinen bayt sayısını döner.
    static func deleteFiles(in path: String, olderThanDays days: Int, excluded: [String]) -> (freed: Int64, failed: Bool) {
        let cutoff = Int(Date().timeIntervalSince1970) - days * 86_400
        var targets: [(String, Int64)] = []
        FTSWalker.walk(path) { ent in
            let info = Int32(ent.pointee.fts_info)
            if (info == FTS_F || info == FTS_SL), let st = ent.pointee.fts_statp,
               Int(st.pointee.st_mtimespec.tv_sec) < cutoff {
                targets.append((String(cString: ent.pointee.fts_path), FTSWalker.allocated(ent)))
            }
            return true
        }
        var freed: Int64 = 0
        var failed = false
        for (p, size) in targets {
            if Exclusions.isExcluded(p, in: excluded) { continue }
            if unlink(p) == 0 { freed += size } else { failed = true }
        }
        return (freed, failed)
    }

    static func allocatedSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        var seen = Set<UInt64>()
        FTSWalker.walk(path) { ent in
            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_D:
                if info != FTS_D, let st = ent.pointee.fts_statp, st.pointee.st_nlink > 1 {
                    if !seen.insert(st.pointee.st_ino).inserted { return true }
                }
                total += FTSWalker.allocated(ent)
            default:
                break
            }
            return true
        }
        return total
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
