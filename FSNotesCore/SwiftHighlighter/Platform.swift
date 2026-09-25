//
//  PlatformColor.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 14.11.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import AppKit

public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias FontTraits = NSFontDescriptor.SymbolicTraits

extension PlatformColor {
    convenience init(hex: String) {
        let trimHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexString: String
        if trimHex.hasPrefix("#") {
            hexString = String(trimHex.dropFirst())
        } else {
            hexString = trimHex
        }

        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)

        let r, g, b, a: CGFloat

        switch hexString.count {
        case 6: // RRGGBB
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1.0
        case 8: // RRGGBBAA
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        default:
            // Некорректный формат — делаем черный цвет
            r = 0; g = 0; b = 0; a = 1
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }

    public static var label: PlatformColor {
        return NSColor.lightGray
    }
}

extension PlatformFont {
    static func withTraits(font: PlatformFont, traits: FontTraits) -> PlatformFont {
        let manager = NSFontManager.shared
        var desiredTraits: NSFontTraitMask = []

        if traits.contains(.bold) {
            desiredTraits.insert(.boldFontMask)
        }

        if traits.contains(.italic) {
            desiredTraits.insert(.italicFontMask)
        }

        return manager.convert(font, toHaveTrait: desiredTraits)
    }
}
