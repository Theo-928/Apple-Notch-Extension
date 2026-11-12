import Foundation

/// A compact xterm-compatible screen model: enough of VT100/xterm for shells,
/// prompts with colors, and full-screen programs (vim, less, htop, top).
final class TerminalEmulator {
    enum TColor: Equatable {
        case def
        case idx(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    struct Attr: Equatable {
        var fg: TColor = .def
        var bg: TColor = .def
        var bold = false, dim = false, italic = false, underline = false, inverse = false
    }

    struct Cell {
        var ch: Character = " "
        var attr = Attr()
        /// Second half of a double-width character; not drawn.
        var isWideTail = false
    }

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var lines: [[Cell]]
    private(set) var scrollback: [[Cell]] = []
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = true
    private(set) var appCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var isAlternateScreen = false
    /// The program asked for mouse events (DEC modes 1000/1002/1003).
    private(set) var mouseReporting = false
    /// Mouse events should use SGR encoding (DEC mode 1006).
    private(set) var sgrMouse = false
    /// Running total of lines ever pushed into scrollback (survives trimming),
    /// so a scrolled-back view can stay put while new output arrives.
    private(set) var scrollbackPushCount = 0
    private(set) var title = ""

    /// Bytes the terminal must send back to the program (e.g. cursor position reports).
    var respond: ([UInt8]) -> Void = { _ in }

    private let maxScrollback = 3000
    private var attr = Attr()
    private var wrapPending = false
    private var autowrap = true
    private var originMode = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var savedCursor: (x: Int, y: Int, attr: Attr) = (0, 0, Attr())
    private var savedPrimary: [[Cell]]?
    private var savedPrimaryCursor: (x: Int, y: Int) = (0, 0)

    // Parser state
    private enum State { case ground, escape, csi, osc, oscEscape, charset, ignoreST, ignoreSTEscape }
    private var state: State = .ground
    private var csiParams: [UInt8] = []
    private var csiPrivate: UInt8 = 0
    private var csiIntermediate: UInt8 = 0
    private var oscBuffer: [UInt8] = []
    private var utf8Buffer: [UInt8] = []
    private var utf8Needed = 0

    init(cols: Int, rows: Int) {
        self.cols = max(2, cols)
        self.rows = max(2, rows)
        scrollBottom = self.rows - 1
        lines = Array(repeating: Array(repeating: Cell(), count: self.cols), count: self.rows)
    }

    // MARK: - Public

    func feed(_ bytes: [UInt8]) {
        for b in bytes { process(b) }
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(2, newRows)
        guard newCols != cols || newRows != rows else { return }

        func fit(_ line: [Cell]) -> [Cell] {
            if line.count == newCols { return line }
            if line.count > newCols { return Array(line.prefix(newCols)) }
            return line + Array(repeating: Cell(), count: newCols - line.count)
        }
        lines = lines.map(fit)
        scrollback = scrollback.map(fit)
        savedPrimary = savedPrimary?.map(fit)

        if newRows < lines.count {
            // Drop blank lines below the cursor first, then push the top into scrollback.
            while lines.count > newRows, cursorY < lines.count - 1, isBlank(lines[lines.count - 1]) {
                lines.removeLast()
            }
            while lines.count > newRows {
                let top = lines.removeFirst()
                if !isAlternateScreen { appendScrollback(top) }
                cursorY -= 1
            }
        } else if newRows > lines.count {
            // Pull lines back from scrollback so content stays anchored to the bottom.
            while lines.count < newRows, !isAlternateScreen, let last = scrollback.popLast() {
                lines.insert(fit(last), at: 0)
                cursorY += 1
            }
            while lines.count < newRows { lines.append(blankLine(newCols)) }
        }
        if var primary = savedPrimary {
            while primary.count > newRows { primary.removeFirst() }
            while primary.count < newRows { primary.append(blankLine(newCols)) }
            savedPrimary = primary
        }
        cols = newCols
        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        cursorX = min(max(0, cursorX), cols - 1)
        cursorY = min(max(0, cursorY), rows - 1)
        wrapPending = false
    }

    /// Text of a line, trailing spaces trimmed.
    static func text(of line: [Cell], from: Int = 0, to: Int? = nil) -> String {
        let end = min(to ?? line.count, line.count)
        guard from < end else { return "" }
        var s = ""
        for i in from..<end where !line[i].isWideTail { s.append(line[i].ch) }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    func clearScrollback() { scrollback.removeAll() }

    // MARK: - Byte processing

    private func process(_ b: UInt8) {
        switch state {
        case .ground:
            if utf8Needed > 0 {
                if b & 0xC0 == 0x80 {
                    utf8Buffer.append(b)
                    utf8Needed -= 1
                    if utf8Needed == 0 {
                        if let s = String(bytes: utf8Buffer, encoding: .utf8), let scalar = s.unicodeScalars.first {
                            put(scalar)
                        }
                        utf8Buffer.removeAll()
                    }
                    return
                }
                utf8Buffer.removeAll(); utf8Needed = 0
            }
            switch b {
            case 0x1B: state = .escape
            case 0x0D: cursorX = 0; wrapPending = false
            case 0x0A, 0x0B, 0x0C: lineFeed()
            case 0x08: if cursorX > 0 { cursorX -= 1 }; wrapPending = false
            case 0x09:
                let next = min(cols - 1, (cursorX / 8 + 1) * 8)
                cursorX = next; wrapPending = false
            case 0x07, 0x00, 0x0E, 0x0F: break
            case 0x20..<0x7F: put(Unicode.Scalar(b))
            case 0xC0..<0xE0: utf8Buffer = [b]; utf8Needed = 1
            case 0xE0..<0xF0: utf8Buffer = [b]; utf8Needed = 2
            case 0xF0..<0xF8: utf8Buffer = [b]; utf8Needed = 3
            default: break
            }

        case .escape:
            state = .ground
            switch b {
            case UInt8(ascii: "["):
                csiParams.removeAll(); csiPrivate = 0; csiIntermediate = 0
                state = .csi
            case UInt8(ascii: "]"): oscBuffer.removeAll(); state = .osc
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"): state = .charset
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .ignoreST
            case UInt8(ascii: "7"): saveCursor()
            case UInt8(ascii: "8"): restoreCursor()
            case UInt8(ascii: "D"): lineFeed()
            case UInt8(ascii: "E"): cursorX = 0; lineFeed()
            case UInt8(ascii: "M"): reverseIndex()
            case UInt8(ascii: "c"): fullReset()
            default: break
            }

        case .charset:
            state = .ground

        case .csi:
            switch b {
            case 0x30...0x39, UInt8(ascii: ";"), UInt8(ascii: ":"):
                csiParams.append(b)
            case UInt8(ascii: "?"), UInt8(ascii: ">"), UInt8(ascii: "="), UInt8(ascii: "<"):
                if csiParams.isEmpty { csiPrivate = b }
            case 0x20...0x2F:
                csiIntermediate = b
            case 0x40...0x7E:
                state = .ground
                executeCSI(b)
            case 0x1B:
                state = .escape
            default:
                break
            }

        case .osc:
            if b == 0x07 { handleOSC(); state = .ground }
            else if b == 0x1B { state = .oscEscape }
            else if oscBuffer.count < 4096 { oscBuffer.append(b) }

        case .oscEscape:
            handleOSC()
            state = .ground
            if b != UInt8(ascii: "\\") { process(b) }

        case .ignoreST:
            if b == 0x1B { state = .ignoreSTEscape } else if b == 0x07 { state = .ground }

        case .ignoreSTEscape:
            state = b == UInt8(ascii: "\\") ? .ground : .ignoreST
        }
    }

    // MARK: - Printing

    private func put(_ scalar: Unicode.Scalar) {
        // Combining marks join the previous cell.
        if scalar.properties.generalCategory == .nonspacingMark || scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) {
            let x = wrapPending ? cursorX : cursorX - 1
            if x >= 0, x < cols {
                var s = String(lines[cursorY][x].ch)
                s.unicodeScalars.append(scalar)
                if let c = s.first { lines[cursorY][x].ch = c }
            }
            return
        }
        let width = Self.isWide(scalar) ? 2 : 1
        if wrapPending {
            if autowrap { cursorX = 0; lineFeed() }
            wrapPending = false
        }
        if cursorX + width > cols {
            if autowrap { cursorX = 0; lineFeed() } else { cursorX = cols - width }
        }
        lines[cursorY][cursorX] = Cell(ch: Character(scalar), attr: attr)
        if width == 2, cursorX + 1 < cols {
            lines[cursorY][cursorX + 1] = Cell(ch: " ", attr: attr, isWideTail: true)
        }
        cursorX += width
        if cursorX >= cols {
            cursorX = cols - 1
            wrapPending = true
        }
    }

    static func isWide(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x1100 { return false }
        if s.properties.isEmojiPresentation { return true }
        return (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v)
            || (0x20000...0x3FFFD).contains(v)
    }

    // MARK: - Movement & scrolling

    private func blankLine(_ count: Int? = nil) -> [Cell] {
        Array(repeating: Cell(ch: " ", attr: Attr(bg: attr.bg)), count: count ?? cols)
    }

    private func isBlank(_ line: [Cell]) -> Bool {
        line.allSatisfy { $0.ch == " " && $0.attr.bg == .def }
    }

    private func appendScrollback(_ line: [Cell]) {
        scrollback.append(line)
        scrollbackPushCount += 1
        if scrollback.count > maxScrollback { scrollback.removeFirst(scrollback.count - maxScrollback) }
    }

    private func lineFeed() {
        wrapPending = false
        if cursorY == scrollBottom { scrollUp(1) }
        else if cursorY < rows - 1 { cursorY += 1 }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorY == scrollTop { scrollDown(1) }
        else if cursorY > 0 { cursorY -= 1 }
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<min(n, scrollBottom - scrollTop + 1) {
            let removed = lines.remove(at: scrollTop)
            if scrollTop == 0 && !isAlternateScreen { appendScrollback(removed) }
            lines.insert(blankLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        for _ in 0..<min(n, scrollBottom - scrollTop + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: scrollTop)
        }
    }

    private func saveCursor() { savedCursor = (cursorX, cursorY, attr) }
    private func restoreCursor() {
        cursorX = min(savedCursor.x, cols - 1)
        cursorY = min(savedCursor.y, rows - 1)
        attr = savedCursor.attr
        wrapPending = false
    }

    private func fullReset() {
        attr = Attr()
        lines = Array(repeating: blankLine(), count: rows)
        cursorX = 0; cursorY = 0
        scrollTop = 0; scrollBottom = rows - 1
        cursorVisible = true; appCursorKeys = false; bracketedPaste = false; autowrap = true
        mouseReporting = false; sgrMouse = false
        isAlternateScreen = false; savedPrimary = nil
    }

    private func setAlternateScreen(_ on: Bool) {
        guard on != isAlternateScreen else { return }
        if on {
            savedPrimary = lines
            savedPrimaryCursor = (cursorX, cursorY)
            lines = Array(repeating: blankLine(), count: rows)
            isAlternateScreen = true
        } else {
            lines = savedPrimary ?? Array(repeating: blankLine(), count: rows)
            savedPrimary = nil
            cursorX = min(savedPrimaryCursor.x, cols - 1)
            cursorY = min(savedPrimaryCursor.y, rows - 1)
            isAlternateScreen = false
        }
        scrollTop = 0; scrollBottom = rows - 1
        wrapPending = false
    }

    // MARK: - CSI

    private func params() -> [Int] {
        guard !csiParams.isEmpty else { return [] }
        return String(decoding: csiParams, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.split(separator: ":").first ?? "") ?? 0 }
    }

    private func executeCSI(_ final: UInt8) {
        let p = params()
        func arg(_ i: Int, _ def: Int = 1) -> Int {
            guard i < p.count, p[i] != 0 else { return def }
            return p[i]
        }
        let c = Character(Unicode.Scalar(final))

        if csiPrivate == UInt8(ascii: "?") {
            if c == "h" || c == "l" { setPrivateModes(p, c == "h") }
            return
        }
        if csiPrivate != 0 || csiIntermediate != 0 {
            // Secondary DA (CSI > c): identify as a basic xterm.
            if csiPrivate == UInt8(ascii: ">"), c == "c" { respond(Array("\u{1B}[>0;10;0c".utf8)) }
            return
        }

        switch c {
        case "@":
            let n = min(arg(0), cols - cursorX)
            lines[cursorY].insert(contentsOf: Array(repeating: Cell(ch: " ", attr: Attr(bg: attr.bg)), count: n), at: cursorX)
            lines[cursorY].removeLast(n)
        case "A": cursorY = max(cursorY < scrollTop ? 0 : scrollTop, cursorY - arg(0)); wrapPending = false
        case "B", "e": cursorY = min(cursorY > scrollBottom ? rows - 1 : scrollBottom, cursorY + arg(0)); wrapPending = false
        case "C", "a": cursorX = min(cols - 1, cursorX + arg(0)); wrapPending = false
        case "D": cursorX = max(0, cursorX - arg(0)); wrapPending = false
        case "E": cursorX = 0; cursorY = min(rows - 1, cursorY + arg(0)); wrapPending = false
        case "F": cursorX = 0; cursorY = max(0, cursorY - arg(0)); wrapPending = false
        case "G", "`": cursorX = min(cols - 1, max(0, arg(0) - 1)); wrapPending = false
        case "H", "f":
            let top = originMode ? scrollTop : 0
            cursorY = min(rows - 1, max(0, top + arg(0) - 1))
            cursorX = min(cols - 1, max(0, arg(1) - 1))
            wrapPending = false
        case "d": cursorY = min(rows - 1, max(0, arg(0) - 1)); wrapPending = false
        case "J":
            switch arg(0, 0) {
            case 0:
                eraseInLine(from: cursorX, to: cols)
                for y in (cursorY + 1)..<rows { lines[y] = blankLine() }
            case 1:
                eraseInLine(from: 0, to: cursorX + 1)
                for y in 0..<cursorY { lines[y] = blankLine() }
            case 2: for y in 0..<rows { lines[y] = blankLine() }
            case 3: for y in 0..<rows { lines[y] = blankLine() }; scrollback.removeAll()
            default: break
            }
        case "K":
            switch arg(0, 0) {
            case 0: eraseInLine(from: cursorX, to: cols)
            case 1: eraseInLine(from: 0, to: cursorX + 1)
            case 2: eraseInLine(from: 0, to: cols)
            default: break
            }
        case "L":
            guard (scrollTop...scrollBottom).contains(cursorY) else { break }
            for _ in 0..<min(arg(0), scrollBottom - cursorY + 1) {
                lines.remove(at: scrollBottom)
                lines.insert(blankLine(), at: cursorY)
            }
            cursorX = 0
        case "M":
            guard (scrollTop...scrollBottom).contains(cursorY) else { break }
            for _ in 0..<min(arg(0), scrollBottom - cursorY + 1) {
                lines.remove(at: cursorY)
                lines.insert(blankLine(), at: scrollBottom)
            }
            cursorX = 0
        case "P":
            let n = min(arg(0), cols - cursorX)
            lines[cursorY].removeSubrange(cursorX..<(cursorX + n))
            lines[cursorY].append(contentsOf: Array(repeating: Cell(ch: " ", attr: Attr(bg: attr.bg)), count: n))
        case "X": eraseInLine(from: cursorX, to: min(cols, cursorX + arg(0)))
        case "S": scrollUp(arg(0))
        case "T": scrollDown(arg(0))
        case "m": applySGR(p)
        case "r":
            let top = arg(0) - 1, bottom = arg(1, rows) - 1
            if top < bottom, bottom < rows {
                scrollTop = max(0, top); scrollBottom = bottom
            } else {
                scrollTop = 0; scrollBottom = rows - 1
            }
            cursorX = 0; cursorY = originMode ? scrollTop : 0
        case "s": saveCursor()
        case "u": restoreCursor()
        case "n":
            if arg(0, 0) == 6 { respond(Array("\u{1B}[\(cursorY + 1);\(cursorX + 1)R".utf8)) }
            else if arg(0, 0) == 5 { respond(Array("\u{1B}[0n".utf8)) }
        case "c": respond(Array("\u{1B}[?1;2c".utf8))
        default: break
        }
    }

    private func eraseInLine(from: Int, to: Int) {
        let lo = max(0, from), hi = min(cols, to)
        guard lo < hi else { return }
        for x in lo..<hi { lines[cursorY][x] = Cell(ch: " ", attr: Attr(bg: attr.bg)) }
        wrapPending = false
    }

    private func setPrivateModes(_ p: [Int], _ on: Bool) {
        for mode in p {
            switch mode {
            case 1: appCursorKeys = on
            case 6: originMode = on; cursorX = 0; cursorY = on ? scrollTop : 0
            case 7: autowrap = on
            case 25: cursorVisible = on
            case 47, 1047: setAlternateScreen(on)
            case 1048: on ? saveCursor() : restoreCursor()
            case 1049:
                if on { saveCursor(); setAlternateScreen(true) } else { setAlternateScreen(false); restoreCursor() }
            case 1000, 1002, 1003: mouseReporting = on
            case 1006: sgrMouse = on
            case 2004: bracketedPaste = on
            default: break
            }
        }
    }

    private func applySGR(_ p: [Int]) {
        let p = p.isEmpty ? [0] : p
        var i = 0
        func extendedColor() -> TColor? {
            guard i + 1 < p.count else { return nil }
            if p[i + 1] == 5, i + 2 < p.count {
                defer { i += 2 }
                return .idx(UInt8(clamping: p[i + 2]))
            }
            if p[i + 1] == 2, i + 4 < p.count {
                defer { i += 4 }
                return .rgb(UInt8(clamping: p[i + 2]), UInt8(clamping: p[i + 3]), UInt8(clamping: p[i + 4]))
            }
            return nil
        }
        while i < p.count {
            let v = p[i]
            switch v {
            case 0: attr = Attr()
            case 1: attr.bold = true
            case 2: attr.dim = true
            case 3: attr.italic = true
            case 4: attr.underline = true
            case 7: attr.inverse = true
            case 21, 22: attr.bold = false; attr.dim = false
            case 23: attr.italic = false
            case 24: attr.underline = false
            case 27: attr.inverse = false
            case 30...37: attr.fg = .idx(UInt8(v - 30))
            case 38: if let c = extendedColor() { attr.fg = c }
            case 39: attr.fg = .def
            case 40...47: attr.bg = .idx(UInt8(v - 40))
            case 48: if let c = extendedColor() { attr.bg = c }
            case 49: attr.bg = .def
            case 90...97: attr.fg = .idx(UInt8(v - 90 + 8))
            case 100...107: attr.bg = .idx(UInt8(v - 100 + 8))
            default: break
            }
            i += 1
        }
    }

    private func handleOSC() {
        let s = String(decoding: oscBuffer, as: UTF8.self)
        oscBuffer.removeAll()
        guard let semi = s.firstIndex(of: ";") else { return }
        let code = s[..<semi]
        if code == "0" || code == "2" { title = String(s[s.index(after: semi)...]) }
    }
}
