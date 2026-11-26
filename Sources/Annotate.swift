import AppKit
import CoreGraphics

/// Annotation tools drawn over a capture. Rectangle and ellipse share one
/// toolbar button (the frame), which offers both shapes once chosen, and
/// whether they are filled (covering what is inside).
enum AnnotationTool: Int, CaseIterable {
    case rectangle, ellipse, arrow, pen, text, mosaic

    /// The two frame shapes behind the toolbar's single frame button.
    static let frameShapes: [AnnotationTool] = [.rectangle, .ellipse]
    var isFrame: Bool { Self.frameShapes.contains(self) }
    /// The mosaic copies the screen; every other tool draws in the chosen colour.
    var usesColor: Bool { self != .mosaic }

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .pen:       return "scribble"
        case .text:      return "textformat"
        case .mosaic:    return "checkerboard.rectangle"
        }
    }

    /// The frame shapes' solid look, while Fill is on.
    func symbolName(filled: Bool) -> String {
        guard filled, isFrame else { return symbolName }
        return symbolName + ".fill"
    }

    var title: String {
        switch self {
        case .rectangle: return L("Rectangle")
        case .ellipse:   return L("Ellipse")
        case .arrow:     return L("Arrow")
        case .pen:       return L("Pen")
        case .text:      return L("Text")
        case .mosaic:    return L("Mosaic")
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
        /// A brush stroke (as wide as the annotation's line width) that shows
        /// `pixels`, a pixelated copy of the screens covering `area`.
        case mosaic([CGPoint], pixels: CGImage?, area: CGRect)
    }

    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat
    /// Rectangle / ellipse: painted solid in `color`, covering what is inside.
    var filled = false

    /// Smallest rect that contains the whole annotation, for clipping.
    var bounds: CGRect {
        switch shape {
        case .rectangle(let r), .ellipse(let r):
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .mosaic(let points, _, _):
            guard let first = points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
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
            if filled { ctx.fill(r) }
            ctx.stroke(r)
        case .ellipse(let r):
            if filled { ctx.fillEllipse(in: r) }
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
        case .mosaic(let points, let pixels, let area):
            guard let pixels, let first = points.first else { break }
            if points.count == 1 {
                // A click paints one round dab.
                ctx.addEllipse(in: CGRect(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2,
                                          width: lineWidth, height: lineWidth))
            } else {
                ctx.move(to: first)
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.replacePathWithStrokedPath()
            }
            ctx.clip()
            ctx.interpolationQuality = .none     // keep the blocks sharp
            Mosaic.drawUpright(pixels, in: area, on: ctx)
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

/// Pixelates the captured screens for the mosaic brush.
enum Mosaic {
    /// Side of one mosaic block, in points.
    static let blockSize: CGFloat = 8
    /// Brush widths offered in the toolbar, in points.
    static let brushSizes: [CGFloat] = [16, 28, 44]
    static let defaultBrushSize: CGFloat = 28

    /// One pixel per block: the screens under `rect` scaled down, so that
    /// drawing it back into `rect` without interpolation shows the blocks.
    static func image(of rect: CGRect, captures: [DisplayCapture]) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let width = max(1, Int((rect.width / blockSize).rounded(.up)))
        let height = max(1, Int((rect.height / blockSize).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Same y-down space as the selection, at one pixel per block.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.interpolationQuality = .high         // averages the pixels of each block
        var drewAny = false
        for capture in captures {
            let part = rect.intersection(capture.bounds)
            guard !part.isNull, part.width >= 1, part.height >= 1,
                  let piece = ScreenCapture.crop(capture, localRect: part.offsetBy(dx: -capture.bounds.minX,
                                                                                    dy: -capture.bounds.minY))
            else { continue }
            drawUpright(piece, in: part, on: ctx)
            drewAny = true
        }
        return drewAny ? ctx.makeImage() : nil
    }

    /// Draws `image` upright into `rect` of a y-down context (CGContext.draw
    /// paints bottom-up, so the image is flipped back locally).
    static func drawUpright(_ image: CGImage, in rect: CGRect, on ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}
