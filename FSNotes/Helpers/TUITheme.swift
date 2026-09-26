//
//  TUITheme.swift
//  FSNotes
//
//  Vim modal look: one palette and one monospace type scale for the whole window.
//  Colours live in Images.xcassets/TUI so light and dark variants resolve per appearance.
//

import Cocoa

enum TUITheme {
    // MARK: - Palette

    static var background: NSColor { named("tuiBackground") }
    static var bar: NSColor { named("tuiBar") }
    static var text: NSColor { named("tuiText") }
    static var bright: NSColor { named("tuiBright") }
    static var dim: NSColor { named("tuiDim") }
    static var faint: NSColor { named("tuiFaint") }
    static var border: NSColor { named("tuiBorder") }
    static var accent: NSColor { named("tuiAccent") }
    static var selection: NSColor { named("tuiSelection") }
    static var selectionInactive: NSColor { named("tuiSelectionInactive") }
    static var input: NSColor { named("tuiInput") }
    static var code: NSColor { named("tuiCode") }
    static var green: NSColor { named("tuiGreen") }
    static var yellow: NSColor { named("tuiYellow") }
    static var red: NSColor { named("tuiRed") }
    static var magenta: NSColor { named("tuiMagenta") }
    static var cyan: NSColor { named("tuiCyan") }
    static var orange: NSColor { named("tuiOrange") }
    static var statusLine: NSColor { named("tuiStatusLine") }
    static var cursorLine: NSColor { named("tuiCursorLine") }
    static var lineNumber: NSColor { named("tuiLineNumber") }

    // MARK: - Type

    static let baseSize: CGFloat = 13

    /// Bundled in Resources/Fonts/JetBrainsMono (SIL OFL 1.1) and registered through ATSApplicationFontsPath.
    static let familyName = "JetBrains Mono"

    static func font(ofSize size: CGFloat = baseSize, weight: NSFont.Weight = .regular) -> NSFont {
        if let font = NSFont(name: postScriptName(for: weight), size: size) {
            return font
        }

        if #available(macOS 10.15, *) {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }

        return NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Width of one character cell, used to lay text out on a grid.
    static func cellWidth(for font: NSFont) -> CGFloat {
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - Glyph images
    // Text drawn into images, so places that expect an icon show terminal glyphs instead.
    // Drawing happens on demand, so dynamic colours follow light and dark mode.

    /// A single glyph centred in a square, for icon slots (sidebar, badges, disclosure).
    static func glyph(_ text: String, color: NSColor, size: CGFloat = 16, fontSize: CGFloat? = nil,
                      weight: NSFont.Weight = .regular) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(ofSize: fontSize ?? round(size * 0.82), weight: weight),
                .foregroundColor: color
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A text label like ":share" on the winbar, for image-only buttons.
    static func chip(_ text: String, color: NSColor = dim, background: NSColor = .clear) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(ofSize: 12), .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)

        let image = NSImage(size: size, flipped: false) { rect in
            background.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 6, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Winbar lock chip naming the command the button runs next. Labels share one width, so the button never resizes.
    static func lockChip(encrypted: Bool, locked: Bool) -> NSImage {
        if !encrypted {
            return chip(":encrypt")
        }

        return locked ? chip(":unlock ", color: magenta) : chip(":lock   ", color: magenta)
    }

    // MARK: - Private

    private static func postScriptName(for weight: NSFont.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black:
            return "JetBrainsMono-Bold"
        case .semibold:
            return "JetBrainsMono-SemiBold"
        case .medium:
            return "JetBrainsMono-Medium"
        default:
            return "JetBrainsMono-Regular"
        }
    }

    private static func named(_ name: String) -> NSColor {
        return NSColor(named: name) ?? .labelColor
    }
}

extension Notification.Name {
    /// Posted by MainWindow whenever its first responder changes, so panes can redraw their focus state.
    static let tuiFirstResponderDidChange = Notification.Name("TUIFirstResponderDidChange")
}
