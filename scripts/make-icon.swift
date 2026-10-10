// Tạo AppIcon.iconset: swift scripts/make-icon.swift <thư-mục-iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.36, green: 0.27, blue: 0.95, alpha: 1))!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.45, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    let dot = rect.width * 0.24
    NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot * 1.1, y: rect.maxY - dot * 1.1, width: dot, height: dot)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: CGFloat(base * scale)).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
