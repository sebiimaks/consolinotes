//
//  AppDelegate+URLRoutes.swift
//  FSNotes
//
//  Created by Jeff Hanbury on 13/04/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation
import Cocoa


extension AppDelegate {
    
    enum HandledSchemes: String {
        case consolinotes = "consolinotes"
        case fsnotes = "fsnotes"
        case nv = "nv"
        case nvALT = "nvalt"
        case file = "file"
    }
    
    enum FSNotesRoutes: String {
        case find = "find"
        case open = "open"
    }
    
    enum NvALTRoutes: String {
        case find = "find"
        case blank = ""
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard var url = urls.first,
            let scheme = url.scheme
            else { return }

        let path = url.absoluteString.escapePlus()
        if let escaped = URL(string: path) {
            url = escaped
        }

        switch scheme {
        case HandledSchemes.file.rawValue:
            if nil != ViewController.shared() {
                self.importNotes(urls: urls)
            } else {
                self.urls = urls
            }
        case HandledSchemes.consolinotes.rawValue,
             HandledSchemes.fsnotes.rawValue:
            FSNotesRouter(url)
        case HandledSchemes.nv.rawValue,
             HandledSchemes.nvALT.rawValue:
            NvALTRouter(url)
        default:
            break
        }
    }

    /// Opens a note or tag link in this running copy of the app instead of asking Launch Services,
    /// which could pick another installed copy, or FSNotes itself for fsnotes:// links.
    @discardableResult
    static func openAppLink(_ url: URL) -> Bool {
        guard AppLink.isAppLink(url), let delegate = NSApp.delegate as? AppDelegate else { return false }

        delegate.application(NSApp, open: [url])
        return true
    }

    func importNotes(urls: [URL]) {
        guard let vc = ViewController.shared() else { return }

        var importedNote: Note? = nil
        var sidebarIndex: Int? = nil

        for url in urls {
            if let items = vc.sidebarOutlineView.sidebarItems, let note = Storage.shared().getBy(url: url) {
                if let sidebarItem = items.first(where: { ($0 as? SidebarItem)?.project == note.project || $0 as? Project == note.project }) {
                    sidebarIndex = vc.sidebarOutlineView.row(forItem: sidebarItem)
                    importedNote = note
                }
            } else if let project = Storage.shared().getDefault() {
                let newUrl = vc.copy(project: project, url: url)

                UserDataService.instance.focusOnImport = newUrl
                UserDataService.instance.skipSidebarSelection = true
            }
        }

        if let note = importedNote, let si = sidebarIndex {
            vc.sidebarOutlineView.selectRowIndexes([si], byExtendingSelection: false)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: {
                vc.notesTableView.setSelected(note: note)
            })
        }
    }
    
    // MARK: - FSNotes routes
    
    func FSNotesRouter(_ url: URL) {
        guard let directive = url.host else { return }
        
        switch directive {
        case FSNotesRoutes.find.rawValue:
            RouteFSNotesFind(url)
        case FSNotesRoutes.open.rawValue:
            RouteFSNotesOpen(url)
        default:
            break
        }
    }
    
    /// Handles URLs with the tag consolinotes://open/?tag=test (or fsnotes://)
    /// Note links only navigate. URL parameters never create or modify notes.
    /// Handles URLs with the tag consolinotes://open/?title=Existing+Note
    ///
    func RouteFSNotesOpen(_ url: URL) {
        guard let vc = ViewController.shared() else { return }
        
        if let tag = url["tag"]?.removingPercentEncoding {
            vc.sidebarOutlineView.select(tag: tag)
            return
        }
        
        if let title = url["title"]?.removingPercentEncoding {
            if let note = Storage.shared().getBy(titleOrName: title) {
                // Reset UI and focus
                vc.cleanSearchAndEditArea(shouldBecomeFirstResponder: false, completion: { () -> Void in
                    vc.notesTableView.selectRowAndSidebarItem(note: note)
                    
                    NSApp.mainWindow?.makeFirstResponder(vc.editor)
                    vc.notesTableView.saveNavigationHistory(note: note)
                })
                
            } else {
                search(query: title)
            }
        }
    }
    
    /// Handles URLs with the path /find/searchstring1%20searchstring2
    func RouteFSNotesFind(_ url: URL) {
        guard ViewController.shared() != nil else {
            self.url = url
            return
        }

        search(url: url)
    }

    public func search(url: URL) {
        guard let vc = ViewController.shared() else { return }

        var lastPath = url.lastPathComponent

        if let wikiURL = url["id"] {
            if let note = Storage.shared().getBy(titleOrName: wikiURL) {
                vc.cleanSearchAndEditArea(shouldBecomeFirstResponder: false, completion: { () -> Void in
                    vc.notesTableView.selectRowAndSidebarItem(note: note)
                    NSApp.mainWindow?.makeFirstResponder(vc.editor)
                    vc.notesTableView.saveNavigationHistory(note: note)
                })
                return
            } else {
                lastPath = wikiURL
                vc.search.window?.makeFirstResponder(vc.search)
            }
        }

        search(query: lastPath)
    }

    func search(query: String) {
        guard let controller = ViewController.shared() else { return }

        let searchQuery = SearchQuery()
        searchQuery.type = .All
        searchQuery.setFilter(query)

        controller.storage.setSearchQuery(value: searchQuery)
        controller.updateTable() {
            DispatchQueue.main.async {
                controller.search.stringValue = query

                if let note = controller.notesTableView.getNoteList().first {
                    if note.title.lowercased() == query.lowercased() {
                        controller.notesTableView.saveNavigationHistory(note: note)
                        controller.notesTableView.setSelected(note: note)
                        controller.view.window?.makeFirstResponder(controller.editor)
                    } else {
                        controller.search.suggestAutocomplete(note, filter: query)
                    }
                }
            }
        }
    }
    
    // MARK: - nvALT routes, for compatibility
    
    func NvALTRouter(_ url: URL) {
        guard let directive = url.host else { return }
        
        switch directive {
        case NvALTRoutes.find.rawValue:
            RouteNvAltFind(url)
        default:
            RouteNvAltBlank(url)
            break
        }
    }
    
    /// Handle URLs in the format nv://find/searchstring1%20searchstring2
    ///
    /// Note: this route is identical to the corresponding FSNotes route.
    ///
    func RouteNvAltFind(_ url: URL) {
        RouteFSNotesFind(url)
    }
    
    /// Handle URLs in the format nv://note%20title
    ///
    /// Note: this route is an alias to the /find route above.
    ///
    func RouteNvAltBlank(_ url: URL) {
        let pathWithFind = url.absoluteString.replacingOccurrences(of: "://", with: "://find/")
        guard let newURL = URL(string: pathWithFind) else { return }
        
        RouteFSNotesFind(newURL)
    }
    
}
