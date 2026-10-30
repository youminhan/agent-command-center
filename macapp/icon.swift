// Renders the app icon: a dark terminal tile split into tmux panes with a
// green status bar. Usage: swift icon.swift <out.iconset>
import Cocoa

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    // Tile (Apple's icon grid: 824pt body inset 100pt).
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(starting: rgb(0x2B3240), ending: rgb(0x11141A))!.draw(in: tile, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    rgb(0xFFFFFF, 0.08).setStroke()
    tile.lineWidth = 4 * s
    tile.stroke()

    // Status bar.
    let barY: CGFloat = 170, barH: CGFloat = 92
    NSBezierPath(roundedRect: r(170, barY, 684, barH), xRadius: 22 * s, yRadius: 22 * s).fill(with: rgb(0x2EA043))
    for (i, w) in [70, 110, 90].enumerated() {
        let x = 200 + CGFloat(i) * 140
        NSBezierPath(roundedRect: r(x, barY + 32, CGFloat(w), 28), xRadius: 14 * s, yRadius: 14 * s)
            .fill(with: rgb(0x0D1117, i == 0 ? 0.85 : 0.45))
    }

    // Panes: one tall left, two stacked right.
    let top: CGFloat = 854, bottom = barY + barH + 28, gap: CGFloat = 28
    let leftW: CGFloat = 390, rightX = 170 + leftW + gap, rightW = 854 - rightX
    let midY = (top + bottom) / 2
    let panes = [r(170, bottom, leftW, top - bottom),
                 r(rightX, midY + gap / 2, rightW, top - midY - gap / 2),
                 r(rightX, bottom, rightW, midY - gap / 2 - bottom)]
    for (i, p) in panes.enumerated() {
        let path = NSBezierPath(roundedRect: p, xRadius: 26 * s, yRadius: 26 * s)
        path.fill(with: rgb(0x0D1117))
        (i == 0 ? rgb(0x3FB950) : rgb(0xFFFFFF, 0.12)).setStroke()
        path.lineWidth = (i == 0 ? 8 : 4) * s
        path.stroke()
    }

    // Prompt "❯ _" in the active pane, faint text lines in the others.
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 220 * s, y: 760 * s))
    prompt.line(to: NSPoint(x: 280 * s, y: 715 * s))
    prompt.line(to: NSPoint(x: 220 * s, y: 670 * s))
    prompt.lineWidth = 26 * s
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    rgb(0x3FB950).setStroke()
    prompt.stroke()
    NSBezierPath(roundedRect: r(310, 660, 90, 24), xRadius: 8 * s, yRadius: 8 * s).fill(with: rgb(0xE6EDF3))
    for p in [panes[2]] {
        for (j, frac) in [0.7, 0.5, 0.6].enumerated() {
            let y = p.maxY / s - 60 - CGFloat(j) * 50
            if y < p.minY / s + 30 { break }
            NSBezierPath(roundedRect: r(p.minX / s + 36, y, (p.width / s - 72) * CGFloat(frac), 20),
                         xRadius: 10 * s, yRadius: 10 * s).fill(with: rgb(0x8B949E, 0.45))
        }
    }

    // AI sparkle (four-point star) in the top-right pane.
    let c = NSPoint(x: panes[1].midX, y: panes[1].midY)
    func star(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let k = r * 0.22
        p.move(to: NSPoint(x: cx, y: cy + r))
        p.curve(to: NSPoint(x: cx + r, y: cy), controlPoint1: NSPoint(x: cx + k, y: cy + k), controlPoint2: NSPoint(x: cx + k, y: cy + k))
        p.curve(to: NSPoint(x: cx, y: cy - r), controlPoint1: NSPoint(x: cx + k, y: cy - k), controlPoint2: NSPoint(x: cx + k, y: cy - k))
        p.curve(to: NSPoint(x: cx - r, y: cy), controlPoint1: NSPoint(x: cx - k, y: cy - k), controlPoint2: NSPoint(x: cx - k, y: cy - k))
        p.curve(to: NSPoint(x: cx, y: cy + r), controlPoint1: NSPoint(x: cx - k, y: cy + k), controlPoint2: NSPoint(x: cx - k, y: cy + k))
        return p
    }
    NSGradient(starting: rgb(0xD2A8FF), ending: rgb(0x8957E5))!.draw(in: star(c.x, c.y, 82 * s), angle: -60)
    star(c.x + 70 * s, c.y + 58 * s, 26 * s).fill(with: rgb(0xD2A8FF, 0.9))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath {
    func fill(with c: NSColor) { c.setFill(); fill() }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
