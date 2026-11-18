import Foundation
import Darwin

extension CleanupScanner {
    private static let largeSkipDirs: Set<String> = [
        "Library", "node_modules", "Pods", "DerivedData", "Applications", "venv", "site-packages",
    ]

    /// İçine girilmeyen paket klasörleri (Fotoğraflar arşivi, uygulamalar vb.)
    private static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "fcpbundle", "logicx",
        "imovielibrary", "xcarchive", "framework", "bundle", "plugin", "kext", "pkg", "band",
    ]

    /// Ev klasöründe çok büyük veya uzun süredir açılmamış dosyalar. Hiçbiri önceden seçilmez.
    static func largeFiles(_ ctx: CleanupContext) -> [CleanupItem] {
        let d = UserDefaults.standard
        let largeMin = Int64(max(10, d.integer(forKey: Prefs.largeFileMinMB))) * 1_000_000
        let oldMin = Int64(max(1, d.integer(forKey: Prefs.oldFileMinMB))) * 1_000_000
        let oldDays = Double(max(1, d.integer(forKey: Prefs.oldFileDays)))
        let now = Date().timeIntervalSince1970
        var items: [CleanupItem] = []

        FTSWalker.walkSkipping(ctx.home.path) { ent in
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_D {
                guard ent.pointee.fts_level > 0 else { return .continue }
                let name = FTSWalker.name(ent)
                if name.hasPrefix(".") || largeSkipDirs.contains(name)
                    || packageExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    return .skip
                }
                return .continue
            }
            guard info == FTS_F, let st = ent.pointee.fts_statp else { return .continue }
            let size = FTSWalker.allocated(ent)
            guard size >= min(oldMin, largeMin) else { return .continue }
            let last = Double(max(st.pointee.st_atimespec.tv_sec, st.pointee.st_mtimespec.tv_sec))
            let age = max(0, (now - last) / 86_400)
            let isLarge = size >= largeMin
            let isOld = age >= oldDays && size >= oldMin
            guard isLarge || isOld else { return .continue }
            let name = FTSWalker.name(ent)
            guard !name.hasPrefix(".") else { return .continue }

            let url = URL(fileURLWithPath: String(cString: ent.pointee.fts_path))
            let parent = Fmt.displayPath(url.deletingLastPathComponent().path)
            var reasons: [String] = []
            if isLarge { reasons.append(L("Büyük dosya", "Large file")) }
            if isOld { reasons.append(L("\(Int(age)) gündür açılmadı", "Not opened for \(Int(age)) days")) }
            items.append(CleanupItem(
                urls: [url], title: name, detail: L("\(parent) · son kullanım \(Int(age)) gün önce", "\(parent) · last used \(Int(age)) days ago"),
                category: .largeFiles, autoEligible: false, defaultSelected: false, contentsOnly: false,
                note: reasons.joined(separator: " · "), lastUsed: Date(timeIntervalSince1970: last)))
            return .continue
        }
        return items
    }
}
