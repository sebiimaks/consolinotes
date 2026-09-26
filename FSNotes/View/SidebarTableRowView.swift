//
//  SidebarTableRowView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 4/11/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class SidebarTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        TUIRowSelection.draw(in: bounds, emphasized: isEmphasized)
    }

    // Keep the regular text colours on the tinted TUI selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return .normal
    }
}

/// Selected row in a list, drawn like Vim's cursorline: a full-width tinted band.
enum TUIRowSelection {
    static func draw(in rect: NSRect, emphasized: Bool) {
        (emphasized ? TUITheme.selection : TUITheme.selectionInactive).setFill()
        rect.fill()
    }
}
