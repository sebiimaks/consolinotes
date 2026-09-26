//
//  SettingsFilesNaming.swift
//  FSNotesCore
//
//  Created by Олександр Глущенко on 19.06.2020.
//  Copyright © 2020 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

enum SettingsFilesNaming: Int {
    case uuid
    case autoRename
    case untitledNote
    case date
    case altDate
    case autoRenameNew
    case compactDate
    case compactDateMinutes
    case compactDateSeconds

    public var tag: Int {
        switch self {
        case .uuid: return 0x00
        case .autoRename: return 0x01
        case .untitledNote: return 0x02
        case .date: return 0x03
        case .altDate: return 0x04
        case .autoRenameNew: return 0x05
        case .compactDate: return 0x06
        case .compactDateMinutes: return 0x07
        case .compactDateSeconds: return 0x08
        }
    }

    public func getName() -> String {
        switch self {
        case .uuid, .autoRename, .autoRenameNew:
            return UUID().uuidString
        case .untitledNote:
            return "Untitled Note"
        case .date:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMddHHmmss"
            return formatter.string(from: Date())
        case .altDate:
            let dateFromatter = DateFormatter()
            dateFromatter.amSymbol = "AM"
            dateFromatter.pmSymbol = "PM"

            dateFromatter.dateFormat = "yyyy-MM-dd hh.mm.ss a"
            let date = dateFromatter.string(from: Date())
            return date
        case .compactDate, .compactDateMinutes, .compactDateSeconds:
            let formatter = DateFormatter()
            // Fixed Gregorian digits, whatever the system calendar and locale.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = dateFormat
            return formatter.string(from: Date())
        }
    }

    /// These formats number clashes as `_001`, `_002` and so on instead of appending a space and a digit.
    public var usesSequenceSuffix: Bool {
        return [.compactDate, .compactDateMinutes, .compactDateSeconds].contains(self)
    }

    private var dateFormat: String {
        switch self {
        case .compactDateMinutes: return "yyyyMMdd_HHmm"
        case .compactDateSeconds: return "yyyyMMdd_HHmmss"
        default: return "yyyyMMdd"
        }
    }
}
