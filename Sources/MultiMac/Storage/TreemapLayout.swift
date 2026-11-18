import CoreGraphics

enum TreemapLayout {
    struct Tile {
        let node: FileNode
        let rect: CGRect
        let depth: Int
        let nested: Bool
    }

    static let headerHeight: CGFloat = 16

    static func tiles(for root: FileNode, in rect: CGRect, maxDepth: Int = 2) -> [Tile] {
        var out: [Tile] = []
        func recurse(_ node: FileNode, _ rect: CGRect, _ depth: Int, limit: Int) {
            let kids = node.children.prefix(limit).filter { $0.size > 0 }
            for (child, r) in squarify(Array(kids), in: rect) {
                guard r.width >= 1, r.height >= 1 else { continue }
                let canNest = depth < maxDepth && child.kind == .directory && !child.children.isEmpty
                    && r.width > 56 && r.height > 40
                out.append(Tile(node: child, rect: r, depth: depth, nested: canNest))
                if canNest {
                    let inner = CGRect(x: r.minX + 2, y: r.minY + headerHeight,
                                       width: r.width - 4, height: r.height - headerHeight - 2)
                    recurse(child, inner, depth + 1, limit: 80)
                }
            }
        }
        recurse(root, rect, 1, limit: 400)
        return out
    }

    /// Squarified treemap (Bruls, Huijsing, van Wijk).
    static func squarify(_ nodes: [FileNode], in rect: CGRect) -> [(FileNode, CGRect)] {
        let nodes = nodes.sorted { $0.size > $1.size }
        let total = Double(nodes.reduce(Int64(0)) { $0 + $1.size })
        guard total > 0, rect.width > 1, rect.height > 1 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        let areas = nodes.map { Double($0.size) * scale }

        var result: [(FileNode, CGRect)] = []
        result.reserveCapacity(nodes.count)
        var remaining = rect
        var start = 0
        while start < nodes.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0.5 else { break }
            var end = start + 1
            var rowSum = areas[start]
            var best = worst(sum: rowSum, min: areas[start], max: areas[start], side: side)
            while end < nodes.count {
                let newSum = rowSum + areas[end]
                let w = worst(sum: newSum, min: areas[end], max: areas[start], side: side)
                if w > best { break }
                best = w
                rowSum = newSum
                end += 1
            }
            if remaining.width >= remaining.height {
                let colW = CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for i in start..<end {
                    let h = CGFloat(areas[i]) / colW
                    result.append((nodes[i], CGRect(x: remaining.minX, y: y, width: colW, height: h)))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + colW, y: remaining.minY,
                                   width: max(0, remaining.width - colW), height: remaining.height)
            } else {
                let rowH = CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for i in start..<end {
                    let w = CGFloat(areas[i]) / rowH
                    result.append((nodes[i], CGRect(x: x, y: remaining.minY, width: w, height: rowH)))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + rowH,
                                   width: remaining.width, height: max(0, remaining.height - rowH))
            }
            start = end
        }
        return result
    }

    private static func worst(sum s: Double, min mn: Double, max mx: Double, side w: Double) -> Double {
        let s2 = s * s, w2 = w * w
        return Swift.max(w2 * mx / s2, s2 / (w2 * mn))
    }
}
