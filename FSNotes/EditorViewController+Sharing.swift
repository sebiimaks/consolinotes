//
//  EditorViewController+Sharing.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 03.07.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

extension EditorViewController: NSSharingServicePickerDelegate {
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        var share = proposedServices

        if #available(macOS 11.0, *) {
            guard let image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: nil) else {
                
                return proposedServices
            }

            let titlePlain = NSLocalizedString("Copy Plain Text", comment: "")
            let plainText = NSSharingService(title: titlePlain, image: image, alternateImage: image, handler: {
                self.saveTextAtClipboard()
            })
            share.insert(plainText, at: 0)

            let titleHTML = NSLocalizedString("Copy HTML", comment: "")
            let html = NSSharingService(title: titleHTML, image: image, alternateImage: image, handler: {
                self.saveHtmlAtClipboard()
            })
            share.insert(html, at: 1)
        }
        
        return share
    }
    
    //MARK: Share Service
        
    public func saveTextAtClipboard() {
        if let note = vcEditor?.note {
            let unloadedText = note.content.unloadTasks()
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
            pasteboard.setString(unloadedText.string, forType: NSPasteboard.PasteboardType.string)
        }
    }
    
    public func saveHtmlAtClipboard() {
        if let note = vcEditor?.note {
            let unloadedText = note.content.unloadTasks()
            if let render = renderMarkdownHTML(markdown: unloadedText.string) {
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
                pasteboard.setString(render, forType: NSPasteboard.PasteboardType.string)
            }
        }
    }
}
