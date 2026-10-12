//
//  EditorViewController.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 26.06.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit
import WebKit
import UserNotifications

class EditorViewController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {
    private static var passwordRequestGeneration: UInt64 = 0
    private static let passwordControllers = NSHashTable<EditorViewController>.weakObjects()
    private var passwordAlert: NSAlert?
    private var passwordWindowObserver: NSObjectProtocol?

    /// A pending password prompt must not undo a later lock request.
    public static func cancelPasswordRequests() {
        passwordRequestGeneration &+= 1
        for controller in passwordControllers.allObjects { controller.teardownPasswordPrompt() }
        FIDO2UnlockUI.cancelPendingRequests()
        EncryptedNoteRecoveryController.cancel()
        PlaintextDisclosure.cancel()
        PrivateNoteArchive.cancelOperations()
    }
    
    public var alert: NSAlert?
    public var noteLoading: ProgressState = .none
    
    public var vcEditor: EditTextView?
    public var vcTitleLabel: TitleTextField?
    public var vcNonSelectedLabel: NSTextField?
    
    public var vcPreviewButton: NSButton?
    public var vcShareButton: NSButton?
    public var vcLockUnlockButton: NSButton?
    public var vcEditorScrollView: EditorScrollView?
    
    public var previewResizeTimer = Timer()
    public var rowUpdaterTimer = Timer()
    public var editorUndoManager = UndoManager()
    
    public var breakUndoTimer = Timer()
    
    // git
    public var snapshotsTimer = Timer()
    public var lastSnapshot: Int?
    
    public var encPassword: NSSecureTextField?
    public var encVerifyPassword: NSSecureTextField?
    public var encCompletionHandler: ((String) -> Void)?
    
    public func initView() {
        guard let editor = vcEditor else { return }
        editor.delegate = self
        
        initScrollObserver()
        
        editor.isGrammarCheckingEnabled = UserDefaultsManagement.grammarChecking
        PrivateTextServices.apply(to: editor)
        editor.isContinuousSpellCheckingEnabled = UserDefaultsManagement.continuousSpellChecking
        editor.smartInsertDeleteEnabled = UserDefaultsManagement.smartInsertDelete
        editor.isAutomaticSpellingCorrectionEnabled = UserDefaultsManagement.automaticSpellingCorrection
        editor.isAutomaticQuoteSubstitutionEnabled = UserDefaultsManagement.automaticQuoteSubstitution
        editor.isAutomaticDataDetectionEnabled = UserDefaultsManagement.automaticDataDetection
        editor.isAutomaticLinkDetectionEnabled = UserDefaultsManagement.automaticLinkDetection
        editor.isAutomaticTextReplacementEnabled = UserDefaultsManagement.automaticTextReplacement
        editor.isAutomaticDashSubstitutionEnabled = UserDefaultsManagement.automaticDashSubstitution
    }
        
    deinit {
        if let observer = passwordWindowObserver { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.removeObserver(self)
    }
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let vc = ViewController.shared() else { return false}
        
        // Current note
        var note = vc.editor.note
        
        if note == nil {
            note = vc.getSelectedNotes()?.first
        }
        
        let ident = menuItem.identifier?.rawValue
        
        if let title = menuItem.menu?.identifier?.rawValue {
            switch title {
            case "fsnotesMenu":
                if menuItem.identifier?.rawValue == "fsnotes.emptyBin" {
                    menuItem.keyEquivalentModifierMask = UserDefaultsManagement.focusInEditorOnNoteSelect
                    ? [.command, .option, .shift]
                    : [.command, .shift]
                    
                    menuItem.title = NSLocalizedString("Empty Bin", comment: "")
                    return true
                }
            case "fileMenu":
                return vc.processFileMenuItems(menuItem, menuId: title)
            case "shareMenu":
                return vc.processShareMenuItems(menuItem, menuId: title)
            case "folderMenu":
                return vc.processLibraryMenuItems(menuItem, menuId: title)
            case "findMenu":
                guard let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
                      evc.vcEditor?.note != nil else { return false }
                        
                if evc.vcEditor?.markdownView == nil {
                    if ["findMenu.find",
                        "findMenu.findAndReplace",
                        "findMenu.next",
                        "findMenu.prev",
                        "findMenu.selectionToFind"
                    ].contains(menuItem.identifier?.rawValue) {
                        return true
                    }
                } else {
                    if ["findMenu.find",
                        "findMenu.next",
                        "findMenu.prev",
                        "findMenu.selectionToFind"
                    ].contains(menuItem.identifier?.rawValue) {
                        return true
                    }
                }

                return false
            case "viewSortBy":
                let iconName = UserDefaultsManagement.sortDirection ? "arrow.down" : "arrow.up"
                
                switch menuItem.tag {
                case 1:
                    if UserDefaultsManagement.sort == .modificationDate {
                        if #available(macOS 11.0, *) {
                            menuItem.image = NSImage.init(systemSymbolName: iconName, accessibilityDescription: nil)
                            menuItem.state = .off
                        } else {
                            menuItem.state = .on
                            menuItem.image = NSImage()
                        }
                    } else {
                        menuItem.state = .off
                        menuItem.image = NSImage()
                    }
                case 2:
                    if UserDefaultsManagement.sort == .creationDate {
                        if #available(macOS 11.0, *) {
                            menuItem.image = NSImage.init(systemSymbolName: iconName, accessibilityDescription: nil)
                            menuItem.state = .off
                        } else {
                            menuItem.state = .on
                            menuItem.image = NSImage()
                        }
                    } else {
                        menuItem.state = .off
                        menuItem.image = NSImage()
                    }
                case 3:
                    if UserDefaultsManagement.sort == .title {
                        if #available(macOS 11.0, *) {
                            menuItem.image = NSImage.init(systemSymbolName: iconName, accessibilityDescription: nil)
                            menuItem.state = .off
                        } else {
                            menuItem.state = .on
                            menuItem.image = NSImage()
                        }
                    } else {
                        menuItem.state = .off
                        menuItem.image = NSImage()
                    }
                default:
                    break
                }
            case "showInSidebar":
                switch menuItem.tag {
                case 1:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityInbox ? .on : .off
                case 2:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityNotes ? .on : .off
                case 3:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityTodo ? .on : .off
                case 5:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityTrash ? .on : .off
                case 6:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityUntagged ? .on : .off
                default:
                    break
                }
            case "viewMenu":
                
                switch ident {
                case "previewMathJax":
                    menuItem.state = UserDefaultsManagement.mathJaxPreview ? .on : .off
                    break
                    
                case "viewMenu.historyBack":
                    if vc.notesTableView.historyPosition == 0 {
                        return false
                    }
                    break
                    
                case "viewMenu.historyForward":
                    if vc.notesTableView.historyPosition == vc.notesTableView.history.count - 1 {
                        return false
                    }
                    break
                    
                case "view.toggleNoteList":
                    menuItem.title = vc.isVisibleNoteList()
                    ? NSLocalizedString("Hide Note List", comment: "")
                    : NSLocalizedString("Show Note List", comment: "")
                    break
                    
                case "view.toggleSidebar":
                    menuItem.title = vc.isVisibleSidebar()
                    ? NSLocalizedString("Hide Sidebar", comment: "")
                    : NSLocalizedString("Show Sidebar", comment: "")
                    break
                    
                case "viewMenu.actualSize":
                    return UserDefaultsManagement.fontSize != UserDefaultsManagement.DefaultFontSize
                    
                default:
                    break
                }
                
            default:
                break
            }
        }
        
        return true
    }
    
    public func getSelectedNotes() -> [Note]? {
        // Opened window
        if NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true,
           let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
           let note = evc.vcEditor?.note {
            return [note]
        }
        
        // Active main window
        if let cvc = NSApplication.shared.keyWindow?.contentViewController,
           cvc.isKind(of: ViewController.self),
           let vc = ViewController.shared(),
           let selected = vc.notesTableView.getSelectedNotes() {
            return selected
        }
        
        return nil
    }
    
    public func getSelectedNote() -> Note? {
        // Opened window
        if NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true,
           let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
           let note = evc.vcEditor?.note {
            return note
        }
        
        // Active main window
        if let cvc = NSApplication.shared.keyWindow?.contentViewController,
           cvc.isKind(of: ViewController.self),
           let vc = ViewController.shared(),
           let selected = vc.notesTableView.getSelectedNotes()?.first {
            
            return selected
        }
        
        return nil
    }
    
    private func isFirstResponder(responder: AnyClass) -> Bool {
        return view.window?.firstResponder?.isKind(of: responder) == true
    }
    
    private func isOpenedInNewWindow() -> Bool {
        return NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true
    }
    
    // MARK: Window bar actions
    
    @IBAction func textFinder(_ sender: NSMenuItem) {
        guard let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
              evc.vcEditor?.note != nil
        else { return }
        
        if let mView = evc.vcEditor?.markdownView {
            mView.performTextFinderAction(sender)
            return
        }
        
        if let editView = evc.vcEditor {
            editView.performFindPanelAction(sender)
        }
    }
    
    @IBAction func fsToggleLockItem(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }
        
        if isFirstResponder(responder: SidebarOutlineView.self) {
            vc.sidebarOutlineView.toggleFolderLock(sender)
            return
        }
        
        if isFirstResponder(responder: NotesTableView.self) ||
            isFirstResponder(responder: EditTextView.self) ||
            isOpenedInNewWindow() {
            vc.toggleNotesLock(sender)
            return
        }
    }
    
    @IBAction func fsDecryptItem(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }
        
        if isFirstResponder(responder: SidebarOutlineView.self) {
            vc.sidebarOutlineView.removeFolderEncryption(sender)
            return
        }
        
        if isFirstResponder(responder: NotesTableView.self) || isOpenedInNewWindow() {
            vc.removeNoteEncryption(sender)
            return
        }
    }
    
    @IBAction func fsRevealItem(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }
        
        if isFirstResponder(responder: SidebarOutlineView.self) {
            vc.sidebarOutlineView.revealInFinder(sender)
            return
        }
        
        if isFirstResponder(responder: NotesTableView.self) ||
            isFirstResponder(responder: EditTextView.self) ||
            isOpenedInNewWindow() {
            vc.finderMenu(sender)
            return
        }
    }
    
    @IBAction func fsRenameItem(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }
        
        if isFirstResponder(responder: SidebarOutlineView.self) || isOpenedInNewWindow() {
            vc.sidebarOutlineView.renameFolderMenu(sender)
            return
        }
        
        if isFirstResponder(responder: NotesTableView.self) ||
            isFirstResponder(responder: EditTextView.self) {
            vc.renameMenu(sender)
            return
        }
    }
        
    @IBAction func toggleNotesLock(_ sender: Any) {
        guard let vc = ViewController.shared(),
              let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController else { return }
        
        let isOpenedWindow = NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true
        
        var notes = vc.getSelectedNotes()
        if isOpenedWindow, let note = evc.vcEditor?.note {
            notes = [note]
        }
        
        guard let first = notes?.first, let notes = notes else { return }
        
        // Lock unlocked
        if first.isUnlocked() && !first.isPrivacyShielded {
            _ = lockUnlocked(notes: notes)
            return
        }
        
        // Unlock encrypted
        if first.isEncryptedAndLocked() {
            getMasterPassword(allowHardware: true) { password in
                guard password.count > 0 else { return }
                
                for note in notes {
                    guard note.isEncryptedAndLocked(), note.unLock(password: password) else { continue }
                    
                    let insertTags = note.scanContentTags().0
                    
                    DispatchQueue.main.async {
                        self.reloadAllOpenedWindows(note: note)
                        
                        ViewController.shared()?.sidebarOutlineView?.addTags(insertTags)
                        ViewController.shared()?.notesTableView.reloadRow(note: note)
                    }
                }
            }
            
            return
        }
        
        // Encrypt plain
        getMasterPassword(forEncrypt: true) { password in
            for note in notes {
                guard !note.isEncrypted() else { continue }
                if note.encrypt(password: password) {
                    note.password = nil
                    
                    DispatchQueue.main.async {
                        self.reloadAllOpenedWindows(note: note)
                        
                        ViewController.shared()?.focusTable()
                        ViewController.shared()?.notesTableView.reloadRow(note: note)
                        ViewController.shared()?.sidebarOutlineView.reloadTags()
                    }
                } else { note.presentSaveFailure() }
            }
        }
    }
    
    @IBAction func openProjectViewSettings(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else {
            return
        }
        
        if let controller = vc.storyboard?.instantiateController(withIdentifier: "ProjectSettingsViewController")
            as? ProjectSettingsViewController {
            vc.projectSettingsViewController = controller
            
            if let project = vc.sidebarOutlineView.getSelectedProject() {
                vc.presentAsSheet(controller)
                controller.load(project: project)
            }
        }
    }
    
    @IBAction func createFolder(_ sender: Any) {
        guard let vc = ViewController.shared(),
              let sidebarOutlineView = vc.sidebarOutlineView else { return }
        
        // Call from menu bar
        if let sender = sender as? NSMenuItem, sender.identifier?.rawValue == "fileMenu.attach" {
            sidebarOutlineView.addRoot()
            return
        }
        
        // Call from popup menu or menu bar
        var project = sidebarOutlineView.getSelectedProject()

        if project == nil || project?.isVirtual == true || !isFirstResponder(responder: SidebarOutlineView.self) {
            project = Storage.shared().getDefault()
        }

        guard let project = project, let window = MainWindowController.shared() else { return }

        let alert = NSAlert()
        vc.alert = alert

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 20))
        alert.messageText = NSLocalizedString("New project", comment: "")
        alert.informativeText = NSLocalizedString("Please enter project name:", comment: "")
        alert.accessoryView = field
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Add", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.beginSheetModal(for: window) { (returnCode: NSApplication.ModalResponse) -> Void in
            if returnCode == NSApplication.ModalResponse.alertFirstButtonReturn {
                let name = field.stringValue
                guard name.count > 0 else { return }
                
                OperationQueue.main.addOperation {
                    vc.sidebarOutlineView.createProject(in: project, with: name)
                }
            }

            NSApp.mainWindow?.makeFirstResponder(sidebarOutlineView)
            vc.alert = nil
        }

        field.becomeFirstResponder()
    }
    
    @IBAction func togglePreview(_ sender: Any) {
        guard let editor = vcEditor else { return }
        
        let firstResp = view.window?.firstResponder

        editor.togglePreviewState()
        
        if (editor.isPreviewEnabled()) {
            
            //Preview mode doesn't support text search
            cancelTextSearch()
            refillEditArea(force: true)

            if let mdView = vcEditor?.editorViewController?.vcEditor?.markdownView {
                view.window?.makeFirstResponder(mdView)
            }
        } else {
            disablePreview()
        }

        if let responder = firstResp, (
            ViewController.shared()?.search.currentEditor() == firstResp
            || responder.isKind(of: NotesTableView.self)
            || responder.isKind(of: SidebarOutlineView.self)
        ) {
            view.window?.makeFirstResponder(firstResp)
        } else {
            var responder: NSResponder? = vcEditor
            
            if vcEditor?.isPreviewEnabled() == true, let mView = vcEditor?.markdownView {
                responder = mView
            }
            
            if let responder = responder {
                view.window?.makeFirstResponder(responder)
            }
        }

        vcEditor?.userActivity?.needsSave = true

        editor.note?.project.saveNotesPreview()

        updateVimChrome()
    }

    /// Refreshes the Vim statusline and command line of this editor's window. Windows with Vim chrome override it.
    @objc dynamic func updateVimChrome() {}
    
    @IBAction func toggleMathJax(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on

        UserDefaultsManagement.mathJaxPreview = sender.state == .on

        refillEditArea(force: true)
    }
        
    @IBAction func shareSheet(_ sender: NSButton) {
        if let note = vcEditor?.note, !note.isEncryptedAndLocked(), PlaintextDisclosure.confirm("Share", note: note) {
            let sharingPicker = NSSharingServicePicker(items: [
                note.getPrettifiedContent()
            ])
            sharingPicker.delegate = self
            sharingPicker.show(relativeTo: NSZeroRect, of: sender, preferredEdge: .minY)
        }
    }
    
    // MARK: File menu
    
    @IBAction func printNotes(_ sender: NSMenuItem) {
        guard let notes = getSelectedNotes(), let note = notes.first, !note.isEncryptedAndLocked(),
              PlaintextDisclosure.confirm("Print", note: note) else { return }
        
        if note.isMarkdown() || note.isEncrypted() {
            printMarkdownPreview()
            return
        }
        
        let pv = NSTextView(frame: NSMakeRect(0, 0, 528, 688))
        pv.textStorage?.append(note.content)
        
        let printInfo = NSPrintInfo.shared
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.scalingFactor = 1
        printInfo.topMargin = 40
        printInfo.leftMargin = 40
        printInfo.rightMargin = 40
        printInfo.bottomMargin = 40
        
        let operation: NSPrintOperation = NSPrintOperation(view: pv, printInfo: printInfo)
        operation.printPanel.options.insert(NSPrintPanel.Options.showsPaperSize)
        operation.printPanel.options.insert(NSPrintPanel.Options.showsOrientation)
        operation.run()
    }
    
    @IBAction func finderMenu(_ sender: NSMenuItem) {
        guard let notes = getSelectedNotes() else { return }
        
        var urls = [URL]()
        for note in notes {
            urls.append(note.url)
        }
        
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    
    @IBAction func pinMenu(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }
        
        ViewController.shared()?.pin(selectedNotes: notes, toggle: true)
    }
    
    @IBAction func editorMenu(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }
        
        ViewController.shared()?.external(selectedNotes: notes)
    }
    
    @IBAction func copyURL(_ sender: Any) {
        guard let note = getSelectedNotes()?.first, !note.isEncryptedAndLocked() else { return }
        
        if let title = note.title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {

            let name = AppLink.findPrefix + title
            SensitiveClipboard.writeString(name)
            
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else { return }

                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                ) { _, _ in }
            }

            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("URL has been copied to clipboard", comment: "")
            content.body = "The note link is available on this Mac's clipboard."
            content.sound = .default

            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }
    
    @IBAction func copyTitle(_ sender: Any) {
        guard let note = getSelectedNotes()?.first, !note.isEncryptedAndLocked() else { return }
        SensitiveClipboard.writeString(note.title)
    }
    
    @IBAction func upgradeNoteEncryption(_ sender: Any) {
        guard let selected = getSelectedNotes(), selected.count == 1,
              let note = selected.first, !note.isEncryptedAndLocked(), note.usesLegacyEncryption,
              let password = note.password else { return }
        let alert = NSAlert()
        alert.messageText = "Upgrade this note's encryption?"
        alert.informativeText = "This keeps the current password and upgrades the note to stronger password derivation and authenticated encryption. FSNotes and consolinotes versions before 1.2 cannot open the upgraded file. Existing history and backup copies are unchanged."
        alert.addButton(withTitle: "Upgrade Encryption")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard note.upgradeEncryption(password: password) else {
            note.presentSaveFailure()
            return
        }
        reloadAllOpenedWindows(note: note)
        ViewController.shared()?.notesTableView.reloadRow(note: note)
    }

    @IBAction func removeNoteEncryption(_ sender: Any) {
        guard var notes = getSelectedNotes(),
              let vc = ViewController.shared() else { return }

        notes = decryptUnlocked(notes: notes)
        guard notes.count > 0 else { return }

        getMasterPassword(allowHardware: true) { password in
            for note in notes {
                if note.isEncrypted() {
                    let success = note.unEncrypt(password: password)
                    if success && notes.count == 0x01 {
                        note.password = nil
                        DispatchQueue.main.async {
                            self.reloadAllOpenedWindows(note: note)
                        }
                    }
                }
                
                vc.notesTableView.reloadRow(note: note)
            }
        }
    }
    
    @IBAction func changeCreationDate(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }
        guard let note = notes.first else { return }
        guard let creationDate = note.getFileCreationDate() else { return }
        guard let window = view.window else { return }

        alert = NSAlert()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 20))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = formatter.string(from: creationDate)

        field.stringValue = date
        field.placeholderString = "2020-08-28 21:59:07"

        alert?.messageText = NSLocalizedString("Change Creation Date", comment: "Menu") + ":"
        alert?.accessoryView = field
        alert?.alertStyle = .informational
        alert?.addButton(withTitle: "OK")
        alert?.beginSheetModal(for: window) { (returnCode: NSApplication.ModalResponse) -> Void in
            if returnCode == NSApplication.ModalResponse.alertFirstButtonReturn {
                for note in notes {
                    if note.setCreationDate(string: field.stringValue) {
                        ViewController.shared()?.notesTableView.reloadRow(note: note)
                    }
                }
            }

            self.alert = nil
        }

        field.becomeFirstResponder()
    }
        
    @IBAction func createInNewWindow(_ sender: Any) {
        var content = String()
        
        if let inlineTags = ViewController.shared()?.sidebarOutlineView.getSelectedInlineTags() {
            content = inlineTags
        }
        
        if let note = createNote(content: content, openInNewWindow: true) {
            openInNewWindow(note: note)
        }
    }
    
    @IBAction func quickNote(_ sender: Any) {
        if let note = createNote(content: "", openInNewWindow: true) {
            NSApp.activate(ignoringOtherApps: true)
            
            if !NSApp.isActive {
                AppDelegate.mainWindowController?.window?.miniaturize(self)
            }
            
            openInNewWindow(note: note)
        }
    }
    
    @IBAction func historyMenu(_ sender: Any) {
        guard let cvc = NSApplication.shared.keyWindow?.contentViewController,
              let vc = ViewController.shared(),
              let note = getSelectedNotes()?.first else { return }

        let moveMenu = NSMenu()
        moveMenu.identifier = NSUserInterfaceItemIdentifier("fileMenu.history")
        let commits = note.getCommits()

        // Port
        if commits.count == 0 {
            return
        }

        for commit in commits {
            let menuItem = NSMenuItem()
            menuItem.title = commit.getDate()
            menuItem.representedObject = commit
            menuItem.action = #selector(vc.checkoutRevision(_:))
            moveMenu.addItem(menuItem)
        }

        let general = moveMenu.item(at: 0)

        // Main window
        if cvc.isKind(of: ViewController.self),
           vc.notesTableView.selectedRow >= 0 {
            let view = vc.notesTableView.rect(ofRow: vc.notesTableView.selectedRow)
            let x = vc.splitView.subviews[0].frame.width + 5
            moveMenu.popUp(positioning: general, at: NSPoint(x: x, y: view.origin.y + 8), in: vc.notesTableView)
            return
        }

        // Opened in new window
        if cvc.isKind(of: NoteViewController.self) {
            moveMenu.popUp(positioning: general, at: NSPoint(x: view.frame.width + 10, y: view.frame.height - 5), in: view)
        }
    }
    
    @IBAction func duplicate(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }
        
        if notes.contains(where: { !$0.isEncrypted() }), !PlaintextDisclosure.allowUnencryptedCopy("Duplicate Unencrypted") { return }
        for note in notes {
            if note.isUnlocked(), !note.save() { note.presentSaveFailure(); return }
            let src = note.url
            let dst = NameHelper.generateCopy(file: note.url)

            if note.isTextBundle() || note.isEncrypted() {
                try? FileManager.default.copyItem(at: src, to: dst)
                
                continue
            }

            let name = dst.deletingPathExtension().lastPathComponent
            let noteDupe = Note(name: name, project: note.project, type: note.type, cont: note.container)
            noteDupe.content = NSMutableAttributedString(string: note.content.string)

            // Clone images
            if note.type == .Markdown && note.container == .none {
                let images = note.content.getImagesAndFiles()
                for image in images {
                    noteDupe.move(from: image.url, imagePath: image.path, to: note.project, copy: true)
                }
            }

            if noteDupe.save() {
                Storage.shared().add(noteDupe)
            }


            ViewController.shared()?.notesTableView.insertRows(notes: [noteDupe])
        }
    }
    
    @IBAction func importNote(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.begin { (result) -> Void in
            if result == NSApplication.ModalResponse.OK {
                let urls = panel.urls
                
                if let project = vc.sidebarOutlineView.getSelectedProject() ?? Storage.shared().getDefault() {
                    for url in urls {
                        _ = vc.copy(project: project, url: url)
                    }
                }
            }
        }
    }
    
    @objc func moveNote(_ sender: NSMenuItem) {
        let project = sender.representedObject as! Project
        
        guard let notes = getSelectedNotes() else { return }
        
        ViewController.shared()?.moveReq(notes: notes, project: project) { success in
            guard success else { return }
            
            if let cvc = NSApplication.shared.keyWindow?.contentViewController,
               cvc.isKind(of: NoteViewController.self) {
                self.updateTitle(note: notes.first!)
            }
        }
    }
    
    @IBAction func toggleContainer(_ sender: NSMenuItem) {
        guard let notes = getSelectedNotes() else { return }
        
        var newContainer: NoteContainer = .textBundleV2
        if notes.first?.container == .textBundle || notes.first?.container == .textBundleV2 {
            newContainer = .none
        }
        
        for note in notes {
            if note.isEncrypted() {
                continue
            }
            
            note.convertContainer(to: newContainer)
        }
    }
    
    @IBAction func openWindow(_ sender: Any) {
        guard let currentNote = ViewController.shared()?.notesTableView.getSelectedNote() else { return }
     
        openInNewWindow(note: currentNote)
    }
    
    @IBAction func moveMenu(_ sender: Any) {
        guard let vc = ViewController.shared() else { return }
        
        // Move menu right from notes table view
        
        if let cvc = NSApplication.shared.keyWindow?.contentViewController, cvc.isKind(of: ViewController.self) {
            if vc.notesTableView.selectedRow >= 0 {
                vc.loadMoveMenu()

                let moveTitle = NSLocalizedString("Move", comment: "Menu")
                let moveMenu = vc.noteMenu.item(withTitle: moveTitle)
                let view = vc.notesTableView.rect(ofRow: vc.notesTableView.selectedRow)
                let x = vc.splitView.subviews[0].frame.width + 5
                let general = moveMenu?.submenu?.item(at: 0)

                moveMenu?.submenu?.popUp(positioning: general, at: NSPoint(x: x, y: view.origin.y + 8), in: vc.notesTableView)
            }
            
            return
            
        // Move menu right from window
            
        } else {
            vc.loadMoveMenu()
            
            let moveTitle = NSLocalizedString("Move", comment: "Menu")
            let moveMenu = vc.noteMenu.item(withTitle: moveTitle)
            let general = moveMenu?.submenu?.item(at: 0)
            
            moveMenu?.submenu?.popUp(positioning: general, at: NSPoint(x: view.frame.width + 10, y: view.frame.height - 5), in: view)
        }
    }
    
    public func removeNotes(notes: [Note], forceRemove: Bool = false, rows: IndexSet? = nil) {
        guard let vc = ViewController.shared() else { return }
        
        let si = vc.getSidebarItem()
        if si?.isTrash() == true || forceRemove {
            vc.removeForever(notes: notes)
            return
        }
        
        let currentNote = vc.editor.note
        UserDataService.instance.searchTrigger = true
        vc.storage.removeNotes(notes: notes) { urlMapping in
            let removedNotes = notes.filter { note in !vc.storage.noteList.contains { $0 === note } }
            vc.notesTableView.removeRows(notes: removedNotes)
            vc.sidebarOutlineView.reloadTags()
            if let md = AppDelegate.mainWindowController {
                let undoManager = md.notesListUndoManager
                if let ntv = vc.notesTableView, let urlMapping = urlMapping, !urlMapping.isEmpty {
                    // Register undo (restore)
                    undoManager.registerUndo(withTarget: ntv, selector: #selector(ntv.unDelete), object: urlMapping)
                    undoManager.setActionName(NSLocalizedString("Delete", comment: ""))
                }
                
                if !removedNotes.isEmpty, let rows = rows, let minRow = rows.min(), minRow > -1 {
                    let qty = vc.notesTableView.countNotes()
                    if qty > minRow {
                        vc.notesTableView.selectRow(minRow)
                    } else {
                        vc.notesTableView.selectRow(qty - 1)
                    }
                }
                
            }
            UserDataService.instance.searchTrigger = false
            if let currentNote = currentNote, removedNotes.contains(where: { $0 === currentNote }) {
                vc.editor.clear()
            }
            for note in removedNotes { self.closeAllOpenedWindows(where: note) }
        }
        
        // If is main window – focus to notes list
        if let cvc = NSApplication.shared.keyWindow?.contentViewController,
           cvc.isKind(of: ViewController.self) {
            NSApp.mainWindow?.makeFirstResponder(vc.notesTableView)
        }
    }
    
    @IBAction func actualSize(_ sender: Any) {
        UserDefaultsManagement.codeFont = NSFont(descriptor: UserDefaultsManagement.codeFont.fontDescriptor, size: CGFloat(UserDefaultsManagement.DefaultFontSize))!
        UserDefaultsManagement.noteFont = NSFont(descriptor: UserDefaultsManagement.noteFont.fontDescriptor, size: CGFloat(UserDefaultsManagement.DefaultFontSize))!

        ViewController.shared()?.reloadFonts()
    }

    @IBAction func zoomIn(_ sender: Any) {
        UserDefaultsManagement.codeFont = NSFont(descriptor: UserDefaultsManagement.codeFont.fontDescriptor, size: UserDefaultsManagement.codeFont.pointSize + 1)!
        UserDefaultsManagement.noteFont = NSFont(descriptor: UserDefaultsManagement.noteFont.fontDescriptor, size: UserDefaultsManagement.noteFont.pointSize + 1)!

        ViewController.shared()?.reloadFonts()
    }

    @IBAction func zoomOut(_ sender: Any) {
        UserDefaultsManagement.codeFont = NSFont(descriptor: UserDefaultsManagement.codeFont.fontDescriptor, size: UserDefaultsManagement.codeFont.pointSize - 1)!
        UserDefaultsManagement.noteFont = NSFont(descriptor: UserDefaultsManagement.noteFont.fontDescriptor, size: UserDefaultsManagement.noteFont.pointSize - 1)!

        ViewController.shared()?.reloadFonts()
    }
    
    @IBAction func showBackLinks(_ sender: NSMenuItem) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
            let cvc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
            let note = cvc.vcEditor?.note, !note.isEncryptedAndLocked() {
            ViewController.shared()?.editor.clear()
            appDelegate.search(query: "[[" + note.title + "]]")
        }
    }

    // MARK: Dep methods
    
    public func openInNewWindow(note: Note, frame: NSRect? = nil, preview: Bool = false) {
        guard let windowController = NSStoryboard(name: "Main", bundle: nil)
            .instantiateController(withIdentifier: "noteWindowController") as? NSWindowController else { return }
        
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(windowController)
                
        let viewController = windowController.contentViewController as! NoteViewController
        viewController.initWindow()
                
        viewController.editor.changePreviewState(preview)
        viewController.editor.fill(note: note)
        
        if note.isEncryptedAndLocked() {
            viewController.lockUnlockButton.image = TUITheme.lockChip(encrypted: true, locked: true)
            viewController.toggleNotesLock(self)
        } else {
            viewController.lockUnlockButton.image = TUITheme.lockChip(encrypted: note.isEncrypted(), locked: false)
        }
        
        AppDelegate.noteWindows.insert(windowController, at: 0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let frame = frame {
                windowController.window?.setFrame(frame, display: true)
            }
            
            viewController.view.window?.makeFirstResponder(viewController.editor)
            viewController.updateVimChrome()
        }
    }
    
    func cancelTextSearch() {
        let menu = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.tag = NSTextFinder.Action.hideFindInterface.rawValue
        vcEditor?.performTextFinderAction(menu)
    }

    func disablePreview(captureScroll: Bool = true) {
        guard let textView = self.vcEditor else { return }
        
        textView.disablePreviewEditorAndNote()
        
        if captureScroll {
            textView.markdownView?.getScrollPosition { point in
                self.vcEditor?.note?.contentOffsetWeb = point
            }
        }
        
        textView.markdownView?.removeFromSuperview()
        textView.markdownView = nil
        
        textView.subviews.removeAll(where: { $0.isKind(of: MPreviewView.self) })

        refillEditArea()
    }
    
    public func viewDidResize() {
        guard vcEditor?.isPreviewEnabled() == true else { return }

        if noteLoading != .incomplete {
            previewResizeTimer.invalidate()
            previewResizeTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(reloadPreview), userInfo: nil, repeats: false)
        }
    }
    
    @objc private func reloadPreview() {
        DispatchQueue.main.async {
            MPreviewView.template = nil
            self.refillEditArea(force: true)
        }
    }
    
    public func updateTitle(note: Note) {
        guard let vcTitleLabel = vcTitleLabel else { return }
        
        if note.isPrivacyShielded {
            vcTitleLabel.stringValue = "Locked — unsaved changes protected"
            view.window?.title = "consolinotes — Locked"
            return
        }
        var titleString = note.getFileName()

        if titleString.isValidUUID {
            titleString = String()
        }

        if titleString.count > 0 {
            vcTitleLabel.stringValue = note.project.getNestedLabel() + " › " + titleString
        } else {
            vcTitleLabel.stringValue = note.project.getNestedLabel()
        }

        vcTitleLabel.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)

        view.window?.title = vcTitleLabel.stringValue
    }
    
    func refillEditArea(force: Bool = false) {
        noteLoading = .incomplete
        vcPreviewButton?.state = vcEditor?.isPreviewEnabled() == true ? .on : .off

        if let note = vcEditor?.note {
            vcEditor?.fill(note: note, force: force)
        }

        noteLoading = .done
    }
    
    public func unLock(notes: [Note]) {
        getMasterPassword(allowHardware: true) { password in
            guard password.count > 0 else { return }

            var i = 0
            for note in notes {
                let success = note.unLock(password: password)
                if success {

                    DispatchQueue.main.async {
                        guard !note.isEncryptedAndLocked() else { return }
                        ViewController.shared()?.sidebarOutlineView?.addTags(note.scanContentTags().0)
                        ViewController.shared()?.notesTableView.reloadRow(note: note)
                    }

                    if i == 0 {
                        note.password = password

                        DispatchQueue.main.async {
                            self.reloadAllOpenedWindows(note: note)
                        }
                    }
                }
                
                i = i + 1
            }
        }
    }
    
    public func reloadAllOpenedWindows(note: Note) {
        let editors = AppDelegate.getEditTextViews()
        
        for editor in editors {
            if editor.note == note {
                editor.editorViewController?.refillEditArea(force: true)
                
                let lockImage = TUITheme.lockChip(encrypted: note.isEncrypted(), locked: note.isEncryptedAndLocked())

                if let noteVC = editor.editorViewController as? NoteViewController {
                    noteVC.lockUnlockButton.image = lockImage
                }
                
                if let mainVC = editor.editorViewController as? ViewController {
                    mainVC.lockUnlock.image = lockImage
                }
                
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
    
    public func closeAllOpenedWindows(where note: Note) {
        for editor in AppDelegate.getOpenedEditTextViews() {
            if editor.note == note {
                editor.window?.close()
            }
        }
    }

    public func getMasterPassword(forEncrypt: Bool = false, allowHardware: Bool = false, completion requestCompletion: @escaping (String) -> ()) {
        Self.passwordControllers.add(self)
        let generation = Self.passwordRequestGeneration
        let completion: (String) -> Void = { password in
            guard generation == Self.passwordRequestGeneration else { return }
            requestCompletion(password)
        }
        if forEncrypt && !UserDefaultsManagement.suppressNewEncryptionFormatNotice {
            let notice = NSAlert()
            notice.alertStyle = .informational
            notice.messageText = "Encrypt with the new note format?"
            notice.informativeText = "New encrypted files require consolinotes 1.2 or later and cannot be opened by FSNotes. Existing history and backup copies are unchanged and may still contain plaintext. Keep the password; it is required to open these notes."
            notice.addButton(withTitle: "Encrypt")
            notice.addButton(withTitle: "Cancel")
            notice.showsSuppressionButton = true
            notice.suppressionButton?.title = "Do not ask again."
            guard runPasswordNotice(notice) == .alertFirstButtonReturn,
                  generation == Self.passwordRequestGeneration else { return }
            if notice.suppressionButton?.state == .on {
                UserDefaultsManagement.suppressNewEncryptionFormatNotice = true
            }
        }
        if !forEncrypt && allowHardware {
            do {
                if try FIDO2PasswordProvider.shared.load() != nil {
                    let choice = NSAlert()
                    choice.messageText = "Unlock encrypted notes"
                    choice.informativeText = "Use your enrolled YubiKey, or enter the original note password."
                    choice.addButton(withTitle: "Use YubiKey…")
                    choice.addButton(withTitle: "Enter Password…")
                    choice.addButton(withTitle: "Cancel")
                    let answer = runPasswordNotice(choice)
                    guard generation == Self.passwordRequestGeneration else { return }
                    switch answer {
                    case .alertFirstButtonReturn:
                        FIDO2UnlockUI.unlock(from: self, completion: completion, manualFallback: {
                            guard generation == Self.passwordRequestGeneration else { return }
                            self.masterPasswordPrompt(validation: false, completion: completion)
                        }); return
                    case .alertSecondButtonReturn: break
                    default: return
                    }
                }
            } catch {
                masterPasswordPrompt(validation: false, reason: "The YubiKey enrollment could not be read. Enter your original note password.", completion: completion)
                return
            }
        }
        masterPasswordPrompt(validation: forEncrypt, completion: completion)
    }

    /// All application-owned prompt references are released before invoking a caller.
    /// AppKit and Swift can still make temporary copies; this is lifetime reduction,
    /// not a promise of complete memory erasure.
    func teardownPasswordPrompt() {
        let prompt = passwordAlert
        passwordAlert = nil
        if let observer = passwordWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            passwordWindowObserver = nil
        }
        for field in [encPassword, encVerifyPassword].compactMap({ $0 }) {
            field.currentEditor()?.string = ""
            field.stringValue = ""
        }
        encPassword = nil
        encVerifyPassword = nil
        encCompletionHandler = nil
        if alert === prompt { alert = nil }
        guard let prompt = prompt else { return }
        prompt.accessoryView = nil
        if NSApp.modalWindow === prompt.window { NSApp.abortModal() }
        if let parent = prompt.window.sheetParent { parent.endSheet(prompt.window, returnCode: .abort) }
        prompt.window.orderOut(nil)
    }

    private func observePasswordWindow(_ window: NSWindow) {
        passwordWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in Self.cancelPasswordRequests() }
    }

    private func runPasswordNotice(_ prompt: NSAlert) -> NSApplication.ModalResponse {
        teardownPasswordPrompt()
        passwordAlert = prompt
        if let window = view.window { observePasswordWindow(window) }
        let response = prompt.runModal()
        if passwordAlert === prompt { teardownPasswordPrompt() }
        return response
    }

    @IBAction func onOkClick(_ sender: Any?) {
        guard let field = encPassword, let prompt = passwordAlert else { return }
        guard !field.stringValue.isEmpty else {
            prompt.informativeText = "Enter a non-empty password."
            prompt.window.makeFirstResponder(field)
            return
        }
        if let repeated = encVerifyPassword, !field.stringValue.utf8.elementsEqual(repeated.stringValue.utf8) {
            prompt.informativeText = "The passwords do not match. Please enter them again."
            repeated.stringValue = ""
            prompt.window.makeFirstResponder(repeated)
            return
        }
        let password = field.stringValue
        let completion = encCompletionHandler
        teardownPasswordPrompt()
        completion?(password)
    }

    private func masterPasswordPrompt(validation: Bool = false, reason: String? = nil, completion: @escaping (String) -> ()) {
        let generation = Self.passwordRequestGeneration
        Self.passwordControllers.add(self)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, generation == Self.passwordRequestGeneration,
                  var window = self.view.window else { return }
            if let editor = NSApplication.shared.keyWindow?.contentViewController as? NoteViewController,
               let current = editor.view.window { window = current }
            self.teardownPasswordPrompt()
            let prompt = NSAlert()
            self.passwordAlert = prompt
            self.alert = prompt
            self.observePasswordWindow(window)
            prompt.alertStyle = .informational
            prompt.messageText = validation ? "Enter an encryption password:" : "Note password:"
            prompt.informativeText = reason ?? (validation
                ? "Keep this password. It cannot be recovered if you lose it."
                : "Enter the password used to encrypt the current note. If a save failed while locking, the password reveals the retained changes.")
            prompt.addButton(withTitle: "OK")
            prompt.addButton(withTitle: "Cancel")
            prompt.buttons[0].target = self
            prompt.buttons[0].action = #selector(self.onOkClick(_:))

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24))
            field.placeholderString = "Password"
            field.setAccessibilityLabel("Note password")
            self.encPassword = field
            self.encCompletionHandler = completion
            if validation {
                let repeated = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24))
                repeated.placeholderString = "Repeat password"
                repeated.setAccessibilityLabel("Repeat note password")
                self.encVerifyPassword = repeated
                let fields = NSStackView(views: [field, repeated])
                fields.orientation = .vertical
                fields.alignment = .leading
                fields.spacing = 10
                fields.frame = NSRect(x: 0, y: 0, width: 290, height: 58)
                field.widthAnchor.constraint(equalToConstant: 290).isActive = true
                repeated.widthAnchor.constraint(equalToConstant: 290).isActive = true
                prompt.accessoryView = fields
            } else { prompt.accessoryView = field }
            prompt.beginSheetModal(for: window) { [weak self, weak prompt] _ in
                guard let self = self, let prompt = prompt, self.passwordAlert === prompt else { return }
                self.teardownPasswordPrompt()
            }
            prompt.window.makeFirstResponder(field)
        }
    }

    func dismissSensitiveDialog() {
        guard let current = alert else { return }
        alert = nil
        func clearFields(_ view: NSView) {
            if let field = view as? NSTextField {
                field.currentEditor()?.string = ""
                field.stringValue = ""
            } else if let text = view as? NSTextView { text.string = "" }
            for child in view.subviews { clearFields(child) }
        }
        if let accessory = current.accessoryView { clearFields(accessory) }
        current.accessoryView = nil
        current.messageText = ""
        current.informativeText = ""
        if NSApp.modalWindow === current.window { NSApp.abortModal() }
        if let parent = current.window.sheetParent { parent.endSheet(current.window, returnCode: .abort) }
        current.window.orderOut(nil)
    }

    /// Shield every editor before any disk write, so a failed save never leaves
    /// retained plaintext visible. The model remains available only for saving
    /// and an explicit password-authenticated recovery action.
    static func shieldForLock(notes: [Note]) {
        cancelPasswordRequests()
        SensitiveClipboard.clearOwned()
        LocalFindState.query = ""
        UserDefaultsManagement.recentSearches = nil
        ViewController.shared()?.search.clearPrivateState()
        for note in notes where note.isUnlocked() { note.isPrivacyShielded = true }
        MPreviewView.purgeSensitivePreviews()
        for editor in AppDelegate.getEditTextViews() {
            editor.editorViewController?.dismissSensitiveDialog()
            editor.clearPrivateFind()
            guard let note = editor.note, notes.contains(where: { $0 === note }) else { continue }
            editor.lockEncryptedView()
            editor.editorViewController?.cancelTextSearch()
            editor.editorViewController?.previewResizeTimer.invalidate()
            editor.editorViewController?.updateTitle(note: note)
            editor.editorViewController?.updateVimChrome()
            editor.window?.displayIfNeeded()
        }
        if let vc = ViewController.shared() {
            vc.updateCounters(note: vc.editor.note)
            for note in notes { vc.notesTableView.reloadRow(note: note) }
            vc.sidebarOutlineView.reloadTags()
            vc.view.window?.displayIfNeeded()
        }
    }

    public func lockUnlocked(notes: [Note]) -> [Note] {
        Self.shieldForLock(notes: notes.filter { $0.isUnlocked() || $0.hasPendingPlaintextCleanup })
        var remaining = notes
        var failures = 0
        for note in notes where note.isUnlocked() || note.hasPendingPlaintextCleanup {
            if note.lock() {
                remaining.removeAll { $0 === note }
                reloadAllOpenedWindows(note: note)
                ViewController.shared()?.notesTableView.reloadRow(note: note)
            } else { failures += 1 }
        }
        ViewController.shared()?.sidebarOutlineView.reloadTags()
        if failures > 0 {
            showProtectionFailure("Some notes could not finish saving or cleanup. Their content is hidden and unsaved changes have been retained. Resolve the storage problem and retry Lock All, or enter the note password to reveal the retained changes. Keep the app open until recovery is complete.")
        }
        return remaining
    }

    public func showProtectionFailure(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Protection operation incomplete"
            alert.informativeText = message
            alert.runModal()
        }
    }

    public func decryptUnlocked(notes: [Note]) -> [Note] {
        var notes = notes

        for note in notes {
            if note.isUnlocked() && !note.isPrivacyShielded {
                if note.unEncryptUnlocked() {
                    notes.removeAll { $0 === note }
                    ViewController.shared()?.notesTableView.reloadRow(note: note)
                }
            }
        }

        return notes
    }
    
    public func removeTags(note: Note) {
        let tags = note.tags
        note.tags = []
        ViewController.shared()?.sidebarOutlineView?.removeTags(tags)
    }
    
    public func dropTitle() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "consolinotes"

        vcTitleLabel?.stringValue = appName
        view.window?.title = appName
    }
    
    func focusEditArea() {
        guard let editor = vcEditor,
              let note = editor.note,
              !editor.isPreviewEnabled(),
              !note.isEncryptedAndLocked() else { return }

        editor.window?.makeFirstResponder(editor)

        if let ntv = ViewController.shared()?.notesTableView, ntv.selectedRow > -1 {
            vcEditor?.isEditable = true
            vcNonSelectedLabel?.isHidden = true
        }
    }
        
    // Changed main edit view
    func textDidChange(_ notification: Notification) {
        guard let editor = vcEditor,
              let note = editor.note,
              let vc = ViewController.shared() else { return }

        vc.prevCommit = nil

        if editor.isEditable {
            note.isBlocked = true

            editor.textStorage?.removeHighlight()
            note.save(attributed: editor.attributedString())

            updateLastEditedStatus()
            vc.reSort(note: note)
        }

        breakUndoTimer.invalidate()
        breakUndoTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(breakUndo), userInfo: nil, repeats: true)
    }

    private func updateLastEditedStatus() {
        let editors = AppDelegate.getEditTextViews()

        for editor in editors {
            editor.isLastEdited = false
        }

        vcEditor?.isLastEdited = true
    }
            
    @objc func breakUndo() {
        guard let editor = vcEditor else { return }
        
        if (
            editor.isPreviewEnabled() == false
           && editor.isEditable
        ) {
            editor.breakUndoCoalescing()
        }
    }
    
    public func createNote(name: String = "", content: String = "", folderName: String? = nil, openInNewWindow: Bool = false, encryptionPassword: String? = nil, creationProject: Project? = nil) -> Note? {
        guard let vc = ViewController.shared() else { return nil }
        
        var text = String()
        var project: Project?
        
        if let folderName = folderName {
            project = vc.sidebarOutlineView.getOrCreateProject(name: folderName)
            
            if let existProject = project, existProject.isEncrypted {
                project = nil
            }
        }
        
        let selectedProjects = vc.sidebarOutlineView.getSidebarProjects()
        var sidebarProject = creationProject ?? project ?? selectedProjects?.first

        
        if sidebarProject == nil {
            sidebarProject = Storage.shared().getDefault()
        }
        
        guard let project = sidebarProject, !project.isLocked() else { return nil }
        if PrivacyPreferences.encryptNewNotes, !project.isEncrypted, encryptionPassword == nil {
            getMasterPassword(forEncrypt: true) { [weak self] password in
                guard let self = self else { return }
                if let note = self.createNote(name: name, content: content, folderName: folderName,
                                               openInNewWindow: openInNewWindow, encryptionPassword: password, creationProject: project), openInNewWindow {
                    self.openInNewWindow(note: note)
                }
            }
            return nil
        }

                
        if !name.isEmpty, [.autoRename, .autoRenameNew].contains(UserDefaultsManagement.naming) && UserDefaultsManagement.autoInsertHeader {
            text.append("# " + name + "\n\n")
        }
        
        if !content.isEmpty {
            text.append(content)
        }
        
        let inlineTags = vc.sidebarOutlineView.getSelectedInlineTags()
        if !inlineTags.isEmpty {
            text.append(inlineTags)
        }
        
        if let type = vc.getSidebarType(), type == .Todo, content.count == 0 {
            text = "- [ ] "
        }

        let note = Note(name: name, project: project)
        note.content = NSMutableAttributedString(string: text)
        if project.isEncrypted || encryptionPassword != nil {
            guard let password = encryptionPassword ?? project.password, note.encrypt(password: password) else {
                showProtectionFailure("The encrypted note could not be created. No plaintext note was created in the folder. Resolve the storage problem and try again.")
                return nil
            }
            guard note.unLock(password: password) else {
                Storage.shared().add(note)
                vc.updateTable()
                showProtectionFailure("The encrypted note was created and kept locked, but could not be opened. Your saved ciphertext is retained; try unlocking it again.")
                return nil
            }
        } else if !note.save() {
            note.presentSaveFailure()
            return nil
        }
        Storage.shared().add(note)

        _ = note.scanContentTags()

        if folderName == nil, let selectedProjects = selectedProjects, !selectedProjects.contains(project) {
            return note
        }

        if !openInNewWindow {
            disablePreview()
            
            vc.notesTableView.deselectNotes()
            vc.storage.searchQuery.dropFilter()
            vc.editor.string = text
            vc.editor.note = note
            vc.search.stringValue.removeAll()
        }
        
        vc.updateTable() {
            if openInNewWindow {
                return
            }
            
            DispatchQueue.main.async {
                vc.notesTableView.saveNavigationHistory(note: note)
                if let index = vc.notesTableView.getIndex(for: note) {
                    vc.notesTableView.selectRowIndexes([index], byExtendingSelection: false)
                    vc.notesTableView.scrollRowToVisible(index)
                }
            
                vc.focusEditArea()

                NSApp.activate(ignoringOtherApps: true)
                self.view.window?.makeKeyAndOrderFront(self)
            }
        }
        
        return note
    }
}
