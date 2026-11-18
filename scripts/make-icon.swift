// Uygulama ikonunu çizer: swiftc ile derlenip çalıştırılır, 1024x1024 PNG üretir.
// Kullanım: ./scripts/make-icon.sh
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS ikon ızgarası: 824pt kare, köşe yarıçapı ~185
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Gölge
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Arka plan gradyanı (indigo → mor → pembe)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [
    NSColor(calibratedRed: 0.27, green: 0.30, blue: 0.95, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.93, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.93, green: 0.35, blue: 0.62, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

// Üst parlaklık
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.25).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

// Halka gösterge (RAM/disk ölçer hissi)
let center = CGPoint(x: 512, y: 512)
ctx.setLineCap(.round)
ctx.setLineWidth(54)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
ctx.addArc(center: center, radius: 290, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.addArc(center: center, radius: 290, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.45, clockwise: true)
ctx.strokePath()
ctx.restoreGState()

// Ortada parıltı simgesi
let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
}

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
