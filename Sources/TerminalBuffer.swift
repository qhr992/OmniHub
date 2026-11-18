import Foundation

/// Minimal terminal screen model: a list of lines plus a cursor.
///
/// It understands what an interactive shell actually emits — CR / LF / BS /
/// TAB, cursor movement, line and screen erase, insert/delete characters —
/// and ignores colours and other modes. Full-screen programs (vim, htop) are
/// out of scope.
final class TerminalBuffer {
    /// One cell per terminal column. A wide (CJK) glyph occupies two cells:
    /// the glyph and an empty continuation cell.
    private(set) var lines: [[String]] = [[]]
    private(set) var row = 0
    private(set) var col = 0
    /// Lowest line index changed since the last `consumeDirty()`.
    private var dirtyFrom = 0

    var columns = 120
    var visibleRows = 30
    private let maxLines = 4000

    private enum State { case ground, escape, csi, osc, oscEscape, charset }
    private var state = State.ground
    private var csiBuffer = ""
    private var oscBuffer = ""
    /// Window title set by the shell (OSC 0 / 2), shown as the tab label.
    private(set) var title = ""
    private var pendingBytes: [UInt8] = []
    static let continuation = ""

    func consumeDirty() -> Int {
        let value = min(dirtyFrom, lines.count - 1)
        dirtyFrom = lines.count - 1
        return max(0, value)
    }

    private func touch(_ line: Int) { dirtyFrom = min(dirtyFrom, line) }

    // MARK: Input

    func feed(_ bytes: [UInt8]) {
        pendingBytes.append(contentsOf: bytes)
        // Hold back an incomplete UTF-8 sequence at the end of the chunk.
        var cut = pendingBytes.count
        var index = pendingBytes.count - 1
        var seen = 0
        while index >= 0, seen < 4 {
            let byte = pendingBytes[index]
            seen += 1
            if byte & 0xC0 == 0x80 { index -= 1; continue }       // continuation byte
            let needed: Int
            if byte & 0x80 == 0 { needed = 1 }
            else if byte & 0xE0 == 0xC0 { needed = 2 }
            else if byte & 0xF0 == 0xE0 { needed = 3 }
            else if byte & 0xF8 == 0xF0 { needed = 4 }
            else { needed = 1 }
            if needed > seen { cut = index }
            break
        }
        let ready = pendingBytes[0..<cut]
        let text = String(decoding: ready, as: UTF8.self)
        pendingBytes.removeFirst(cut)
        for scalar in text.unicodeScalars { process(scalar) }
    }

    private func process(_ scalar: Unicode.Scalar) {
        switch state {
        case .ground:
            switch scalar.value {
            case 0x1B: state = .escape
            case 0x0D: col = 0
            case 0x0A, 0x0B, 0x0C: lineFeed()
            case 0x08: if col > 0 { col -= 1 }
            case 0x09: col = min(columns - 1, (col / 8 + 1) * 8)
            case 0x00...0x1F, 0x7F: break                          // BEL and friends
            default: put(scalar)
            }
        case .escape:
            switch scalar {
            case "[": state = .csi; csiBuffer = ""
            case "]", "P", "_", "^": state = .osc; oscBuffer = ""
            case "(", ")", "*", "+", "#", "%": state = .charset
            case "M": if row > 0 { row -= 1 }; state = .ground      // reverse index
            case "c": reset(); state = .ground
            default: state = .ground
            }
        case .charset:
            state = .ground
        case .osc:
            if scalar.value == 0x07 { finishOSC(); state = .ground }
            else if scalar.value == 0x1B { state = .oscEscape }
            else if oscBuffer.count < 256 { oscBuffer.unicodeScalars.append(scalar) }
        case .oscEscape:
            if scalar == "\\" { finishOSC(); state = .ground } else { state = .osc }
        case .csi:
            if scalar.value >= 0x40, scalar.value <= 0x7E {
                executeCSI(final: Character(scalar))
                state = .ground
            } else if csiBuffer.count < 64 {
                csiBuffer.unicodeScalars.append(scalar)
            } else {
                state = .ground
            }
        }
    }

    private func finishOSC() {
        if oscBuffer.hasPrefix("0;") || oscBuffer.hasPrefix("2;") {
            title = String(oscBuffer.dropFirst(2))
        }
        oscBuffer = ""
    }

    // MARK: Printing

    private static func isWide(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v)
            || (0x20000...0x3FFFD).contains(v)
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return true
        default: return (0xFE00...0xFE0F).contains(scalar.value)
        }
    }

    private func put(_ scalar: Unicode.Scalar) {
        if Self.isZeroWidth(scalar) {
            // Attach combining marks to the glyph before the cursor.
            var target = col - 1
            while target > 0, lines[row][safe: target] == Self.continuation { target -= 1 }
            if target >= 0, target < lines[row].count {
                lines[row][target].unicodeScalars.append(scalar)
                touch(row)
            }
            return
        }
        let width = Self.isWide(scalar.value) ? 2 : 1
        if col + width > columns {            // auto-wrap
            lineFeed()
            col = 0
        }
        pad(to: col + width)
        lines[row][col] = String(Character(scalar))
        if width == 2 { lines[row][col + 1] = Self.continuation }
        col += width
        touch(row)
    }

    private func pad(to count: Int) {
        if lines[row].count < count {
            lines[row].append(contentsOf: Array(repeating: " ", count: count - lines[row].count))
        }
    }

    private func lineFeed() {
        row += 1
        if row >= lines.count {
            lines.append([])
            touch(lines.count - 2)
        }
        if lines.count > maxLines {
            let drop = lines.count - maxLines
            lines.removeFirst(drop)
            row = max(0, row - drop)
            dirtyFrom = 0
        }
    }

    private func reset() {
        lines = [[]]
        row = 0
        col = 0
        dirtyFrom = 0
    }

    /// First line of the "screen" — the last `visibleRows` lines.
    private var screenTop: Int { max(0, lines.count - visibleRows) }

    // MARK: CSI

    private func executeCSI(final: Character) {
        if csiBuffer.hasPrefix("?") || csiBuffer.hasPrefix(">") || csiBuffer.hasPrefix("=") { return }
        let params = csiBuffer.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        func param(_ index: Int, _ fallback: Int) -> Int {
            guard index < params.count, let value = params[index], value > 0 else { return fallback }
            return value
        }

        switch final {
        case "A": row = max(screenTop, row - param(0, 1))
        case "B", "e": moveDown(param(0, 1))
        case "C", "a": col = min(columns - 1, col + param(0, 1))
        case "D": col = max(0, col - param(0, 1))
        case "E": moveDown(param(0, 1)); col = 0
        case "F": row = max(screenTop, row - param(0, 1)); col = 0
        case "G", "`": col = min(columns - 1, param(0, 1) - 1)
        case "d": moveTo(row: param(0, 1))
        case "H", "f":
            moveTo(row: param(0, 1))
            col = min(columns - 1, param(1, 1) - 1)
        case "J":
            let mode = params.first.flatMap { $0 } ?? 0
            if mode >= 2 {
                reset()
            } else if mode == 0 {
                if lines[row].count > col { lines[row].removeSubrange(col...) }
                if lines.count > row + 1 { lines.removeSubrange((row + 1)...) }
                touch(row)
            }
        case "K":
            let mode = params.first.flatMap { $0 } ?? 0
            switch mode {
            case 0: if lines[row].count > col { lines[row].removeSubrange(col...) }
            case 1:
                pad(to: col + 1)
                for i in 0...col { lines[row][i] = " " }
            default: lines[row].removeAll()
            }
            touch(row)
        case "P":
            if col < lines[row].count {
                let end = min(lines[row].count, col + param(0, 1))
                lines[row].removeSubrange(col..<end)
                touch(row)
            }
        case "@":
            pad(to: col)
            lines[row].insert(contentsOf: Array(repeating: " ", count: param(0, 1)), at: col)
            touch(row)
        case "X":
            let count = param(0, 1)
            pad(to: col + count)
            for i in col..<(col + count) { lines[row][i] = " " }
            touch(row)
        default:
            break       // colours (m), modes (h/l), scroll regions… ignored
        }
    }

    private func moveDown(_ count: Int) {
        row += count
        while row >= lines.count { lines.append([]) }
        touch(max(0, row - count))
    }

    private func moveTo(row target: Int) {
        row = screenTop + target - 1
        while row >= lines.count { lines.append([]) }
        touch(min(row, lines.count - 1))
    }

    // MARK: Output

    /// Text of one line, trailing blanks removed.
    func text(ofLine index: Int) -> String {
        var cells = lines[index]
        while let last = cells.last, last == " " || last == Self.continuation { cells.removeLast() }
        return cells.joined()
    }

    /// Cursor line text padded so the cursor cell exists, plus the UTF-16
    /// range of that cell inside the returned string.
    func cursorLine() -> (text: String, cursor: NSRange) {
        var cells = lines[row]
        if cells.count <= col { cells.append(contentsOf: Array(repeating: " ", count: col + 1 - cells.count)) }
        while cells.count > col + 1, let last = cells.last, last == " " || last == Self.continuation {
            cells.removeLast()
        }
        let before = cells[0..<col].joined()
        var glyph = cells[col]
        if glyph.isEmpty { glyph = " "; cells[col] = " " }
        return (cells.joined(), NSRange(location: before.utf16.count, length: glyph.utf16.count))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
