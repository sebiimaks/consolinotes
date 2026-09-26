//
//  TUIBars.swift
//  FSNotes
//
//  Window chrome for the Vim modal look: a tabline under the traffic lights, a statusline
//  at the foot of each window (library, notes, editor) and a command line at the bottom.
//

import Cocoa

typealias TUISegment = (text: String, color: NSColor)

/// The mode shown in the focused window's statusline, derived from what has keyboard focus.
enum VimMode {
    case normal, insert, preview, command

    var label: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .preview: return "PREVIEW"
        case .command: return "COMMAND"
        }
    }

    var color: NSColor {
        switch self {
        case .normal: return TUITheme.accent
        case .insert: return TUITheme.green
        case .preview: return TUITheme.magenta
        case .command: return TUITheme.yellow
        }
    }
}

/// Tabs across the top of the window, one per open note. Moves the window like a title bar.
final class VimTabLine: NSView {
    static let height: CGFloat = 28
    /// Room for the traffic lights.
    static let leadingInset: CGFloat = 78

    var tabs: [String] = [] {
        didSet { if tabs != oldValue { needsDisplay = true } }
    }

    /// The tab for this window's note.
    var activeIndex = 0 {
        didSet { if activeIndex != oldValue { needsDisplay = true } }
    }

    var rightText = "consolinotes" {
        didSet { if rightText != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool {
        return true
    }

    override var mouseDownCanMoveWindow: Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2,
              let action = UserDefaults.standard.object(forKey: "AppleActionOnDoubleClick") as? String else {
            super.mouseDown(with: event)
            return
        }

        switch action {
        case "Maximize":
            window?.windowController?.maximizeWindow()
        case "Minimize":
            window?.performMiniaturize(nil)
        default:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        TUITheme.bar.setFill()
        bounds.fill()

        let font = TUITheme.font(ofSize: 12)
        let bold = TUITheme.font(ofSize: 12, weight: .semibold)
        var x = Self.leadingInset

        // The first tab is the main window's note; the rest are separate note windows.
        for (index, tab) in tabs.enumerated() {
            let label = " \(index + 1) \(tab) "
            let isActive = index == activeIndex
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isActive ? bold : font,
                .foregroundColor: isActive ? TUITheme.bright : TUITheme.dim
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            let rect = NSRect(x: x, y: 0, width: ceil(size.width), height: bounds.height)

            if isActive {
                TUITheme.background.setFill()
                rect.fill()
            }

            (label as NSString).draw(at: NSPoint(x: x, y: floor((bounds.height - size.height) / 2)), withAttributes: attributes)
            x = rect.maxX

            if !isActive && index + 1 != activeIndex && index < tabs.count - 1 {
                x = TUIText.draw([("│", TUITheme.border)], at: x, centerY: bounds.midY, font: font)
            }
        }

        TUIText.draw([(rightText, TUITheme.dim)], trailingAt: bounds.maxX - 10, centerY: bounds.midY, font: font)
    }
}

/// A window's statusline. The focused window shows its mode as a coloured segment.
final class VimStatusLine: NSView {
    static let height: CGFloat = 20

    var mode: VimMode? {
        didSet { if mode != oldValue { needsDisplay = true } }
    }

    var name = "" {
        didSet { if name != oldValue { needsDisplay = true } }
    }

    var flags = "" {
        didSet { if flags != oldValue { needsDisplay = true } }
    }

    var right: [String] = [] {
        didSet { if right != oldValue { needsDisplay = true } }
    }

    /// Shown at the right end in the mode colour, like Vim's ruler.
    var position = "" {
        didSet { if position != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool {
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let isActive = mode != nil
        (isActive ? TUITheme.statusLine : TUITheme.bar).setFill()
        bounds.fill()

        let font = TUITheme.font(ofSize: 12)
        let bold = TUITheme.font(ofSize: 12, weight: .bold)
        let midY = bounds.midY
        var x: CGFloat = 0

        if let mode = mode {
            let label = " \(mode.label) "
            let width = ceil((label as NSString).size(withAttributes: [.font: bold]).width)
            mode.color.setFill()
            NSRect(x: 0, y: 0, width: width, height: bounds.height).fill()
            TUIText.draw([(label, TUITheme.background)], at: 0, centerY: midY, font: bold)
            x = width
            drawTriangle(at: x, pointingRight: true, color: mode.color)
            x += bounds.height / 2
        }

        x = TUIText.draw([(" " + name, isActive ? TUITheme.text : TUITheme.dim)], at: x, centerY: midY, font: font)

        if !flags.isEmpty {
            TUIText.draw([(" " + flags, TUITheme.dim)], at: x, centerY: midY, font: font)
        }

        var maxX = bounds.maxX

        if let mode = mode, !position.isEmpty {
            let label = " \(position) "
            let width = ceil((label as NSString).size(withAttributes: [.font: bold]).width)
            mode.color.setFill()
            NSRect(x: maxX - width, y: 0, width: width, height: bounds.height).fill()
            TUIText.draw([(label, TUITheme.background)], at: maxX - width, centerY: midY, font: bold)
            maxX -= width
            drawTriangle(at: maxX, pointingRight: false, color: mode.color)
            maxX -= bounds.height / 2
        }

        if !right.isEmpty {
            let text = right.joined(separator: " │ ")
            TUIText.draw([(text, TUITheme.dim)], trailingAt: maxX - 8, centerY: midY, font: font)
        }
    }

    /// Powerline-style separator between the mode segment and the rest of the line.
    private func drawTriangle(at x: CGFloat, pointingRight: Bool, color: NSColor) {
        let width = bounds.height / 2
        let path = NSBezierPath()

        if pointingRight {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + width, y: bounds.midY))
            path.line(to: NSPoint(x: x, y: bounds.height))
        } else {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x - width, y: bounds.midY))
            path.line(to: NSPoint(x: x, y: bounds.height))
        }

        path.close()
        color.setFill()
        path.fill()
    }
}

/// The command line at the bottom of the window: mode messages, the search prompt, file info.
final class VimCommandLine: NSView {
    static let height: CGFloat = 20

    var message: [TUISegment] = [] {
        didSet { needsDisplay = true }
    }

    var right: [TUISegment] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        TUITheme.background.setFill()
        bounds.fill()

        let font = TUITheme.font(ofSize: 12)
        TUIText.draw(message, at: 6, centerY: bounds.midY, font: font)
        TUIText.draw(right, trailingAt: bounds.maxX - 10, centerY: bounds.midY, font: font)
    }
}

/// A plain filled rectangle that follows light and dark mode, for input strips.
final class TUIFillView: NSView {
    var color: NSColor = TUITheme.input {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

/// Draws runs of coloured monospace text on one line.
enum TUIText {
    @discardableResult
    static func draw(_ segments: [TUISegment], at x: CGFloat, centerY: CGFloat, font: NSFont) -> CGFloat {
        var x = x

        for segment in segments {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: segment.color]
            let text = segment.text as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: x, y: floor(centerY - size.height / 2)), withAttributes: attributes)
            x += size.width
        }

        return x
    }

    static func draw(_ segments: [TUISegment], trailingAt maxX: CGFloat, centerY: CGFloat, font: NSFont) {
        let width = segments.reduce(CGFloat(0)) {
            $0 + ($1.text as NSString).size(withAttributes: [.font: font]).width
        }
        draw(segments, at: maxX - width, centerY: centerY, font: font)
    }
}
