#!/usr/bin/env python3
"""Exercise production cut/paste with synthetic notes and a unique pasteboard."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
def method(path, name):
    text = (ROOT/path).read_text(); start = text.index(name); brace = text.index('{', start); end = brace + 1; depth = 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
fixture = r'''
import Cocoa
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let app = NSApplication.shared
let board = NSPasteboard.withUniqueName()
defer { SensitiveClipboard.clearOwned(); board.releaseGlobally() }
final class Note { var locked = false; func isEncryptedAndLocked() -> Bool { locked } }
class RecordingTextView: NSTextView {
    var fallbackPastes = 0
    override func paste(_ sender: Any?) { fallbackPastes += 1 }
}
final class EditTextView: RecordingTextView {
    var note: Note? = Note()
    var deletedAttachment: URL?
    let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
    func getParagraphRange() -> NSRange? { NSRange(location: 0, length: textStorage!.length) }
    func saveFile(url: URL, in note: Note) -> Bool { false }
    override func insertText(_ text: Any, replacementRange: NSRange) {
        if let deletion = text as? String, deletion.isEmpty, let url = deletedAttachment {
            try? FileManager.default.removeItem(at: url)
            deletedAttachment = nil
        }
        super.insertText(text, replacementRange: replacementRange)
    }
__CUT__
__PASTE__
}
extension String { func trim() -> String { trimmingCharacters(in: .whitespacesAndNewlines) } }
extension NSMutableAttributedString {
__UNLOAD_TASKS__
    func unloadAttachments() -> NSMutableAttributedString { unloadTasks() }
    func loadTasks() {}
    static func build(data: Data) -> NSMutableAttributedString? { nil }
}
let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
editor.isRichText = true; editor.isEditable = true; editor.allowsUndo = true
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let file = root.appendingPathComponent("cut %.png")
let bytes = Data([1, 2, 3, 4])
try bytes.write(to: file)
let attachment = NSMutableAttributedString(attachment: NSTextAttachment())
attachment.addAttributes([.attachmentUrl:file, .attachmentPath:"i/cut.png"], range: NSRange(location:0,length:1))
editor.textStorage!.setAttributedString(attachment)
editor.setSelectedRange(NSRange(location:0,length:1)); editor.deletedAttachment = file
editor.cut(nil)
expect(editor.string.isEmpty && !FileManager.default.fileExists(atPath:file.path), "Cut did not remove fixture")
editor.paste(nil)
expect(editor.textStorage!.length == 1, "Cut attachment was not pasted")
expect(editor.textStorage!.attribute(.attachmentSave, at:0, effectiveRange:nil) as? Data == bytes, "Cut lost attachment bytes after source deletion")
// A failed serialization must preserve both editor content and the existing clipboard.
let oversized = Data(repeating:0, count:NotePasteboardCodec.maximumAttachmentBytes + 1)
try oversized.write(to:file)
editor.textStorage!.setAttributedString(attachment); editor.setSelectedRange(NSRange(location:0,length:1))
board.clearContents(); board.setString("earlier clipboard", forType:.string)
editor.cut(nil)
expect(editor.textStorage!.length == 1 && FileManager.default.fileExists(atPath:file.path), "Rejected cut deleted content")
expect(board.string(forType:.string) == "earlier clipboard", "Rejected cut replaced clipboard")
// AppKit must never receive supported-but-rejected representations through fallback.
editor.string = "keep"; editor.setSelectedRange(NSRange(location:0,length:4))
board.clearContents(); board.setString(String(repeating:"x", count:NotePasteboardCodec.maximumTextBytes+1), forType:.string)
editor.paste(nil)
expect(editor.string == "keep" && editor.fallbackPastes == 0, "Oversized text escaped through fallback")
board.clearContents(); board.setData(oversized, forType:.png)
editor.paste(nil)
expect(editor.string == "keep" && editor.fallbackPastes == 0, "Oversized image escaped through fallback")
board.clearContents(); board.setData(Data("malformed".utf8), forType:NSPasteboard.attributed)
editor.paste(nil)
expect(editor.string == "keep" && editor.fallbackPastes == 0, "Malformed rich paste reached fallback")
board.clearContents(); board.setString("accepted", forType:.string)
editor.paste(nil)
expect(editor.string == "accepted", "Ordinary text paste failed")
editor.note!.locked = true; editor.setSelectedRange(NSRange(location:0,length:8))
editor.cut(nil); editor.paste(nil)
expect(editor.string == "accepted", "Locked editor changed")
print("PASS: cut attachment bytes survive source deletion; failed cuts preserve content; oversized/malformed paste rejected without fallback")
'''
fixture = fixture.replace('__CUT__', method('FSNotes/View/EditTextView.swift','    override func cut(').replace('requireCompleteContent: true', 'to: board, requireCompleteContent: true'))
fixture = fixture.replace('__PASTE__', method('FSNotes/View/EditTextView.swift','    override func paste(').replace('NSPasteboard.general', 'board'))
fixture = fixture.replace('__UNLOAD_TASKS__', method('FSNotesCore/Extensions/NSMutableAttributedString+.swift','    public func unloadTasks()'))
with tempfile.TemporaryDirectory(prefix='consolinotes-editor-clipboard-') as temporary:
    work=Path(temporary); (work/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(work/'modules'),
        str(ROOT/'FSNotesCore/Extensions/NSAttributedStringKey+.swift'),
        str(ROOT/'FSNotesCore/Extensions/Pasteboard.swift'),str(work/'main.swift'),'-o',str(work/'test')],check=True)
    subprocess.run([str(work/'test'),str(work)],check=True,timeout=30)
