import AppKit
import CoreGraphics

/// Annotation tools drawn over a capture.
enum AnnotationTool: Int, CaseIterable {
    case rectangle, ellipse, arrow, pen, text

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .pen:       return "scribble"
        case .text:      return "textformat"
        }
    }

    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse:   return "Ellipse"
        case .arrow:     return "Arrow"
        case .pen:       return "Pen"
        case .text:      return "Text"
        }
    }
}

/// A single annotation, stored in the CG global coordinate space (points,
/// origin top-left, y down) so it survives any per-display transform.
struct Annotation {
    enum Shape {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
        case text(String, CGPoint)
    }

    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat

    /// Smallest rect that contains the whole annotation, for clipping.
    var bounds: CGRect {
        switch shape {
        case .rectangle(let r), .ellipse(let r):
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .arrow(let a, let b):
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(a.x - b.x), height: abs(a.y - b.y))
            return r.insetBy(dx: -lineWidth * 4, dy: -lineWidth * 4)
        case .pen(let points):
            guard let first = points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .text(let string, let origin):
            let size = (string as NSString).size(withAttributes: Annotation.textAttributes)
            return CGRect(origin: origin, size: size).insetBy(dx: -2, dy: -2)
        }
    }

    static let textAttributes: [NSAttributedString.Key: Any] = {
        [.font: NSFont.systemFont(ofSize: 16, weight: .semibold),
         .foregroundColor: NSColor.systemRed]
    }()

    /// Draws the annotation. The context must already be in the CG global
    /// space (top-left origin, y down).
    func draw(in ctx: CGContext, textColor: NSColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch shape {
        case .rectangle(let r):
            ctx.stroke(r)
        case .ellipse(let r):
            ctx.strokeEllipse(in: r)
        case .arrow(let from, let to):
            drawArrow(ctx, from: from, to: to)
        case .pen(let points):
            guard points.count > 1 else { break }
            ctx.beginPath()
            ctx.move(to: points[0])
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .text(let string, let origin):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: color
            ]
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            (string as NSString).draw(at: origin, withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }

    private func drawArrow(_ ctx: CGContext, from: CGPoint, to: CGPoint) {
        let headLength = max(lineWidth * 4, 10)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let spread = CGFloat.pi / 7

        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()

        ctx.beginPath()
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - headLength * cos(angle - spread),
                                y: to.y - headLength * sin(angle - spread)))
        ctx.addLine(to: CGPoint(x: to.x - headLength * cos(angle + spread),
                                y: to.y - headLength * sin(angle + spread)))
        ctx.closePath()
        ctx.fillPath()
    }
}
