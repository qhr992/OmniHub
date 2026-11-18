// Verifies the capture path used by OmniHub: ScreenCapture.captureAllDisplays
// (ScreenCaptureKit) -> crop -> pixel statistics. Built together with
// Sources/ScreenCapture.swift (see test.sh). Prints evidence that real screen
// content was captured, not just a wallpaper.
//
// ScreenCaptureKit needs Screen Recording for the program running this test
// (the terminal app, or sshd when run over ssh); without it nothing is captured.

import AppKit
import CoreGraphics

func stats(_ image: CGImage) -> (unique: Int, mean: Double) {
    let width = min(image.width, 400)
    let height = min(image.height, 400)
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let ctx = CGContext(data: &data, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return (0, 0) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var set = Set<UInt32>()
    var sum = 0
    for i in stride(from: 0, to: data.count, by: 4) {
        let px = UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
        set.insert(px)
        sum += Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])
    }
    return (set.count, Double(sum) / Double(width * height * 3))
}

print("CGPreflightScreenCaptureAccess = \(CGPreflightScreenCaptureAccess())")
print("active displays = \(ScreenCapture.activeDisplayIDs().count)")

ScreenCapture.captureAllDisplays { captures in
    if captures.isEmpty {
        print("  nothing captured: grant Screen Recording to the program running this test")
    }
    for capture in captures {
        let s = stats(capture.image)
        print(String(format: "  display %u: bounds=%.0fx%.0f  image=%dx%d  scale=%.2f  uniqueColors=%d  mean=%.1f",
                     capture.displayID, capture.bounds.width, capture.bounds.height,
                     capture.image.width, capture.image.height, capture.scale, s.unique, s.mean))
        // The same local-rect crop OmniHub performs.
        let sel = CGRect(x: 100, y: 100, width: 320, height: 200)
        if let cropped = ScreenCapture.crop(capture, localRect: sel) {
            print("    crop 320x200pt -> \(cropped.width)x\(cropped.height)px  OK")
        } else {
            print("    crop FAILED")
        }
    }
    exit(0)
}
RunLoop.main.run()
