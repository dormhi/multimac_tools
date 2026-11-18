import SwiftUI

/// Diskin hangi ana klasörlere dağıldığını ölçer (Genel Bakış'taki "Disk nereye gidiyor?").
struct UsageSegment: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    var bytes: Int64
    /// Tıklanınca taranacak klasör; nil ise tüm disk
    let path: String?
}

@MainActor
final class OverviewStore: ObservableObject {
    @Published private(set) var segments: [UsageSegment] = []
    @Published private(set) var isMeasuring = false
    @Published private(set) var measuredAt: Date?
    @Published private(set) var progress: Double = 0

    private var stale = true

    func invalidate() { stale = true }

    func measureIfNeeded() async {
        guard stale, !isMeasuring else { return }
        await measure()
    }

    private struct Group {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let color: Color
        let path: String?
        var paths: [String]
    }

    /// Ölçüm sürerken yenisi başlarsa (ör. dil değişti) eskisinin sonuçları yeni listeye eklenmesin.
    private var generation = 0

    func measure() async {
        generation += 1
        let run = generation
        isMeasuring = true
        stale = false
        progress = 0
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let roots = Set(Prefs.roots)

        var groups: [String: Group] = [
            "apps": Group(id: "apps", title: L("Uygulamalar", "Applications", "Программы"), subtitle: "/Applications", symbol: "app.badge.fill",
                          color: .blue, path: "/Applications", paths: ["/Applications"]),
            "library": Group(id: "library", title: L("Kütüphane", "Library", "Библиотека"), subtitle: L("Uygulama verisi, önbellekler · ~/Library", "App data, caches · ~/Library", "Данные приложений, кэши · ~/Library"),
                             symbol: "books.vertical.fill", color: .purple, path: home + "/Library", paths: []),
            "projects": Group(id: "projects", title: L("Projeler", "Projects", "Проекты"), subtitle: L("Kod ve build kalıntıları", "Code and build leftovers", "Код и остатки сборок"),
                              symbol: "chevron.left.forwardslash.chevron.right", color: .orange, path: nil, paths: []),
            "downloads": Group(id: "downloads", title: L("İndirilenler", "Downloads", "Загрузки"), subtitle: "~/Downloads",
                               symbol: "arrow.down.circle.fill", color: .green, path: home + "/Downloads", paths: []),
            "documents": Group(id: "documents", title: L("Belgeler ve Masaüstü", "Documents and Desktop", "Документы и Рабочий стол"), subtitle: "~/Documents, ~/Desktop",
                               symbol: "doc.fill", color: .teal, path: home + "/Documents", paths: []),
            "media": Group(id: "media", title: L("Medya", "Media", "Медиа"), subtitle: L("Resimler, Filmler, Müzik", "Pictures, Movies, Music", "Изображения, Фильмы, Музыка"),
                           symbol: "photo.fill", color: .pink, path: home + "/Pictures", paths: []),
            "hidden": Group(id: "hidden", title: L("Geliştirici araçları", "Developer tools", "Инструменты разработчика"), subtitle: L("~/.npm, ~/.cache, ~/.cargo… gizli klasörler", "~/.npm, ~/.cache, ~/.cargo… hidden folders", "~/.npm, ~/.cache, ~/.cargo… скрытые папки"),
                            symbol: "wrench.and.screwdriver.fill", color: .indigo, path: home, paths: []),
            "otherHome": Group(id: "otherHome", title: L("Diğer ev dosyaları", "Other home files", "Другие файлы в домашней папке"), subtitle: L("Ev klasöründeki diğer her şey", "Everything else in your home folder", "Всё остальное в домашней папке"),
                               symbol: "house.fill", color: .mint, path: home, paths: []),
        ]

        for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where name != ".Trash" {
            let full = home + "/" + name
            let key: String
            switch name {
            case "Library": key = "library"
            case "Downloads": key = "downloads"
            case "Documents", "Desktop": key = "documents"
            case "Pictures", "Movies", "Music": key = "media"
            default:
                if roots.contains(full) { key = "projects" }
                else if name.hasPrefix(".") { key = "hidden" }
                else { key = "otherHome" }
            }
            groups[key]?.paths.append(full)
        }
        // Proje kökleri ev klasörünün doğrudan altında değilse (ör. ~/Documents/GitHub) zaten Belgeler içinde sayılır.
        if let first = groups["projects"]?.paths.first, groups["projects"]?.paths.count == 1 {
            groups["projects"] = Group(id: "projects", title: L("Projeler", "Projects", "Проекты"), subtitle: Fmt.displayPath(first),
                                       symbol: "chevron.left.forwardslash.chevron.right", color: .orange,
                                       path: first, paths: [first])
        }

        let order = ["apps", "library", "projects", "hidden", "downloads", "documents", "media", "otherHome"]
        segments = order.compactMap { id in
            groups[id].map { UsageSegment(id: $0.id, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol,
                                          color: $0.color, bytes: 0, path: $0.path) }
        }

        let jobs: [(String, String)] = order.flatMap { id in (groups[id]?.paths ?? []).map { (id, $0) } }
        var done = 0
        await withTaskGroup(of: (String, Int64).self) { group in
            var next = 0
            func add() {
                let job = jobs[next]
                next += 1
                group.addTask(priority: .utility) { (job.0, DirectorySizer.allocatedSize(job.1)) }
            }
            for _ in 0..<min(3, jobs.count) { add() }
            while let (id, size) = await group.next() {
                guard run == generation else { group.cancelAll(); return }
                if let i = segments.firstIndex(where: { $0.id == id }) { segments[i].bytes += size }
                done += 1
                progress = Double(done) / Double(max(1, jobs.count))
                if next < jobs.count { add() }
            }
        }

        guard run == generation else { return }
        let disk = DiskReader.read()
        let measured = segments.reduce(Int64(0)) { $0 + $1.bytes }
        segments.removeAll { $0.bytes < 50_000_000 }
        segments.sort { $0.bytes > $1.bytes }
        segments.append(UsageSegment(
            id: "system", title: L("macOS ve sistem verisi", "macOS and system data", "macOS и системные данные"),
            subtitle: L("Sistem birimi, swap, anlık görüntüler, diğer kullanıcılar", "System volume, swap, snapshots, other users", "Системный том, своп, снимки, другие пользователи"),
            symbol: "gearshape.2.fill", color: .gray, bytes: max(0, disk.used - measured), path: nil))
        measuredAt = Date()
        isMeasuring = false
    }
}
