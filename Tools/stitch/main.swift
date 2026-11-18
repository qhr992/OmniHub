// Validates ScrollStitcher against synthetic viewport frames cut from one tall
// source document. A correct stitcher must reproduce the document byte-for-byte.
//
// Cases:
//   1. plain scrolling, uneven steps, last step short (page bottom)
//   2. a document with blank areas up to ~45% of the viewport (ambiguous
//      overlap; a blank run taller than the overlap is undecidable by design)
//   3. sticky header + footer that never move
//   4. repeated / unchanged frames and a scroll back up in the middle

import CoreGraphics
import Foundation

let width = 640

/// Deterministic noisy rows so every row signature is unique.
func noisyDocument(height: Int, blankRanges: [Range<Int>] = [], seed start: UInt32 = 0x9E3779B9) -> [UInt8] {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var seed = start
    for y in 0..<height {
        if blankRanges.contains(where: { $0.contains(y) }) { continue }
        for x in 0..<width {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let i = (y * width + x) * 4
            bytes[i] = UInt8((y &* 7 &+ x / 9) & 0xFF)
            bytes[i + 1] = UInt8((seed >> 16) & 0xFF)
            bytes[i + 2] = UInt8((y / 3) & 0xFF)
        }
    }
    return bytes
}

func rows(_ source: [UInt8], _ start: Int, _ count: Int) -> [UInt8] {
    Array(source[(start * width * 4)..<((start + count) * width * 4)])
}

func run(_ name: String,
         document: [UInt8], documentHeight: Int,
         viewport: Int, offsets: [Int],
         header: [UInt8] = [], footer: [UInt8] = []) -> Bool {
    let headerRows = header.count / (width * 4)
    let footerRows = footer.count / (width * 4)
    let stitcher = ScrollStitcher()
    for offset in offsets {
        let body = rows(document, offset, viewport)
        let frame = ScrollFrame(width: width,
                                height: headerRows + viewport + footerRows,
                                rgba: header + body + footer)
        stitcher.append(frame)
    }
    let expected = header + rows(document, 0, documentHeight) + footer
    let expectedHeight = headerRows + documentHeight + footerRows
    guard let image = stitcher.makeImage(), let data = image.dataProvider?.data as Data? else {
        print("FAIL  \(name): no image")
        return false
    }
    let produced = [UInt8](data)
    if stitcher.height == expectedHeight && produced == expected {
        print("PASS  \(name): height=\(stitcher.height), byte-identical")
        return true
    }
    print("FAIL  \(name): height=\(stitcher.height) expected=\(expectedHeight)")
    return false
}

var ok = true

let plain = noisyDocument(height: 2400)
ok = run("plain scroll, uneven steps",
         document: plain, documentHeight: 2400,
         viewport: 800, offsets: [0, 310, 700, 1180, 1600]) && ok

let blank = noisyDocument(height: 3000, blankRanges: [150..<450, 1400..<1750, 2500..<2700])
ok = run("large blank areas",
         document: blank, documentHeight: 3000,
         viewport: 800, offsets: [0, 300, 600, 950, 1300, 1700, 2050, 2200]) && ok

let sticky = noisyDocument(height: 2000, seed: 0x1234_5678)
let header = rows(noisyDocument(height: 60, seed: 0xAAAA_0001), 0, 60)
let footer = rows(noisyDocument(height: 40, seed: 0xBBBB_0002), 0, 40)
ok = run("sticky header + footer",
         document: sticky, documentHeight: 2000,
         viewport: 700, offsets: [0, 350, 700, 1000, 1300],
         header: header, footer: footer) && ok

ok = run("unchanged frames + scroll back up",
         document: plain, documentHeight: 2400,
         viewport: 800, offsets: [0, 0, 400, 400, 150, 400, 800, 800, 1200, 1600, 1600]) && ok

exit(ok ? 0 : 1)
