//
//  NSPasteboard+.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 25.09.2020.
//  Copyright © 2020 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

extension NSPasteboard {
    public static var note: NSPasteboard.PasteboardType {
        .init("es.fsnot.pasteboard.note")
    }

    public static var project: NSPasteboard.PasteboardType {
        .init("es.fsnot.pasteboard.project")
    }

    public static var attributed: NSPasteboard.PasteboardType {
        .init("es.fsnot.pasteboard.attributed")
    }
}
