//
//  ClickableTextField.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 13.08.2024.
//  Copyright © 2024 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

class ClickableTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        
        guard let vc = ViewController.shared(),
            let projects = vc.sidebarOutlineView.getSelectedProjects() else { return }

        vc.getMasterPassword(allowPIV: false) { password in
            vc.sidebarOutlineView.unlock(projects: projects, password: password, action: nil)
        }
    }
}
