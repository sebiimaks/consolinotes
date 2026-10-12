// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.
import Cocoa

/// A find bar whose query never enters the system Find pasteboard.
final class PrivateTextFinder: NSObject {
    private weak var editor: EditTextView?
    private let query = NSSearchField()
    private let replacement = NSTextField()
    private let bar = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 72))
    private let replaceRow = NSStackView()
    private let status = NSTextField(labelWithString: "")

    init(editor: EditTextView) {
        self.editor = editor
        super.init()
        query.placeholderString = "Find in this note"
        query.recentsAutosaveName = nil
        query.maximumRecents = 0
        query.sendsSearchStringImmediately = true
        query.target = self; query.action = #selector(queryChanged)
        query.setAccessibilityLabel("Find in this note")
        replacement.placeholderString = "Replace with"
        replacement.setAccessibilityLabel("Replacement text")
        let row = NSStackView(views: [query, button("Previous", #selector(previous)), button("Next", #selector(next)), status, button("Done", #selector(done))])
        row.spacing = 6
        replaceRow.setViews([replacement, button("Replace", #selector(replace)), button("Replace All", #selector(replaceAll))], in: .leading)
        replaceRow.spacing = 6
        let stack = NSStackView(views: [row, replaceRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            replaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            query.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            replacement.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func perform(tag: Int) {
        guard let action = NSTextFinder.Action(rawValue: tag) else { return }
        // Locking must be able to dismiss the bar even after access is revoked.
        if action == .hideFindInterface { close(clear: true); return }
        if action == .hideReplaceInterface {
            replacement.currentEditor()?.string = ""
            replacement.stringValue = ""
            replaceRow.isHidden = true
            return
        }
        guard let editor = editor, editor.note?.isEncryptedAndLocked() == false else { return }
        switch action {
        case .nextMatch: find(backwards: false)
        case .previousMatch: find(backwards: true)
        case .replace: performReplacement(findNext: false)
        case .replaceAndFind: performReplacement(findNext: true)
        case .replaceAll: replaceAll()
        case .setSearchString:
            if let selection = editor.attributedSubstring(forProposedRange: editor.selectedRange(), actualRange: nil)?.string {
                LocalFindState.query = selection; query.stringValue = selection
            }
        case .showFindInterface, .showReplaceInterface:
            query.stringValue = LocalFindState.query
            replaceRow.isHidden = action != .showReplaceInterface
            editor.enclosingScrollView?.findBarView = bar
            editor.enclosingScrollView?.isFindBarVisible = true
            editor.window?.makeFirstResponder(query)
        default: return
        }
    }

    func close(clear: Bool) {
        editor?.enclosingScrollView?.isFindBarVisible = false
        if clear {
            query.currentEditor()?.string = ""; replacement.currentEditor()?.string = ""
            query.stringValue = ""; replacement.stringValue = ""; status.stringValue = ""
        }
    }

    @objc private func done() { close(clear: true); editor?.window?.makeFirstResponder(editor) }
    @objc private func queryChanged() { LocalFindState.query = query.stringValue; status.stringValue = "" }
    @objc private func next() { find(backwards: false) }
    @objc private func previous() { find(backwards: true) }

    private func find(backwards: Bool) {
        guard let editor = editor, editor.note?.isEncryptedAndLocked() == false else { return }
        let term = LocalFindState.query
        query.stringValue = term
        guard !term.isEmpty else { perform(tag: NSTextFinder.Action.showFindInterface.rawValue); return }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let start = min(backwards ? selection.location : NSMaxRange(selection), text.length)
        let range = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: text.length - start)
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        var match = text.range(of: term, options: options, range: range)
        if match.location == NSNotFound { match = text.range(of: term, options: options) }
        guard match.location != NSNotFound else { status.stringValue = "Not found"; return }
        editor.setSelectedRange(match); editor.scrollRangeToVisible(match)
        status.stringValue = ""
    }

    @objc private func replace() { performReplacement(findNext: false) }

    private func performReplacement(findNext: Bool) {
        guard let editor = editor, editor.isEditable, editor.note?.isEncryptedAndLocked() == false,
              !LocalFindState.query.isEmpty,
              let selected = editor.attributedSubstring(forProposedRange: editor.selectedRange(), actualRange: nil)?.string,
              selected.caseInsensitiveCompare(LocalFindState.query) == .orderedSame else { next(); return }
        editor.insertText(replacement.stringValue, replacementRange: editor.selectedRange())
        if findNext { next() }
    }

    @objc private func replaceAll() {
        guard let editor = editor, editor.isEditable, editor.note?.isEncryptedAndLocked() == false else { return }
        let term = LocalFindState.query
        guard !term.isEmpty else { return }
        let text = editor.string as NSString
        var matches = [NSRange](), offset = 0
        while offset < text.length {
            let range = text.range(of: term, options: .caseInsensitive, range: NSRange(location: offset, length: text.length - offset))
            if range.location == NSNotFound { break }
            matches.append(range); offset = NSMaxRange(range)
        }
        guard !matches.isEmpty, let storage = editor.textStorage else {
            status.stringValue = "Not found"
            return
        }
        let replacementText = replacement.stringValue
        // One text change prevents autosaving the note once for every match.
        // AppKit records the matching ranges for a single undoable operation.
        guard editor.shouldChangeText(inRanges: matches.map { NSValue(range: $0) },
                                      replacementStrings: matches.map { _ in replacementText }) else { return }
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        for range in matches.reversed() { storage.replaceCharacters(in: range, with: replacementText) }
        storage.endEditing()
        editor.didChangeText()
        editor.undoManager?.endUndoGrouping()
        editor.breakUndoCoalescing()
        status.stringValue = "Replaced \(matches.count)"
    }
}
