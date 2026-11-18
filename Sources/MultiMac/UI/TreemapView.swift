import SwiftUI

enum TreemapPalette {
    static func color(_ node: FileNode, depth: Int) -> Color {
        switch node.kind {
        case .smallFiles: return Color(white: depth == 1 ? 0.42 : 0.5)
        case .unscanned: return Color(hue: 0.0, saturation: 0.15, brightness: 0.3)
        default: break
        }
        let hue: Double, sat: Double
        switch node.safety.level {
        case .protected: hue = 0.0; sat = 0.62
        case .caution: hue = 0.08; sat = 0.68
        case .junk: hue = 0.37; sat = 0.55
        case .normal: hue = node.kind == .file ? 0.70 : 0.585; sat = 0.5
        }
        return Color(hue: hue, saturation: sat, brightness: depth == 1 ? 0.5 : 0.66)
    }
}

private final class TileCache {
    var key: (ObjectIdentifier, CGSize, Int)?
    var tiles: [TreemapLayout.Tile] = []

    func tiles(for focus: FileNode, size: CGSize, version: Int) -> [TreemapLayout.Tile] {
        if let k = key, k.0 == ObjectIdentifier(focus), k.1 == size, k.2 == version { return tiles }
        tiles = TreemapLayout.tiles(for: focus, in: CGRect(origin: .zero, size: size))
        key = (ObjectIdentifier(focus), size, version)
        return tiles
    }
}

struct TreemapView: View {
    let focus: FileNode
    let version: Int
    @Binding var selection: FileNode?
    @ObservedObject var hover: HoverModel
    private var hovered: FileNode? { hover.node }
    let onOpen: (FileNode) -> Void

    @State private var cache = TileCache()

    var body: some View {
        GeometryReader { geo in
            let tiles = cache.tiles(for: focus, size: geo.size, version: version)
            Canvas { ctx, _ in
                draw(tiles, in: &ctx)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    guard let t = hit(tiles, v.location) else { return }
                    if t.node.kind == .directory { onOpen(t.node) } else { selection = t.node }
                }
                .exclusively(before: SpatialTapGesture().onEnded { v in
                    selection = hit(tiles, v.location)?.node
                })
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let node = hit(tiles, p)?.node
                    if node !== hover.node { hover.node = node }
                case .ended:
                    hover.node = nil
                }
            }
        }
        .background(Color.black.opacity(0.85))
    }

    private func hit(_ tiles: [TreemapLayout.Tile], _ p: CGPoint) -> TreemapLayout.Tile? {
        tiles.last { $0.rect.contains(p) }
    }

    private func draw(_ tiles: [TreemapLayout.Tile], in ctx: inout GraphicsContext) {
        for tile in tiles {
            let r = tile.rect.insetBy(dx: 0.5, dy: 0.5)
            guard r.width > 0.5, r.height > 0.5 else { continue }
            var color = TreemapPalette.color(tile.node, depth: tile.depth)
            if tile.node === hovered { color = color.opacity(0.75) }
            let path = Path(r)
            ctx.fill(path, with: .color(color))
            if tile.node.kind == .unscanned {
                drawHatch(in: r, ctx: &ctx)
            }
            ctx.stroke(path, with: .color(.black.opacity(0.45)), lineWidth: tile.depth == 1 ? 1 : 0.5)

            guard r.width > 34, r.height > 13 else { continue }
            let name = tile.node.kind == .directory ? tile.node.name + "/" : tile.node.name
            let label: String
            if tile.nested || r.height < 28 {
                label = "\(name)  \(Fmt.bytes(tile.node.size))"
            } else {
                label = "\(name)\n\(Fmt.bytes(tile.node.size))"
            }
            let text = Text(label)
                .font(.system(size: tile.depth == 1 ? 11 : 10, weight: tile.depth == 1 ? .semibold : .regular))
                .foregroundColor(.white.opacity(0.95))
            let labelRect = CGRect(x: r.minX + 3, y: r.minY + 1, width: r.width - 6,
                                   height: tile.nested ? TreemapLayout.headerHeight - 1 : r.height - 2)
            ctx.drawLayer { layer in
                layer.clip(to: Path(labelRect))
                layer.draw(text, in: CGRect(x: labelRect.minX, y: labelRect.minY, width: max(labelRect.width, 400), height: labelRect.height))
            }
        }
        if let sel = selection, let t = tiles.last(where: { $0.node === sel }) {
            ctx.stroke(Path(t.rect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 2.5)
        }
    }

    private func drawHatch(in r: CGRect, ctx: inout GraphicsContext) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(r))
            var p = Path()
            var x = r.minX - r.height
            while x < r.maxX {
                p.move(to: CGPoint(x: x, y: r.maxY))
                p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                x += 10
            }
            layer.stroke(p, with: .color(.white.opacity(0.08)), lineWidth: 2)
        }
    }
}
