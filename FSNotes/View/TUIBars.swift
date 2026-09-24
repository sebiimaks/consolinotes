//
//  TUIBars.swift
//  FSNotes
//
//  Window-wide chrome for the Modern TUI look: a title strip under the traffic lights
//  and a two-row footer with key hints and status.
//

import Cocoa

typealias TUISegment = (text: String, color: NSColor)

/// Strip across the top of the window. Shows the window title and moves the window like a title bar.
final class TUITitleStrip: NSView {
    static let height: CGFloat = 28

    var title = "consolinotes" {
        didSet { if title != oldValue { needsDisplay = true } }
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
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TUITheme.dim]
        let size = (title as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2))
        (title as NSString).draw(at: origin, withAttributes: attributes)

        let hint: [TUISegment] = [("⌘L", TUITheme.accent), (" search or create", TUITheme.dim)]
        TUIText.draw(hint, trailingAt: bounds.maxX - 10, centerY: bounds.midY, font: font)
    }
}

/// Footer with a row of key hints and a status row underneath.
final class TUIStatusBar: NSView {
    static let rowHeight: CGFloat = 20
    static let height: CGFloat = rowHeight * 2

    var hints: [(key: String, label: String)] = [] {
        didSet { needsDisplay = true }
    }

    var statusLeft: [TUISegment] = [] {
        didSet { needsDisplay = true }
    }

    var statusRight: [TUISegment] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight = Self.rowHeight
        let hintsRow = NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
        let statusRow = NSRect(x: 0, y: rowHeight, width: bounds.width, height: rowHeight)

        TUITheme.background.setFill()
        hintsRow.fill()
        TUITheme.bar.setFill()
        statusRow.fill()

        let font = TUITheme.font(ofSize: 12)
        let keyFont = TUITheme.font(ofSize: 12, weight: .semibold)
        let gap = TUITheme.cellWidth(for: font)
        var x: CGFloat = 10

        for hint in hints {
            let key = hint.key as NSString
            let label = hint.label as NSString
            let keyWidth = key.size(withAttributes: [.font: keyFont]).width
            let labelWidth = label.size(withAttributes: [.font: font]).width

            // Only show hints that fit completely.
            if x + keyWidth + gap + labelWidth > bounds.maxX - 10 {
                break
            }

            x = TUIText.draw([(hint.key, TUITheme.accent)], at: x, centerY: hintsRow.midY, font: keyFont) + gap
            x = TUIText.draw([(hint.label, TUITheme.dim)], at: x, centerY: hintsRow.midY, font: font) + gap * 3
        }

        TUIText.draw(statusLeft, at: 10, centerY: statusRow.midY, font: font)
        TUIText.draw(statusRight, trailingAt: bounds.maxX - 10, centerY: statusRow.midY, font: font)
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
