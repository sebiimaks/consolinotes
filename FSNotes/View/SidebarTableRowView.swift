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

/// Selected row in a TUI list: a tinted band with an accent bar on the left edge.
enum TUIRowSelection {
    static func draw(in rect: NSRect, emphasized: Bool) {
        (emphasized ? TUITheme.selection : TUITheme.selectionInactive).setFill()
        rect.fill()

        TUITheme.accent.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
    }
}
