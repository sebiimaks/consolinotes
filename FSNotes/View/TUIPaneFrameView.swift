//
//  TUIPaneFrameView.swift
//  FSNotes
//
//  Box-drawn pane border with "[n]─Title" in the top edge and optional footers in the
//  bottom edge. It sits above a pane's content and lets every click through.
//

import Cocoa

final class TUIPaneFrameView: NSView {
    /// Distance from the top of the view to the top border line.
    static let topLineInset: CGFloat = 9
    /// Distance from the bottom of the view to the bottom border line.
    static let bottomLineInset: CGFloat = 8
    /// Space content should keep clear at the top so it sits below the title.
    static let contentTop: CGFloat = 22
    /// Space content should keep clear at the bottom so it sits above the footer.
    static let contentBottom: CGFloat = 16

    var number: Int? {
        didSet { needsDisplay = true }
    }

    var title = "" {
        didSet { if title != oldValue { needsDisplay = true } }
    }

    var trailingTitle: String? {
        didSet { if trailingTitle != oldValue { needsDisplay = true } }
    }

    var footer: String? {
        didSet { if footer != oldValue { needsDisplay = true } }
    }

    var trailingFooter: String? {
        didSet { if trailingFooter != oldValue { needsDisplay = true } }
    }

    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineColor = isFocused ? TUITheme.accent : TUITheme.border
        let top = Self.topLineInset + 0.5
        let bottom = bounds.maxY - Self.bottomLineInset - 0.5
        let rect = NSRect(x: 0.5, y: top, width: bounds.width - 1, height: max(0, bottom - top))

        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        path.lineWidth = 1
        lineColor.setStroke()
        path.stroke()

        let regular = TUITheme.font(ofSize: 12)
        let emphasis = TUITheme.font(ofSize: 12, weight: .semibold)
        let gap = TUITheme.cellWidth(for: regular)
        var x: CGFloat = 8

        if let number = number {
            x = drawLabel("[\(number)]", at: x, lineY: top, font: emphasis,
                          color: isFocused ? TUITheme.accent : TUITheme.faint) + gap
        }

        if !title.isEmpty {
            drawLabel(title, at: x, lineY: top, font: isFocused ? emphasis : regular,
                      color: isFocused ? TUITheme.accent : TUITheme.dim)
        }

        if let trailingTitle = trailingTitle, !trailingTitle.isEmpty {
            drawLabel(trailingTitle, trailingAt: bounds.maxX - 8, lineY: top, font: regular, color: TUITheme.dim)
        }

        if let footer = footer, !footer.isEmpty {
            drawLabel(footer, at: 8, lineY: bottom, font: regular, color: TUITheme.dim)
        }

        if let trailingFooter = trailingFooter, !trailingFooter.isEmpty {
            drawLabel(trailingFooter, trailingAt: bounds.maxX - 8, lineY: bottom, font: regular, color: TUITheme.dim)
        }
    }

    // MARK: - Labels in the border

    /// Draws text centred on a border line, knocking the line out behind it. Returns the end x.
    @discardableResult
    private func drawLabel(_ text: String, at x: CGFloat, lineY: CGFloat, font: NSFont, color: NSColor) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: x, y: floor(lineY - size.height / 2))

        TUITheme.background.setFill()
        NSRect(x: x - 3, y: origin.y, width: size.width + 6, height: size.height).fill()
        (text as NSString).draw(at: origin, withAttributes: attributes)

        return x + size.width
    }

    private func drawLabel(_ text: String, trailingAt maxX: CGFloat, lineY: CGFloat, font: NSFont, color: NSColor) {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        drawLabel(text, at: maxX - width, lineY: lineY, font: font, color: color)
    }
}
