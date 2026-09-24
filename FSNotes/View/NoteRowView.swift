//
//  NoteRowView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/31/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class NoteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        TUIRowSelection.draw(in: bounds, emphasized: isEmphasized)
    }

    // Keep the regular text colours on the tinted TUI selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return .normal
    }

    // Rows are separated by spacing, not rules.
    override func drawSeparator(in dirtyRect: NSRect) {}
}
