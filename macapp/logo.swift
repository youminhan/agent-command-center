// The Agent Command Center mark, drawn in code. Geometry matches assets/logo.svg:
// a 256×256 design space with y pointing down. Callers map it into their own rect.
import Cocoa

enum Logo {
    private static func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

    private static func quad(_ p: NSBezierPath, to: NSPoint, control c: NSPoint) {
        let a = p.currentPoint
        p.curve(to: to,
                controlPoint1: P(a.x + (c.x - a.x) * 2 / 3, a.y + (c.y - a.y) * 2 / 3),
                controlPoint2: P(to.x + (c.x - to.x) * 2 / 3, to.y + (c.y - to.y) * 2 / 3))
    }

    /// Circular arc from the current point to `to` around `center`, the short way round,
    /// as cubic segments of at most 90°.
    private static func arc(_ p: NSBezierPath, center c: NSPoint, to: NSPoint) {
        let from = p.currentPoint
        let r = hypot(from.x - c.x, from.y - c.y)
        var a0 = atan2(from.y - c.y, from.x - c.x)
        var delta = atan2(to.y - c.y, to.x - c.x) - a0
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let steps = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(steps)
        let k = 4 / 3 * tan(step / 4) * r
        for _ in 0..<steps {
            let a1 = a0 + step
            let p1 = P(c.x + r * cos(a0), c.y + r * sin(a0))
            let p2 = P(c.x + r * cos(a1), c.y + r * sin(a1))
            p.curve(to: p2,
                    controlPoint1: P(p1.x - k * sin(a0), p1.y + k * cos(a0)),
                    controlPoint2: P(p2.x + k * sin(a1), p2.y - k * cos(a1)))
            a0 = a1
        }
    }

    static var tile: NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 224, height: 224), xRadius: 56, yRadius: 56)
    }

    static var leftPane: NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 46, y: 46, width: 72, height: 164), xRadius: 14, yRadius: 14)
    }

    /// Quarter-circle "radar sweep" pane centred on (136,120), radius 74.
    static var sweep: NSBezierPath {
        let p = NSBezierPath()
        p.move(to: P(136, 52))
        quad(p, to: P(142, 46.24), control: P(136, 46))
        arc(p, center: P(136, 120), to: P(209.76, 114))
        quad(p, to: P(204, 120), control: P(210, 120))
        p.line(to: P(150, 120))
        arc(p, center: P(150, 106), to: P(136, 106))
        p.close()
        return p
    }

    /// Four-point spark: the agent pane.
    static var spark: NSBezierPath {
        let (cx, cy, r): (CGFloat, CGFloat, CGFloat) = (173, 174, 41)
        let w = r * 0.2
        let p = NSBezierPath()
        p.move(to: P(cx, cy - r))
        quad(p, to: P(cx + r, cy), control: P(cx + w, cy - w))
        quad(p, to: P(cx, cy + r), control: P(cx + w, cy + w))
        quad(p, to: P(cx - r, cy), control: P(cx - w, cy + w))
        quad(p, to: P(cx, cy - r), control: P(cx - w, cy - w))
        p.close()
        return p
    }

    /// Maps design space (x, y-down) so that design point `origin` lands on `at` in a y-up context, scaled by `s`.
    static func transform(scale s: CGFloat, origin: NSPoint = .zero, at: NSPoint) -> AffineTransform {
        var t = AffineTransform(translationByX: at.x, byY: at.y)
        t.scale(x: s, y: -s)
        t.translate(x: -origin.x, y: -origin.y)
        return t
    }

    static func mapped(_ path: NSBezierPath, _ t: AffineTransform) -> NSBezierPath {
        let c = path.copy() as! NSBezierPath
        c.transform(using: t)
        return c
    }

    /// Menu-bar template image: the three panes without the tile, so it sits lightly in the bar.
    static func menuBarImage(points: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            let inset: CGFloat = 1.5
            let s = (rect.width - inset * 2) / 164  // the panes span 46…210 in design space
            let t = transform(scale: s, origin: P(46, 46), at: P(inset, rect.height - inset))
            NSColor.black.setFill()
            for part in [leftPane, sweep, spark] { mapped(part, t).fill() }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Agent Command Center"
        return img
    }
}
