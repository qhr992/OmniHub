import CoreGraphics
import Foundation

/// One captured frame as tightly packed RGBA8 pixels.
struct ScrollFrame {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    /// Values per row signature: four horizontal luminance bands plus the
    /// mean horizontal gradient. Cheap to compare, yet distinct for UI/text.
    static let signatureStride = 5

    /// Flat array of `height * signatureStride` floats.
    func rowSignatures() -> [Float] {
        let stride = Self.signatureStride
        var out = [Float](repeating: 0, count: height * stride)
        let bands = 4
        rgba.withUnsafeBufferPointer { buf in
            for y in 0..<height {
                let rowStart = y * width * 4
                var sums = [Float](repeating: 0, count: bands)
                var counts = [Float](repeating: 0, count: bands)
                var grad: Float = 0
                var n: Float = 0
                var previous: Float = -1
                var x = 0
                while x < width {
                    let i = rowStart + x * 4
                    let l = 0.299 * Float(buf[i]) + 0.587 * Float(buf[i + 1]) + 0.114 * Float(buf[i + 2])
                    let band = min(bands - 1, x * bands / max(width, 1))
                    sums[band] += l
                    counts[band] += 1
                    if previous >= 0 { grad += abs(l - previous) }
                    previous = l
                    n += 1
                    x += 2          // sample every 2nd pixel
                }
                for band in 0..<bands {
                    out[y * stride + band] = sums[band] / max(counts[band], 1)
                }
                out[y * stride + bands] = grad / max(n, 1)
            }
        }
        return out
    }
}

/// Builds a tall image out of successive captures of a scrolling region.
///
/// Each new frame is compared with the *previous frame* over their whole
/// overlap to find how far the content moved up (`shift`). Rows that never
/// move between frames (sticky headers / footers) are detected and left out
/// of the matching; the footer is appended once at the end.
///
/// When the overlap as a whole does not match because part of the page
/// changed (a sticky bar that shows up after some scrolling, a hover effect,
/// an image loading), the shift is looked up again row by row: most rows of
/// the overlap still agree. Only a frame with no overlap at all is appended
/// unmatched — appending a frame that does overlap would repeat content.
final class ScrollStitcher {
    private(set) var width: Int = 0
    /// Rows committed so far, excluding the pinned footer.
    private var rows = 0
    private var pixels: [UInt8] = []

    private var previous: ScrollFrame?
    private var previousSignatures: [Float] = []

    private var locked = false
    private var header = 0
    private var footer = 0
    private var footerPixels: [UInt8] = []

    /// Frames that matched nothing: once the same unmatched picture has been
    /// seen `settleCount` times in a row the page has clearly come to rest
    /// somewhere past the overlap, so it is appended whole rather than lost.
    private var strayed: [Float] = []
    private var strayedCount = 0
    private let settleCount = 3
    /// How many times the overlap was lost and a frame was appended unmatched.
    private(set) var gaps = 0

    /// Mean per-row signature distance above which a shift is rejected.
    private let matchThreshold: Float = 2.5
    /// Row by row: a row agrees below this distance, and a shift is taken
    /// when at least `agreeShare` of the overlap agrees.
    private let rowAgreeThreshold: Float = 1.5
    private let agreeShare: Float = 0.75
    /// Rows whose signatures differ by less than this count as unchanged.
    private let staticEpsilon: Float = 0.35
    /// Hard cap so a runaway capture cannot exhaust memory.
    private let maxHeight = 40_000

    var height: Int { rows + (locked ? footer : 0) }
    var isFull: Bool { height >= maxHeight }

    private func distance(_ a: [Float], _ ai: Int, _ b: [Float], _ bi: Int) -> Float {
        let s = ScrollFrame.signatureStride
        let x = ai * s, y = bi * s
        let lum = abs(a[x] - b[y]) + abs(a[x + 1] - b[y + 1]) + abs(a[x + 2] - b[y + 2]) + abs(a[x + 3] - b[y + 3])
        return lum / 4 + 0.5 * abs(a[x + 4] - b[y + 4])
    }

    /// Returns the number of newly appended rows (0 when nothing new arrived).
    @discardableResult
    func append(_ frame: ScrollFrame) -> Int {
        let signatures = frame.rowSignatures()

        guard let previous else {
            width = frame.width
            pixels = frame.rgba
            rows = frame.height
            self.previous = frame
            previousSignatures = signatures
            return frame.height
        }
        guard frame.width == width, frame.height == previous.height else { return 0 }
        let h = frame.height

        // Static rows at the top and bottom (only measured until locked).
        var top = header
        var bottom = footer
        if !locked {
            top = 0
            while top < h, distance(previousSignatures, top, signatures, top) < staticEpsilon { top += 1 }
            if top == h { return 0 }                       // identical frame
            bottom = 0
            while bottom < h - top,
                  distance(previousSignatures, h - 1 - bottom, signatures, h - 1 - bottom) < staticEpsilon {
                bottom += 1
            }
            // Implausibly large static areas are treated as coincidence.
            if top > h * 2 / 5 { top = 0 }
            if bottom > h * 2 / 5 { bottom = 0 }
            if h - top - bottom < 48 { top = 0; bottom = 0 }
        }

        let band = h - top - bottom
        let minOverlap = max(16, band / 8)
        guard band > minOverlap else { return 0 }

        // Find the smallest shift whose overlap matches best. "Smallest" is
        // deliberate: it demands the largest overlap, which keeps uniform
        // (blank) areas from being duplicated.
        var bestShift = -1
        var bestScore = Float.greatestFiniteMagnitude
        for shift in 0...(band - minOverlap) {
            let overlap = band - shift
            let limit = bestScore * Float(overlap)
            var total: Float = 0
            var k = 0
            while k < overlap {
                total += distance(previousSignatures, top + shift + k, signatures, top + k)
                if total > limit { break }
                k += 1
            }
            guard k == overlap else { continue }
            let score = total / Float(overlap)
            if score < bestScore - 1e-4 {
                bestScore = score
                bestShift = shift
            }
        }

        if bestScore > matchThreshold,
           let partial = partialMatch(signatures, top: top, band: band, minOverlap: minOverlap) {
            bestShift = partial
            bestScore = 0
        }
        if bestShift == 0, bestScore <= matchThreshold {
            strayedCount = 0
            return 0                                      // nothing moved
        }
        guard bestShift > 0, bestScore <= matchThreshold else {
            return appendStrayed(frame, signatures: signatures, top: top, bottom: bottom)
        }
        strayedCount = 0

        if !locked {
            locked = true
            header = top
            footer = bottom
            // The first frame was stored whole; pull its footer back out.
            if footer > 0 {
                rows -= footer
                pixels.removeLast(footer * width * 4)
            }
        }

        let allowed = min(bestShift, maxHeight - height)
        guard allowed > 0 else { return 0 }
        let bandEnd = h - footer
        let start = (bandEnd - bestShift) * width * 4
        pixels.append(contentsOf: frame.rgba[start..<(start + allowed * width * 4)])
        rows += allowed
        if footer > 0 {
            footerPixels = Array(frame.rgba[(bandEnd * width * 4)...])
        }
        self.previous = frame
        previousSignatures = signatures
        return allowed
    }

    /// The shift at which the largest share of overlapping rows agree, when
    /// that share reaches `agreeShare`; the smallest such shift on a tie, for
    /// the same reason as in `append`. Nil when no shift is convincing.
    private func partialMatch(_ signatures: [Float], top: Int, band: Int, minOverlap: Int) -> Int? {
        var best: (shift: Int, share: Float)?
        for shift in 0...(band - minOverlap) {
            let overlap = band - shift
            let needed = Int((agreeShare * Float(overlap)).rounded(.up))
            let allowedMisses = overlap - max(needed, Int(((best?.share ?? 0) * Float(overlap)).rounded(.down)))
            var agree = 0
            var misses = 0
            for k in 0..<overlap {
                if distance(previousSignatures, top + shift + k, signatures, top + k) < rowAgreeThreshold {
                    agree += 1
                } else {
                    misses += 1
                    if misses > allowedMisses { break }             // cannot beat the best any more
                }
            }
            let share = Float(agree) / Float(overlap)
            guard agree >= needed, agree >= minOverlap else { continue }
            if share > (best?.share ?? 0) + 1e-4 { best = (shift, share) }
        }
        return best?.shift
    }

    /// No overlap with the previous frame (scrolled further than one
    /// viewport between two captures). Waits until the picture is stable,
    /// then continues from it.
    private func appendStrayed(_ frame: ScrollFrame, signatures: [Float], top: Int, bottom: Int) -> Int {
        let h = frame.height
        var same = strayed.count == signatures.count
        if same {
            for row in 0..<h where distance(strayed, row, signatures, row) >= staticEpsilon {
                same = false
                break
            }
        }
        if !same {
            strayed = signatures
            strayedCount = 1
            return 0
        }
        strayedCount += 1
        guard strayedCount >= settleCount else { return 0 }
        strayedCount = 0
        strayed = []

        if !locked {
            locked = true
            header = top
            footer = bottom
            if footer > 0 {
                rows -= footer
                pixels.removeLast(footer * width * 4)
            }
        }
        let bandEnd = h - footer
        let allowed = min(bandEnd - header, maxHeight - height)
        guard allowed > 0 else { return 0 }
        let start = header * width * 4
        pixels.append(contentsOf: frame.rgba[start..<(start + allowed * width * 4)])
        rows += allowed
        if footer > 0 { footerPixels = Array(frame.rgba[(bandEnd * width * 4)...]) }
        previous = frame
        previousSignatures = signatures
        gaps += 1
        return allowed
    }

    /// Composes the accumulated rows into one image.
    func makeImage() -> CGImage? {
        guard width > 0, rows > 0, !pixels.isEmpty else { return nil }
        var data = Data(pixels)
        if locked, footer > 0 { data.append(contentsOf: footerPixels) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
