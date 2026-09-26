//
//  NSPasteboard+.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 25.09.2020.
//  Copyright © 2020 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

extension NSPasteboard {
    // Notes and folders dragged within consolinotes. Distinct from FSNotes, so a drag from FSNotes isn't taken for one of ours.
    public static var note: NSPasteboard.PasteboardType {
        .init("io.github.sebiimaks.consolinotes.pasteboard.note")
    }

    public static var project: NSPasteboard.PasteboardType {
        .init("io.github.sebiimaks.consolinotes.pasteboard.project")
    }

    // Rich text in the same format FSNotes uses, so pasting from FSNotes keeps images and attachments.
    public static var attributed: NSPasteboard.PasteboardType {
        .init("es.fsnot.pasteboard.attributed")
    }
}
