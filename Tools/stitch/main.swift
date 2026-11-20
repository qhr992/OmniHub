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

/// Frames with something drawn over the page that is not part of the
/// document (a sticky bar that appears once the page has scrolled, the
/// overlay scrollbar while it moves). Only the document is expected back.
/// `wholeRows`: compare the pixels too (false when the overlay is part of
/// what the screen showed, like a scrollbar, and only the height can be checked).
func runOverlaid(_ name: String, document: [UInt8], documentHeight: Int, viewport: Int, offsets: [Int],
                 wholeRows: Bool = true,
                 overlay: (_ frameRows: inout [UInt8], _ offset: Int, _ index: Int) -> Void) -> Bool {
    let stitcher = ScrollStitcher()
    for (index, offset) in offsets.enumerated() {
        var body = rows(document, offset, viewport)
        overlay(&body, offset, index)
        stitcher.append(ScrollFrame(width: width, height: viewport, rgba: body))
    }
    guard let image = stitcher.makeImage(), let data = image.dataProvider?.data as Data? else {
        print("FAIL  \(name): no image"); return false
    }
    let produced = [UInt8](data)
    // The first frame is kept whole (overlay included, if it had one), so
    // compare from below the first frame's overlay band onwards.
    let expected = rows(document, 0, documentHeight)
    let skip = 80 * width * 4
    if stitcher.height == documentHeight && stitcher.gaps == 0 && produced.count == expected.count
        && (!wholeRows || produced[skip...] == expected[skip...]) {
        print("PASS  \(name): height=\(stitcher.height), document intact, gaps=\(stitcher.gaps)")
        return true
    }
    print("FAIL  \(name): height=\(stitcher.height) expected=\(documentHeight) gaps=\(stitcher.gaps)")
    return false
}

/// Slow scrolling the way people do it: small steps, each followed by a rest
/// (the same frame captured several times).
func slowWithRests(to end: Int, step: Int, rest: Int) -> [Int] {
    var out: [Int] = []
    var offset = 0
    while true {
        out += Array(repeating: offset, count: rest)
        if offset == end { break }
        offset = min(end, offset + step)
    }
    return out
}

let slowPage = noisyDocument(height: 2400, seed: 0x5150_A11E)
let slowOffsets = slowWithRests(to: 1600, step: 37, rest: 4)

ok = runOverlaid("slow scroll with rests, a sticky bar appears after 200 px",
                 document: slowPage, documentHeight: 2400, viewport: 800, offsets: slowOffsets) { body, offset, _ in
    guard offset > 200 else { return }
    for i in 0..<(70 * width * 4) where i % 4 != 3 { body[i] = 40 }        // a dark 70-row bar
} && ok

ok = runOverlaid("slow scroll with rests, overlay scrollbar while moving",
                 document: slowPage, documentHeight: 2400, viewport: 800, offsets: slowOffsets,
                 wholeRows: false) { body, offset, index in
    // A 12 px thumb on the right, 120 rows tall, following the scroll position.
    let thumbTop = 80 + offset * (800 - 200) / 1600
    for y in thumbTop..<(thumbTop + 120) {
        for x in (width - 14)..<(width - 2) {
            let i = (y * width + x) * 4
            body[i] = 90; body[i + 1] = 90; body[i + 2] = 90
        }
    }
} && ok

// A real leap past the viewport still has no overlap: appended once it rests (one gap).
let leapPage = noisyDocument(height: 3000, seed: 0x0BAD_F00D)
do {
    let stitcher = ScrollStitcher()
    for offset in [0, 0, 1500, 1500, 1500, 1500] {
        stitcher.append(ScrollFrame(width: width, height: 800, rgba: rows(leapPage, offset, 800)))
    }
    let fine = stitcher.height == 1600 && stitcher.gaps == 1
    print((fine ? "PASS" : "FAIL") + "  a leap past the viewport is still appended once, as a gap: height=\(stitcher.height) gaps=\(stitcher.gaps)")
    ok = fine && ok
}

exit(ok ? 0 : 1)
