// Builds the OmniHub app icon (1024×1024 PNG) from an avatar picture.
//   swift Tools/make-icon.swift <avatar.png> <out.png>
//
// macOS icon grid: the picture fills an 824pt squircle centred on a 1024
// canvas, with a soft drop shadow and a thin light rim.

import AppKit
import CoreGraphics

guard CommandLine.arguments.count > 2,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    print("usage: make-icon.swift <avatar.png> <out.png>")
    exit(1)
}
var proposed = NSRect(origin: .zero, size: source.size)
guard let avatar = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { exit(1) }

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
              color: CGColor(red: 0.2, green: 0.2, blue: 0.4, alpha: 0.35))
ctx.addPath(squircle)
ctx.setFillColor(CGColor(red: 0.85, green: 0.86, blue: 0.95, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.draw(avatar, in: body)
ctx.restoreGState()

ctx.addPath(squircle)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
ctx.setLineWidth(6)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote \(CommandLine.arguments[2])")
