//
//  NoteViewController.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 25.06.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit

class NoteViewController: EditorViewController, NSWindowDelegate {

    @IBOutlet weak var shareButton: NSButton!
    @IBOutlet weak var previewButton: NSButton!
    @IBOutlet weak var lockUnlockButton: NSButton!
    
    @IBOutlet weak var titleLabel: TitleTextField!
    @IBOutlet weak var editor: EditTextView!
    @IBOutlet weak var editorScrollView: EditorScrollView!
    @IBOutlet weak var titleBarView: TitleBarView!
    
    @IBOutlet weak var nonSelectedLabel: NSTextField!

    // Vim modal chrome, created in configureVimChrome()
    var vimTabLine: VimTabLine?
    var vimStatus: VimStatusLine?
    var vimCommandLine: VimCommandLine?
    private var vimBufferInfo: VimBufferInfo?
    private var vimInfoGeneration = 0

    public func initWindow() {
        view.window?.title = "New note"
        view.window?.titleVisibility = .hidden
        view.window?.titlebarAppearsTransparent = true
        view.window?.backgroundColor = NSColor(named: "background_win")
        view.window?.delegate = self
        view.window?.setFrameOriginToPositionWindowInCenterOfScreen()
        
        editor.initTextStorage()
        editor.editorViewController = self
        editor.configure()
        
        vcEditor = editor
        vcTitleLabel = titleLabel
        vcNonSelectedLabel = nonSelectedLabel
        vcEditorScrollView = editorScrollView
        
        editor.updateTextContainerInset()

        ViewController.styleTUIChips(preview: previewButton, lock: lockUnlockButton, share: shareButton)
        configureVimChrome()

        super.initView()
    }

    func windowDidResize(_ notification: Notification) {
        editor.updateTextContainerInset()

        super.viewDidResize()
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.noteWindows.removeAll(where: { ($0.contentViewController as? NoteViewController)?.editor.note === editor.note  })
        ViewController.refreshVimTabLines()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateVimChrome()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateVimChrome()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateVimChrome()
    }

    // MARK: - Vim chrome

    /// Tabline above the winbar, and a statusline and command line below the editor, as in the main window.
    private func configureVimChrome() {
        let tabLine = VimTabLine()
        let status = VimStatusLine()
        let commandLine = VimCommandLine()

        for bar in [tabLine, status, commandLine] as [NSView] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
        }

        // The storyboard pins the title bar to the top edge and the editor to the bottom edge; make room for the bars.
        view.constraints
            .filter { ($0.firstItem === titleBarView && $0.firstAttribute == .top)
                || ($0.secondItem === editorScrollView && $0.firstAttribute == .bottom) }
            .forEach { $0.isActive = false }

        NSLayoutConstraint.activate([
            tabLine.topAnchor.constraint(equalTo: view.topAnchor),
            tabLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabLine.heightAnchor.constraint(equalToConstant: VimTabLine.height),
            titleBarView.topAnchor.constraint(equalTo: tabLine.bottomAnchor),

            editorScrollView.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: VimStatusLine.height),

            commandLine.topAnchor.constraint(equalTo: status.bottomAnchor),
            commandLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            commandLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            commandLine.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            commandLine.heightAnchor.constraint(equalToConstant: VimCommandLine.height)
        ])

        ViewController.styleTUIWinbar(titleBar: titleBarView, titleLabel: titleLabel)
        nonSelectedLabel.font = TUITheme.font(ofSize: 13)
        nonSelectedLabel.textColor = TUITheme.dim
        view.window?.backgroundColor = TUITheme.background

        vimTabLine = tabLine
        vimStatus = status
        vimCommandLine = commandLine
    }

    /// Recounts the note off the main thread, then redraws the statusline, command line and tabs.
    override func updateVimChrome() {
        let note = editor.note
        let content = note?.content.string ?? ""
        let selection = editor.selectedRange()

        vimInfoGeneration += 1
        let generation = vimInfoGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let counted = selection.length > 0 ? content.substring(nsRange: selection) ?? content : content
            let info = note.map { _ in
                VimBufferInfo(content: content, caret: selection, words: counted.countWords(), characters: counted.countChars())
            }

            DispatchQueue.main.async {
                guard let self = self, generation == self.vimInfoGeneration else { return }

                self.vimBufferInfo = info
                self.applyVimChrome(note: note)
            }
        }
    }

    private func applyVimChrome(note: Note?) {
        let isKey = view.window?.isKeyWindow ?? false
        let mode: VimMode = editor.isPreviewEnabled()
            ? .preview
            : (view.window?.firstResponder === editor && editor.isEditable ? .insert : .normal)

        ViewController.fillVimEditorStatus(vimStatus, note: note, info: vimBufferInfo)
        vimStatus?.mode = isKey ? mode : nil

        vimCommandLine?.message = isKey ? ViewController.vimCommandLineMessage(mode: mode, search: "") : []
        vimCommandLine?.right = ViewController.vimFileInfo(note: note, info: vimBufferInfo)

        ViewController.refreshVimTabLines()
    }
    
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let fr = window.firstResponder,
            fr.isKind(of: EditTextView.self),
            editor.isEditable {
            return editor.editorViewController?.editorUndoManager
        }
        
        return nil
    }
}
