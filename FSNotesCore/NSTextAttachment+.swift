//
//  NSTextAttachment+.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 10/2/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import AppKit

import UniformTypeIdentifiers

extension NSTextAttachment {
    public func isFile() -> Bool {

            return (attachmentCell?.cellSize().height == 30)
    }
}
