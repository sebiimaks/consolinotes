#!/usr/bin/env python3
"""Synthetic AppKit regressions for production private Find and rich drag handling.

Uses a uniquely named pasteboard only, temporary editor windows and in-memory
notes. The real app, general/Find clipboard, notes and preferences are untouched.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
def method(path, name):
    text = (ROOT / path).read_text(); start = text.index(name); brace = text.index('{', start); level = 1; end = brace + 1
    while level:
        if text[end] == '{': level += 1
        elif text[end] == '}': level -= 1
        end += 1
    return text[start:end]

fixture = r'''
import Cocoa
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
final class Note { var locked = false; func isEncryptedAndLocked() -> Bool { locked } }
final class EditTextView: NSTextView {
    var note: Note? = Note()
    var dragDetected = false
    var changes = 0
    let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
    override func didChangeText() { super.didChangeText(); changes += 1 }
}
extension NSMutableAttributedString {
__UNLOAD_TASKS__
    // These fixtures contain no task glyphs; task serialization has its own test.
    func loadTasks() {}
}
extension EditTextView {
__DRAG__
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
editor.isEditable = true; editor.isRichText = true; editor.allowsUndo = true
let scroll = NSScrollView(frame: editor.frame)
scroll.documentView = editor
let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = scroll
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(editor)
let finder = PrivateTextFinder(editor: editor)
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func fields() -> [NSTextField] { descendants(scroll.findBarView!).compactMap { $0 as? NSTextField } }
func field(_ placeholder: String) -> NSTextField { fields().first { $0.placeholderString == placeholder }! }
func click(_ title: String) {
    let button = descendants(scroll.findBarView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
    button.performClick(nil)
}
func query(_ text: String) {
    let value = field("Find in this note") as! NSSearchField
    value.stringValue = text
    _ = value.sendAction(value.action, to: value.target)
}
editor.string = "First café second CAFÉ third café"
finder.perform(tag: NSTextFinder.Action.showFindInterface.rawValue)
expect(scroll.isFindBarVisible, "Find did not open")
query("café")
expect(LocalFindState.query == "café", "Query was not held locally")
editor.setSelectedRange(NSRange(location: 0, length: 0))
finder.perform(tag: NSTextFinder.Action.nextMatch.rawValue)
expect(editor.selectedRange() == NSRange(location: 6, length: 4), "First Unicode match wrong")
finder.perform(tag: NSTextFinder.Action.nextMatch.rawValue)
expect(editor.selectedRange() == NSRange(location: 18, length: 4), "Case-insensitive match wrong")
finder.perform(tag: NSTextFinder.Action.previousMatch.rawValue)
expect(editor.selectedRange() == NSRange(location: 6, length: 4), "Backward match wrong")
finder.perform(tag: NSTextFinder.Action.previousMatch.rawValue)
expect(editor.selectedRange() == NSRange(location: 29, length: 4), "Backward wrap wrong")
finder.perform(tag: NSTextFinder.Action.nextMatch.rawValue)
expect(editor.selectedRange() == NSRange(location: 6, length: 4), "Forward wrap wrong")
finder.perform(tag: NSTextFinder.Action.setSearchString.rawValue)
expect(LocalFindState.query == "café", "Selection-to-find failed")
finder.perform(tag: NSTextFinder.Action.showReplaceInterface.rawValue)
field("Replace with").stringValue = "tea"
click("Replace")
expect(editor.string == "First tea second CAFÉ third café", "Single replacement failed")
editor.string = "cat CAT cat"
editor.setSelectedRange(NSRange(location: 0, length: 0))
query("cat"); field("Replace with").stringValue = "dog"
editor.localUndo.removeAllActions(); editor.changes = 0
click("Replace All")
expect(editor.string == "dog dog dog", "Replace All failed")
expect(editor.changes == 1, "Replace All emitted a separate save for every match")
expect(editor.localUndo.canUndo, "Replace All was not undoable")
editor.localUndo.undo()
expect(editor.string == "cat CAT cat", "Replace All undo lost original content")
editor.note!.locked = true
let before = editor.string
finder.perform(tag: NSTextFinder.Action.showReplaceInterface.rawValue)
click("Replace All")
expect(editor.string == before, "Shielded note was modified")
finder.perform(tag: NSTextFinder.Action.hideFindInterface.rawValue)
expect(!scroll.isFindBarVisible, "Shielded Find bar failed to close")
expect(field("Find in this note").stringValue.isEmpty && field("Replace with").stringValue.isEmpty, "Find retained cleared text")
editor.note!.locked = false
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally(); window.orderOut(nil) }
func payload(_ text: String) {
    board.clearContents()
    board.setData(NotePasteboardCodec.encode(NSAttributedString(string: text))!, forType: NSPasteboard.attributed)
}
func drop(at location: Int) -> Bool {
    editor.handleAttributedText(board, note: editor.note!, storage: editor.textStorage!, replacementRange: NSRange(location: location, length: 0))
}
editor.string = "abcdef"
editor.setSelectedRange(NSRange(location: 1, length: 2)); editor.dragDetected = true
board.setData(Data("invalid archive".utf8), forType: NSPasteboard.attributed)
expect(!drop(at: 6), "Invalid rich payload accepted")
expect(editor.string == "abcdef" && editor.selectedRange() == NSRange(location: 1, length: 2), "Rejected drop changed selection/content")
payload("bc")
expect(!drop(at: 2), "Move into selection accepted")
expect(editor.string == "abcdef", "Self-overlap drop lost content")
expect(!drop(at: 99), "Out-of-range drop accepted")
expect(editor.string == "abcdef", "Out-of-range drop lost content")
editor.dragDetected = false
expect(drop(at: 6), "External rich drop rejected")
expect(editor.string == "abcdefbc", "External drop deleted current selection")
editor.string = "abcdef"; editor.setSelectedRange(NSRange(location: 1, length: 2)); editor.dragDetected = true
expect(drop(at: 6), "Valid forward move rejected")
expect(editor.string == "adefbc" && editor.selectedRange() == NSRange(location: 4, length: 2), "Forward move corrupted text/selection")
payload("ef")
editor.string = "abcdef"; editor.setSelectedRange(NSRange(location: 4, length: 2)); editor.dragDetected = true
expect(drop(at: 0), "Valid backward move rejected")
expect(editor.string == "efabcd" && editor.selectedRange() == NSRange(location: 0, length: 2), "Backward move corrupted text/selection")
editor.note!.locked = true; editor.dragDetected = false
expect(!drop(at: 0) && editor.string == "efabcd", "Shielded note accepted a drop")
print("PASS: private Find Unicode/case/wrap, replace/undo/batched save, shield/close; invalid/external/self drag moves")
'''
fixture = fixture.replace('__UNLOAD_TASKS__', method('FSNotesCore/Extensions/NSMutableAttributedString+.swift', '    public func unloadTasks()'))
fixture = fixture.replace('__DRAG__', method('FSNotes/View/EditTextView+DragOperation.swift', '    public func handleAttributedText('))
with tempfile.TemporaryDirectory(prefix='consolinotes-private-editor-') as temporary:
    work = Path(temporary); (work/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(work/'modules'),
        str(ROOT/'FSNotesCore/Extensions/NSAttributedStringKey+.swift'),
        str(ROOT/'FSNotesCore/Extensions/Pasteboard.swift'),
        str(ROOT/'FSNotes/Helpers/PrivateTextFinder.swift'),
        str(work/'main.swift'),'-o',str(work/'test')],check=True)
    subprocess.run([str(work/'test')],check=True,timeout=20)
