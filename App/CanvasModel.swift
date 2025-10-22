import Cocoa
import CoreGraphics

struct Stroke {
    var path: NSBezierPath
    var colour: NSColor
}

struct ImageObject {
    var image: NSImage
    /// Position and size in canvas coords
    var frame: CGRect
}

struct TextBox {
    var text: String
    var frame: CGRect
    var fontSize: CGFloat
    var colour: NSColor
    var fontName: String

    init(text: String = "",
         frame: CGRect,
         fontSize: CGFloat,
         colour: NSColor,
         fontName: String = "SF Pro Text") {
        self.text = text
        self.frame = frame
        self.fontSize = fontSize
        self.colour = colour
        self.fontName = fontName
    }
}

struct Frame {
    var strokes: [Stroke] = []
    var images: [ImageObject] = []
    var texts: [TextBox] = []
}

// MARK: – Exact path + stroke-proximity hit-testing -------------------------

private func cgLineCap(from cap: NSBezierPath.LineCapStyle) -> CGLineCap {
    switch cap {
    case .butt:   return .butt
    case .round:  return .round
    case .square: return .square
    @unknown default: return .butt
    }
}

private func cgLineJoin(from j: NSBezierPath.LineJoinStyle) -> CGLineJoin {
    switch j {
    case .miter: return .miter
    case .round: return .round
    case .bevel: return .bevel
    @unknown default: return .miter
    }
}

extension NSBezierPath {
    /// A precise CGPath conversion that preserves all path segments.
    var cgPathExact: CGPath {
        let g = CGMutablePath()
        for i in 0..<elementCount {
            var pts = [NSPoint](repeating: .zero, count: 3)
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:           g.move(to: pts[0])
            case .lineTo:           g.addLine(to: pts[0])
            case .curveTo:          g.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: // approximate quad Bézier with cubic
                let s = pts[0], c = pts[1], e = pts[2]
                let c1 = NSPoint(x: s.x + 2/3*(c.x-s.x), y: s.y + 2/3*(c.y-s.y))
                let c2 = NSPoint(x: e.x + 2/3*(c.x-e.x), y: e.y + 2/3*(c.y-e.y))
                g.addCurve(to: e, control1: c1, control2: c2)
            case .cubicCurveTo:     g.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath:        g.closeSubpath()
            @unknown default: break
            }
        }
        return g
    }

    /// True if point `p` is near the painted stroke (fixes “inside loop deletes” bug).
    func hitsStroke(_ p: CGPoint, tolerance: CGFloat = 2) -> Bool {
        let stroked = cgPathExact.copy(
            strokingWithWidth: max(1, lineWidth) + 2 * tolerance,
            lineCap: cgLineCap(from: lineCapStyle),
            lineJoin: cgLineJoin(from: lineJoinStyle),
            miterLimit: miterLimit,
            transform: .identity
        )
        return stroked.contains(p)
    }

    /// Bounding box of the stroked outline (accurate for selection tests).
    var strokedBoundingBox: CGRect {
        let stroked = cgPathExact.copy(
            strokingWithWidth: max(1, lineWidth),
            lineCap: cgLineCap(from: lineCapStyle),
            lineJoin: cgLineJoin(from: lineJoinStyle),
            miterLimit: miterLimit,
            transform: .identity
        )
        return stroked.boundingBoxOfPath
    }
}
