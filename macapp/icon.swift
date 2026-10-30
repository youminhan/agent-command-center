// Renders the app icon from the shared Logo geometry.
// Usage: icon <out.iconset> [preview.png]
import Cocoa

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    // macOS icon grid: the 824 pt body sits 100 pt in from each edge of a 1024 canvas.
    let unit = CGFloat(px) / 1024
    let s = 824 / 224 * unit
    let t = Logo.transform(scale: s, origin: NSPoint(x: 16, y: 16), at: NSPoint(x: 100 * unit, y: CGFloat(px) - 100 * unit))
    let tile = Logo.mapped(Logo.tile, t)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * unit
    shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
    shadow.set()
    rgb(0x101217).setFill()
    tile.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: rgb(0x2a2f3a), ending: rgb(0x101217))!.draw(in: tile, angle: -90)
    rgb(0xffffff, 0.08).setStroke()
    tile.lineWidth = 4 * unit
    tile.stroke()

    NSGradient(starting: rgb(0xfafafa), ending: rgb(0xe4e4e7))!.draw(in: Logo.mapped(Logo.leftPane, t), angle: -90)
    NSGradient(starting: rgb(0x4ade80), ending: rgb(0x16a34a))!.draw(in: Logo.mapped(Logo.sweep, t), angle: -45)
    NSGradient(starting: rgb(0xc4b5fd), ending: rgb(0x7c3aed))!.draw(in: Logo.mapped(Logo.spark, t), angle: -45)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

@main
struct IconTool {
    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
            try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        if CommandLine.arguments.count > 2 {
            try! render(256).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
