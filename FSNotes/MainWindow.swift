//
//  MainWindow.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 11/2/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class MainWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        NotificationCenter.default.post(name: .tuiFirstResponderDidChange, object: self)
        return result
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        backgroundColor = TUITheme.background

        guard UserDefaults.standard.object(forKey: "NSWindow Frame myMainWindow") == nil else { return }

        if let screenHeight = NSScreen.main?.frame.height, let screenWidth = NSScreen.main?.frame.width {
            let frame = self.frame
            let x = (screenWidth - frame.width) / 2
            let rect = NSRect(x: x, y: frame.origin.y, width: frame.width, height: screenHeight)
            self.setFrame(rect, display: true)
        }
    }
}
