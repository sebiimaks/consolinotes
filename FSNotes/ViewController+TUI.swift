//
//  ViewController+TUI.swift
//  FSNotes
//
//  Installs the Vim modal chrome around the storyboard layout: a tabline, a statusline
//  under each window (library, notes, editor) and a command line at the bottom.
//

import Cocoa

/// Caret and size details of the open note, for the editor statusline and the command line.
struct VimBufferInfo {
    let words: Int
    let characters: Int
    let line: Int
    let column: Int
    let lineCount: Int
    let byteCount: Int

    init(content: String, caret: NSRange?, words: Int, characters: Int) {
        let string = content as NSString
        let location = min(caret?.location ?? 0, string.length)
        let prefix = string.substring(to: location)
        let lineStart = (prefix as NSString).range(of: "\n", options: .backwards)

        self.words = words
        self.characters = characters
        // Count bytes, not Characters: Swift treats "\r\n" as one Character.
        self.line = prefix.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        self.column = location - (lineStart.location == NSNotFound ? 0 : NSMaxRange(lineStart)) + 1
        // The empty line after a trailing newline counts, as the gutter numbers it and the caret can sit there.
        self.lineCount = content.isEmpty ? 0 : content.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        self.byteCount = content.utf8.count
    }
}

extension ViewController {
    static let vimKeyHints = "⌘L /  ⌘N new  ⌘/ preview  ⇧⌘T move  ⌘R rename  ⌘, prefs"

    func configureTUI() {
        applyTUIEditorColors()
        addVimBars()

        vimSidebarStatus = addVimStatusLine(to: sidebarScrollView.superview)
        vimNotesStatus = addVimStatusLine(to: notesListCustomView)
        vimEditorStatus = addVimStatusLine(to: editAreaScroll.superview)
        vimSidebarStatus?.name = "library"

        styleTUIViews()

        NotificationCenter.default.addObserver(
            self, selector: #selector(tuiFirstResponderDidChange(_:)),
            name: .tuiFirstResponderDidChange, object: nil)

        // The command line echoes the search as it is typed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(tuiSearchDidChange(_:)),
            name: NSControl.textDidChangeNotification, object: search)

        // Only the key window shows a mode, as only Vim's current window does.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(tuiFirstResponderDidChange(_:)), name: name, object: nil)
        }

        updateTUIStatus()
    }

    /// Top offset for the search field in the notes window.
    var tuiContentTop: CGFloat {
        return 6
    }

    // MARK: - Status

    func updateTUIStatus() {
        let total = notesTableView.countNotes()
        let selected = notesTableView.selectedRowIndexes.count

        vimNotesStatus?.name = tuiLocationName()
        vimNotesStatus?.right = [selected > 1 ? "\(selected)/\(total) sel" : (total == 1 ? "1 note" : "\(total) notes")]

        updateVimMode()
    }

    func updateTUIEditorPane(note: Note?, info: VimBufferInfo?) {
        vimBufferInfo = info

        ViewController.fillVimEditorStatus(vimEditorStatus, note: note, info: info)
        ViewController.refreshVimTabLines()

        // The chips stay visible, so keep the lock chip in step with the open note.
        lockUnlock.isHidden = note == nil
        lockUnlock.image = TUITheme.lockChip(encrypted: note?.isEncrypted() ?? false, locked: note?.isEncryptedAndLocked() ?? false)

        updateVimMode()
    }

    override func updateVimChrome() {
        updateVimMode()
    }

    /// Works out the mode from keyboard focus and puts it on the focused window's statusline.
    func updateVimMode() {
        let responder = view.window?.firstResponder
        let responderView = responder as? NSView
        let editorContainer = editAreaScroll.superview

        var mode = VimMode.normal
        var focused = vimNotesStatus

        if let fieldEditor = search.currentEditor(), responder === fieldEditor {
            mode = .command
        } else if let container = editorContainer, responderView?.isDescendant(of: container) == true {
            focused = vimEditorStatus
            mode = editor.isPreviewEnabled() ? .preview : (editor.isEditable ? .insert : .normal)
        } else if let container = sidebarScrollView.superview, responderView?.isDescendant(of: container) == true {
            focused = vimSidebarStatus
        }

        let isKey = view.window?.isKeyWindow ?? false

        for status in [vimSidebarStatus, vimNotesStatus, vimEditorStatus] {
            status?.mode = isKey && status === focused ? mode : nil
        }

        vimCommandLine?.message = isKey ? ViewController.vimCommandLineMessage(mode: mode, search: search.stringValue) : []
        vimCommandLine?.right = ViewController.vimFileInfo(note: editor.note, info: vimBufferInfo)
    }

    // MARK: - Shared with note windows

    static func vimCommandLineMessage(mode: VimMode, search: String) -> [TUISegment] {
        switch mode {
        case .insert:
            return [("-- INSERT --", TUITheme.bright)]
        case .preview:
            return [("-- PREVIEW --", TUITheme.bright)]
        case .command:
            return [("/", TUITheme.accent), (search, TUITheme.text)]
        case .normal:
            return [(vimKeyHints, TUITheme.faint)]
        }
    }

    /// Vim's file message, like `"plan.md" 42L, 1234B`.
    static func vimFileInfo(note: Note?, info: VimBufferInfo?) -> [TUISegment] {
        guard let note = note, let info = info else { return [] }

        return [("\"\(tuiFileName(note))\" \(info.lineCount)L, \(info.byteCount)B", TUITheme.dim)]
    }

    static func fillVimEditorStatus(_ status: VimStatusLine?, note: Note?, info: VimBufferInfo?) {
        status?.name = note.map { $0.project.label + "/" + tuiFileName($0) } ?? "[No Name]"
        status?.flags = note?.isEncryptedAndLocked() == true ? "[RO]" : ""
        status?.right = info.map { ["markdown", "utf-8", "\($0.words)w \($0.characters)c"] } ?? []
        status?.position = info.map { "\($0.line):\($0.column)" } ?? ""
    }

    /// Every window shows the same tabs: the main window's note first, then each note window's.
    static func refreshVimTabLines() {
        let main = ViewController.shared()
        let windows = AppDelegate.noteWindows.compactMap { $0.contentViewController as? NoteViewController }
        let names = [main?.editor.note] + windows.map { $0.editor.note }
        let tabs = names.map { $0.map { tuiFileName($0) } ?? "[No Name]" }

        main?.vimTabLine?.tabs = tabs
        main?.vimTabLine?.activeIndex = 0

        for (index, window) in windows.enumerated() {
            window.vimTabLine?.tabs = tabs
            window.vimTabLine?.activeIndex = index + 1
        }
    }

    /// The note title becomes a left-aligned winbar, like Neovim's, instead of a centred title.
    static func styleTUIWinbar(titleBar: NSView, titleLabel: NSTextField) {
        titleBar.constraints
            .first { $0.firstAttribute == .height && $0.secondItem == nil }?
            .constant = 26
        titleLabel.font = TUITheme.font(ofSize: 12, weight: .semibold)
        titleLabel.textColor = TUITheme.dim
        titleLabel.alignment = .left

        for constraint in titleBar.constraints where constraint.firstItem === titleLabel || constraint.secondItem === titleLabel {
            switch constraint.firstAttribute {
            case .centerX:
                constraint.isActive = false
            case .leading:
                constraint.constant = 10
            default:
                break
            }
        }

        titleLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 10).isActive = true
    }

    // MARK: - Private

    /// Markdown colours for the editor. Headers stay at body size so every line sits on the same grid.
    private func applyTUIEditorColors() {
        NotesTextProcessor.syntaxColor = TUITheme.faint
        NotesTextProcessor.headerColor = TUITheme.orange
        NotesTextProcessor.subheaderColor = TUITheme.yellow
        NotesTextProcessor.uniformHeaderSize = true
        NotesTextProcessor.listMarkerColor = TUITheme.accent
        NotesTextProcessor.boldColor = TUITheme.bright
        NotesTextProcessor.strikeColor = TUITheme.dim
        NotesTextProcessor.codeSpanColor = TUITheme.green
        NotesTextProcessor.linkColor = TUITheme.cyan
        NotesTextProcessor.wikiLinkColor = TUITheme.magenta
        NotesTextProcessor.tagColor = TUITheme.green
    }

    private func addVimBars() {
        let tabLine = VimTabLine()
        let commandLine = VimCommandLine()

        for bar in [tabLine, commandLine] as [NSView] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
        }

        // The split view is pinned to the top and bottom edges in the storyboard; make room for the bars.
        let edges: [NSLayoutConstraint.Attribute] = [.top, .bottom]
        view.constraints
            .filter { ($0.firstItem === sidebarSplitView || $0.secondItem === sidebarSplitView)
                && edges.contains($0.firstAttribute) }
            .forEach { $0.isActive = false }

        NSLayoutConstraint.activate([
            tabLine.topAnchor.constraint(equalTo: view.topAnchor),
            tabLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabLine.heightAnchor.constraint(equalToConstant: VimTabLine.height),

            sidebarSplitView.topAnchor.constraint(equalTo: tabLine.bottomAnchor),
            sidebarSplitView.bottomAnchor.constraint(equalTo: commandLine.topAnchor),

            commandLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            commandLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            commandLine.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            commandLine.heightAnchor.constraint(equalToConstant: VimCommandLine.height)
        ])

        vimTabLine = tabLine
        vimCommandLine = commandLine
    }

    /// Pins a statusline across the bottom of a window, above its content.
    private func addVimStatusLine(to container: NSView?) -> VimStatusLine? {
        guard let container = container else { return nil }

        let status = VimStatusLine()
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: VimStatusLine.height)
        ])

        return status
    }

    private func styleTUIViews() {
        let bottom = VimStatusLine.height

        // Library: a NERDTree-style tree. The header only reserved room for the traffic lights.
        outlineHeader.isHidden = true
        sidebarScrollView.automaticallyAdjustsContentInsets = false
        sidebarScrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: bottom, right: 0)
        sidebarScrollView.contentView.contentInsets = sidebarScrollView.contentInsets
        sidebarScrollView.scrollerInsets = NSEdgeInsetsZero
        sidebarOutlineView.backgroundColor = TUITheme.background

        // Notes: the counter moves into the statusline.
        searchTopConstraint.constant = tuiContentTop
        styleTUISearch()
        newNoteButton.image = TUITheme.glyph("+", color: TUITheme.accent, size: 18, weight: .semibold)
        newNoteButton.isBordered = false
        notesCounterViewHeight.constant = 0
        notesCounter.superview?.isHidden = true
        notesScrollView.automaticallyAdjustsContentInsets = false
        notesScrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        notesTableView.backgroundColor = TUITheme.background
        lockedFolder.font = TUITheme.font(ofSize: 12)

        // Editor: the word count moves into the statusline, which covers the old counter bar.
        counter.isHidden = true
        if let counterBar = counter.superview, let container = counterBar.superview {
            heightConstraint(of: counterBar)?.constant = bottom
            container.constraints
                .filter { $0.firstItem === counterBar && $0.firstAttribute == .top }
                .forEach { $0.constant = 0 }
        }
        ViewController.styleTUIWinbar(titleBar: titleBarView, titleLabel: titleLabel)
        nonSelectedLabel.font = TUITheme.font(ofSize: 13)
        nonSelectedLabel.textColor = TUITheme.dim

        // Title bar buttons become text chips that stay visible, like a status line.
        ViewController.styleTUIChips(preview: previewButton, lock: lockUnlock, share: shareButton)
        lockUnlock.isHidden = true
        titleBarAdditionalView.alphaValue = 1
        titleBarView.onMouseExitedClosure = nil
    }

    /// Flat input line with a "/" prompt instead of a rounded search field with a magnifier.
    private func styleTUISearch() {
        search.font = TUITheme.font(ofSize: 12)
        search.textColor = TUITheme.text
        search.isBezeled = false
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none

        if let cell = search.cell as? NSSearchFieldCell {
            // The "/" prompt replaces the magnifier (and opens recent searches); keep the clear button as "×".
            cell.searchButtonCell = nil
            cell.cancelButtonCell?.image = TUITheme.glyph("×", color: TUITheme.dim, size: 14)
            cell.cancelButtonCell?.alternateImage = TUITheme.glyph("×", color: TUITheme.text, size: 14)
            cell.placeholderAttributedString = NSAttributedString(string: "search or create", attributes: [
                .font: TUITheme.font(ofSize: 12),
                .foregroundColor: TUITheme.faint
            ])
        }

        // The input strip and prompt sit behind and beside the borderless field.
        guard let container = search.superview else { return }

        let strip = TUIFillView()
        strip.color = TUITheme.bar

        // Clicking the prompt opens recent searches, as the magnifier did.
        let prompt = NSButton(title: "/", target: self, action: #selector(openRecentPopup(_:)))
        prompt.isBordered = false
        prompt.attributedTitle = NSAttributedString(string: "/", attributes: [
            .font: TUITheme.font(ofSize: 13, weight: .semibold),
            .foregroundColor: TUITheme.accent
        ])
        prompt.toolTip = NSLocalizedString("Recent searches", comment: "")

        for view in [strip, prompt] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(strip, positioned: .below, relativeTo: search)
        container.addSubview(prompt, positioned: .above, relativeTo: strip)

        container.constraints
            .filter { $0.firstItem === search && $0.firstAttribute == .leading && $0.secondItem === container }
            .forEach { $0.constant = 24 }

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            strip.trailingAnchor.constraint(equalTo: newNoteButton.leadingAnchor, constant: -6),
            strip.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            strip.heightAnchor.constraint(equalToConstant: 22),
            prompt.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 6),
            prompt.centerYAnchor.constraint(equalTo: search.centerYAnchor)
        ])
    }

    /// Shared by the main window and separate note windows.
    static func styleTUIChips(preview: NSButton?, lock: NSButton?, share: NSButton?) {
        preview?.image = TUITheme.chip(":preview", background: .clear)
        lock?.image = TUITheme.lockChip(encrypted: false, locked: false)
        share?.image = TUITheme.chip(":share", background: .clear)

        for button in [preview, lock, share].compactMap({ $0 }) {
            button.isBordered = false
            button.imageScaling = .scaleNone

            // The storyboard sized these for 16pt icons; fit the chip instead.
            guard let size = button.image?.size else { continue }
            for constraint in button.constraints where constraint.secondItem == nil {
                if constraint.firstAttribute == .width { constraint.constant = size.width }
                if constraint.firstAttribute == .height { constraint.constant = size.height }
            }
        }
    }

    private func heightConstraint(of view: NSView?) -> NSLayoutConstraint? {
        return view?.constraints.first { $0.firstAttribute == .height && $0.secondItem == nil }
    }

    /// The buffer name for a note. A TextBundle is named after its markdown text, not the bundle folder.
    static func tuiFileName(_ note: Note) -> String {
        return note.isTextBundle()
            ? note.getFileName() + "." + note.getExtensionForContainer()
            : note.url.lastPathComponent
    }

    private func tuiLocationName() -> String {
        let item = sidebarOutlineView.item(atRow: sidebarOutlineView.selectedRow)

        if let project = item as? Project {
            return project.label + "/"
        }

        if let tag = item as? FSTag {
            return "#" + tag.getName()
        }

        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.name.lowercased()
        }

        return "notes"
    }

    @objc private func tuiFirstResponderDidChange(_ notification: Notification) {
        guard let window = view.window, (notification.object as? NSWindow) === window else { return }

        updateVimMode()
    }

    @objc private func tuiSearchDidChange(_ notification: Notification) {
        updateVimMode()
    }
}
