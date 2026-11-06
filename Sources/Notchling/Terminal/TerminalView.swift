import AppKit

/// Draws a `TerminalEmulator` grid and turns key presses into bytes for the shell.
final class TerminalView: NSView {
    let emulator: TerminalEmulator
    var sendBytes: ([UInt8]) -> Void = { _ in }
    var onResize: (Int, Int) -> Void = { _, _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    var fontSize: CGFloat = 11.5 { didSet { updateFont() } }
    private var font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
    private var cellWidth: CGFloat = 7
    private var cellHeight: CGFloat = 14
    private var baselineOffset: CGFloat = 11

    /// Lines scrolled back into history (0 = live view).
    private var scrollOffset = 0
    private var scrollAccumulator: CGFloat = 0
    /// Selection in absolute line coordinates (scrollback + screen).
    private var selectionAnchor: (line: Int, col: Int)?
    private var selectionEnd: (line: Int, col: Int)?
    private var isFocused = false
    private let padding: CGFloat = 4

    init(emulator: TerminalEmulator) {
        self.emulator = emulator
        super.init(frame: .zero)
        updateFont()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        needsDisplay = true
        onFocusChange(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        needsDisplay = true
        onFocusChange(false)
        return true
    }

    private func updateFont() {
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        cellHeight = ceil(font.ascender - font.descender + font.leading) + 1
        baselineOffset = ceil(font.ascender)
        recalcGrid()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalcGrid()
    }

    private func recalcGrid() {
        guard bounds.width > 20, bounds.height > 20 else { return }
        let cols = max(10, Int((bounds.width - padding * 2) / cellWidth))
        let rows = max(3, Int((bounds.height - padding * 2) / cellHeight))
        if cols != emulator.cols || rows != emulator.rows {
            emulator.resize(cols: cols, rows: rows)
            onResize(cols, rows)
        }
    }

    func outputArrived() {
        scrollOffset = 0
        selectionAnchor = nil; selectionEnd = nil
        needsDisplay = true
    }

    // MARK: Drawing

    private var allLineCount: Int { emulator.scrollback.count + emulator.rows }

    private func line(atAbsolute index: Int) -> [TerminalEmulator.Cell]? {
        let sb = emulator.scrollback.count
        if index < sb { return emulator.scrollback[index] }
        let i = index - sb
        return i < emulator.lines.count ? emulator.lines[i] : nil
    }

    private var topAbsoluteLine: Int { emulator.scrollback.count - scrollOffset }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let top = topAbsoluteLine
        for row in 0..<emulator.rows {
            guard let cells = line(atAbsolute: top + row) else { continue }
            let y = padding + CGFloat(row) * cellHeight
            drawRow(cells, absoluteLine: top + row, y: y)
        }

        // Cursor
        if emulator.cursorVisible, scrollOffset == 0 {
            let x = padding + CGFloat(emulator.cursorX) * cellWidth
            let y = padding + CGFloat(emulator.cursorY) * cellHeight
            let rect = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
            if isFocused {
                NSColor.white.withAlphaComponent(0.75).setFill()
                rect.fill()
                let cell = emulator.lines[emulator.cursorY][min(emulator.cursorX, emulator.cols - 1)]
                if cell.ch != " " {
                    NSAttributedString(string: String(cell.ch), attributes: [.font: font, .foregroundColor: NSColor.black])
                        .draw(at: NSPoint(x: x, y: y + baselineOffset - font.ascender))
                }
            } else {
                NSColor.white.withAlphaComponent(0.5).setStroke()
                NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }

        if scrollOffset > 0 {
            let label = NSAttributedString(string: " ↑ \(scrollOffset) lines — type to return ",
                                           attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                        .foregroundColor: NSColor.black,
                                                        .backgroundColor: NSColor.systemYellow])
            label.draw(at: NSPoint(x: bounds.width - label.size().width - 6, y: 4))
        }
    }

    private func drawRow(_ cells: [TerminalEmulator.Cell], absoluteLine: Int, y: CGFloat) {
        let selected = selectionRange(forLine: absoluteLine)
        var col = 0
        while col < cells.count {
            // Group a run of cells sharing attributes (ASCII only, so widths are exact).
            let start = col
            let attr = cells[col].attr
            let isSel = selected?.contains(col) ?? false
            var text = ""
            while col < cells.count, cells[col].attr == attr, (selected?.contains(col) ?? false) == isSel {
                let cell = cells[col]
                if !cell.isWideTail {
                    if cell.ch.isASCII || text.isEmpty { text.append(cell.ch) } else { break }
                }
                col += 1
                if !cell.ch.isASCII { break }
            }
            if col == start { col += 1 }

            var (fg, bg) = colors(for: attr)
            if isSel { bg = NSColor.selectedTextBackgroundColor; fg = .white }
            let x = padding + CGFloat(start) * cellWidth
            let width = CGFloat(col - start) * cellWidth
            if let bg {
                bg.setFill()
                NSRect(x: x, y: y, width: width, height: cellHeight).fill()
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                var attrs: [NSAttributedString.Key: Any] = [.font: attr.bold ? boldFont : font, .foregroundColor: fg]
                if attr.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if attr.italic { attrs[.obliqueness] = 0.15 }
                NSAttributedString(string: text, attributes: attrs)
                    .draw(at: NSPoint(x: x, y: y + baselineOffset - font.ascender))
            }
        }
    }

    private func colors(for attr: TerminalEmulator.Attr) -> (NSColor, NSColor?) {
        var fg = color(attr.fg, isForeground: true, bold: attr.bold) ?? NSColor(white: 0.92, alpha: 1)
        var bg = color(attr.bg, isForeground: false, bold: false)
        if attr.inverse {
            let oldFg = fg
            fg = bg ?? .black
            bg = oldFg
        }
        if attr.dim { fg = fg.withAlphaComponent(0.6) }
        return (fg, bg)
    }

    private static let palette: [NSColor] = {
        let base: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0), (0.80, 0.24, 0.24), (0.36, 0.76, 0.33), (0.85, 0.75, 0.30),
            (0.30, 0.52, 0.90), (0.74, 0.40, 0.85), (0.30, 0.75, 0.80), (0.82, 0.82, 0.82),
            (0.45, 0.45, 0.45), (1.0, 0.42, 0.42), (0.52, 0.92, 0.48), (1.0, 0.92, 0.45),
            (0.48, 0.68, 1.0), (0.90, 0.55, 1.0), (0.45, 0.92, 0.95), (1, 1, 1),
        ]
        var colors = base.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        let steps: [CGFloat] = [0, 95, 135, 175, 215, 255].map { $0 / 255 }
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
            colors.append(NSColor(srgbRed: steps[r], green: steps[g], blue: steps[b], alpha: 1))
        } } }
        for i in 0..<24 {
            let v = CGFloat(8 + i * 10) / 255
            colors.append(NSColor(srgbRed: v, green: v, blue: v, alpha: 1))
        }
        return colors
    }()

    private func color(_ c: TerminalEmulator.TColor, isForeground: Bool, bold: Bool) -> NSColor? {
        switch c {
        case .def: return nil
        case .idx(let i):
            let index = (bold && isForeground && i < 8) ? Int(i) + 8 : Int(i)
            return Self.palette[index]
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    // MARK: Selection

    private func selectionRange(forLine line: Int) -> Range<Int>? {
        guard let a = selectionAnchor, let b = selectionEnd else { return nil }
        let (s, e) = (a.line, a.col) <= (b.line, b.col) ? (a, b) : (b, a)
        guard line >= s.line, line <= e.line else { return nil }
        let from = line == s.line ? s.col : 0
        let to = line == e.line ? e.col + 1 : emulator.cols
        return from < to ? from..<to : nil
    }

    private func cellPosition(_ event: NSEvent) -> (line: Int, col: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let row = max(0, min(emulator.rows - 1, Int((p.y - padding) / cellHeight)))
        let col = max(0, min(emulator.cols - 1, Int((p.x - padding) / cellWidth)))
        return (topAbsoluteLine + row, col)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectionAnchor = cellPosition(event)
        selectionEnd = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        selectionEnd = cellPosition(event)
        needsDisplay = true
    }

    private func selectedText() -> String? {
        guard let a = selectionAnchor, let b = selectionEnd else { return nil }
        let (s, e) = (a.line, a.col) <= (b.line, b.col) ? (a, b) : (b, a)
        var out: [String] = []
        for l in s.line...e.line {
            guard let cells = line(atAbsolute: l) else { continue }
            let from = l == s.line ? s.col : 0
            let to = l == e.line ? e.col + 1 : cells.count
            out.append(TerminalEmulator.text(of: cells, from: from, to: to))
        }
        return out.joined(separator: "\n")
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard !emulator.isAlternateScreen else {
            // Full-screen apps get arrow keys instead, like Terminal.app.
            let lines = Int(abs(event.scrollingDeltaY) / 6)
            if lines > 0 {
                let key = event.scrollingDeltaY > 0 ? "A" : "B"
                let prefix = emulator.appCursorKeys ? "\u{1B}O" : "\u{1B}["
                sendBytes(Array(String(repeating: prefix + key, count: min(lines, 5)).utf8))
            }
            return
        }
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY
        let delta = Int(scrollAccumulator)
        guard delta != 0 else { return }
        scrollAccumulator -= CGFloat(delta)
        scrollOffset = max(0, min(emulator.scrollback.count, scrollOffset + delta))
        needsDisplay = true
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": paste(nil); return true
        case "c":
            if let text = selectedText(), !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        case "k":
            emulator.clearScrollback()
            sendBytes([0x0C])   // Ctrl-L redraws the prompt
            return true
        case "=", "+": fontSize = min(20, fontSize + 1); return true
        case "-": fontSize = max(9, fontSize - 1); return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if emulator.bracketedPaste { text = "\u{1B}[200~" + text + "\u{1B}[201~" }
        sendBytes(Array(text.utf8))
    }

    override func keyDown(with event: NSEvent) {
        if scrollOffset != 0 { scrollOffset = 0; needsDisplay = true }
        let mods = event.modifierFlags
        let esc = "\u{1B}"
        let arrowPrefix = emulator.appCursorKeys ? esc + "O" : esc + "["

        var seq: String?
        switch event.keyCode {
        case 126: seq = arrowPrefix + "A"
        case 125: seq = arrowPrefix + "B"
        case 124: seq = mods.contains(.option) ? esc + "f" : mods.contains(.command) ? "\u{05}" : arrowPrefix + "C"
        case 123: seq = mods.contains(.option) ? esc + "b" : mods.contains(.command) ? "\u{01}" : arrowPrefix + "D"
        case 115: seq = esc + "[H"
        case 119: seq = esc + "[F"
        case 116: seq = esc + "[5~"
        case 121: seq = esc + "[6~"
        case 117: seq = esc + "[3~"
        case 51: seq = mods.contains(.option) ? esc + "\u{7F}" : mods.contains(.command) ? "\u{15}" : "\u{7F}"
        case 36, 76: seq = "\r"
        case 48: seq = mods.contains(.shift) ? esc + "[Z" : "\t"
        case 53: seq = esc
        case 122: seq = esc + "OP"
        case 120: seq = esc + "OQ"
        case 99: seq = esc + "OR"
        case 118: seq = esc + "OS"
        default: break
        }
        if let seq { sendBytes(Array(seq.utf8)); return }

        if mods.contains(.control), let raw = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            // Ctrl-letter → control code (works regardless of keyboard layout quirks).
            if raw.value >= 0x61 && raw.value <= 0x7A { sendBytes([UInt8(raw.value - 0x60)]); return }
            switch raw {
            case "@", " ", "2": sendBytes([0x00]); return
            case "[": sendBytes([0x1B]); return
            case "\\": sendBytes([0x1C]); return
            case "]": sendBytes([0x1D]); return
            default: break
            }
        }
        if let chars = event.characters, !chars.isEmpty {
            sendBytes(Array(chars.utf8))
        }
    }
}
