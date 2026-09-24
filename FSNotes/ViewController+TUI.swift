//
//  ViewController+TUI.swift
//  FSNotes
//
//  Installs the Modern TUI chrome around the storyboard layout: title strip, boxed
//  panes with focus, and the key-hint/status footer.
//

import Cocoa

extension ViewController {
    static let tuiKeyHints: [(key: String, label: String)] = [
        ("⌘N", "new"), ("⌘L", "search/create"), ("⌘/", "preview"), ("⌘T", "todo"), ("⇧⌘T", "move"),
        ("⌘R", "rename"), ("⌘8", "pin"), ("⌥⌘L", "lock"), ("⇧⌘H", "history"), ("⌘S", "commit"),
        ("⌥⌘B", "backlinks"), ("⌘,", "prefs")
    ]

    var tuiPanes: [TUIPaneFrameView] {
        return [tuiSidebarPane, tuiNotesPane, tuiEditorPane].compactMap { $0 }
    }

    func configureTUI() {
        applyTUIEditorColors()
        addTUIBars()

        tuiSidebarPane = addTUIPane(to: sidebarScrollView.superview, number: 1, title: "Library")
        tuiNotesPane = addTUIPane(to: notesListCustomView, number: 2, title: "Notes")
        tuiEditorPane = addTUIPane(to: editAreaScroll.superview, number: 3, title: "Editor")

        styleTUIViews()

        NotificationCenter.default.addObserver(
            self, selector: #selector(tuiFirstResponderDidChange(_:)),
            name: .tuiFirstResponderDidChange, object: nil)
    }

    /// Top offset for content inside a pane, below its title.
    var tuiContentTop: CGFloat {
        return TUIPaneFrameView.contentTop + 2
    }

    // MARK: - Status

    func updateTUIStatus() {
        let location = tuiLocationName()
        let total = notesTableView.countNotes()
        let selected = notesTableView.selectedRowIndexes.count

        tuiNotesPane?.title = location

        if selected > 1 {
            tuiNotesPane?.footer = "\(selected) of \(total) selected"
        } else {
            tuiNotesPane?.footer = total == 1 ? "1 note" : "\(total) notes"
        }

        tuiTitleStrip?.title = "consolinotes — \(location)"

        tuiStatusBar?.statusLeft = [("● ", TUITheme.green), (location, TUITheme.text)]
        tuiStatusBar?.statusRight = [
            ("\(storage.noteList.count) notes · \(storage.getProjects().count) folders", TUITheme.dim)
        ]
    }

    func updateTUIEditorPane(note: Note?, counts: String?) {
        tuiEditorPane?.title = note?.url.lastPathComponent ?? "Editor"
        tuiEditorPane?.footer = counts

        // The chips stay visible, so keep the lock chip in step with the open note.
        lockUnlock.isHidden = note == nil
        lockUnlock.image = TUITheme.lockChip(encrypted: note?.isEncrypted() ?? false, locked: note?.isEncryptedAndLocked() ?? false)
    }

    // MARK: - Private

    /// Markdown colours for the editor. Headers stay at body size so every line sits on the same grid.
    private func applyTUIEditorColors() {
        NotesTextProcessor.syntaxColor = TUITheme.faint
        NotesTextProcessor.headerColor = TUITheme.accent
        NotesTextProcessor.subheaderColor = TUITheme.cyan
        NotesTextProcessor.uniformHeaderSize = true
        NotesTextProcessor.listMarkerColor = TUITheme.accent
        NotesTextProcessor.boldColor = TUITheme.bright
        NotesTextProcessor.strikeColor = TUITheme.dim
        NotesTextProcessor.codeSpanColor = TUITheme.orange
        NotesTextProcessor.linkColor = TUITheme.cyan
        NotesTextProcessor.wikiLinkColor = TUITheme.magenta
        NotesTextProcessor.tagColor = TUITheme.green
    }

    private func addTUIBars() {
        let strip = TUITitleStrip()
        let status = TUIStatusBar()
        status.hints = ViewController.tuiKeyHints

        for bar in [strip, status] as [NSView] {
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
            strip.topAnchor.constraint(equalTo: view.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: TUITitleStrip.height),

            sidebarSplitView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            sidebarSplitView.bottomAnchor.constraint(equalTo: status.topAnchor),

            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: TUIStatusBar.height)
        ])

        tuiTitleStrip = strip
        tuiStatusBar = status
    }

    private func addTUIPane(to container: NSView?, number: Int, title: String) -> TUIPaneFrameView? {
        guard let container = container else { return nil }

        let pane = TUIPaneFrameView()
        pane.number = number
        pane.title = title
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2)
        ])

        return pane
    }

    private func styleTUIViews() {
        let bottom = TUIPaneFrameView.contentBottom + 2

        // Library: the header only reserved room for the traffic lights, which now sit on the title strip.
        outlineHeader.isHidden = true
        sidebarScrollView.automaticallyAdjustsContentInsets = false
        sidebarScrollView.contentInsets = NSEdgeInsets(top: tuiContentTop, left: 4, bottom: bottom, right: 4)
        sidebarOutlineView.backgroundColor = TUITheme.background

        // Notes: the counter moves into the pane footer.
        searchTopConstraint.constant = tuiContentTop
        styleTUISearch()
        newNoteButton.image = TUITheme.glyph("+", color: TUITheme.accent, size: 18, weight: .semibold)
        newNoteButton.isBordered = false
        notesCounterViewHeight.constant = 0
        notesCounter.superview?.isHidden = true
        notesScrollView.automaticallyAdjustsContentInsets = false
        notesScrollView.contentInsets = NSEdgeInsets(top: 0, left: 4, bottom: bottom, right: 4)
        notesTableView.backgroundColor = TUITheme.background
        lockedFolder.font = TUITheme.font(ofSize: 12)

        // Editor: word count moves into the pane footer; the title bar clears the pane title.
        counter.isHidden = true
        heightConstraint(of: counter.superview)?.constant = bottom
        heightConstraint(of: titleBarView)?.constant = 46
        titleLabel.font = TUITheme.font(ofSize: 13, weight: .semibold)
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
            .forEach { $0.constant = 26 }

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            strip.trailingAnchor.constraint(equalTo: newNoteButton.leadingAnchor, constant: -6),
            strip.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            strip.heightAnchor.constraint(equalToConstant: 24),
            prompt.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 7),
            prompt.centerYAnchor.constraint(equalTo: search.centerYAnchor)
        ])
    }

    /// Shared by the main window and separate note windows.
    static func styleTUIChips(preview: NSButton?, lock: NSButton?, share: NSButton?) {
        preview?.image = TUITheme.chip("preview ⌘/")
        lock?.image = TUITheme.lockChip(encrypted: false, locked: false)
        share?.image = TUITheme.chip("share")

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

    private func tuiLocationName() -> String {
        let item = sidebarOutlineView.item(atRow: sidebarOutlineView.selectedRow)

        if let project = item as? Project {
            return project.label
        }

        if let tag = item as? FSTag {
            return "#" + tag.getName()
        }

        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.name
        }

        return "Notes"
    }

    @objc private func tuiFirstResponderDidChange(_ notification: Notification) {
        guard let window = view.window, (notification.object as? NSWindow) === window else { return }

        let responder = window.firstResponder as? NSView

        for pane in tuiPanes {
            guard let container = pane.superview else { continue }
            pane.isFocused = responder?.isDescendant(of: container) ?? false
        }
    }
}
