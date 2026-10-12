#!/usr/bin/env python3
"""Exercise the production watcher reload gate with synthetic note transitions."""
from pathlib import Path
import re
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "FSNotes/Helpers/FileSystemEventManager.swift").read_text()
start = source.index("    private func reloadNote(note:")
end = source.index("\n    }", start) + len("\n    }")
method = source[start:end]
delegate_declaration = re.search(r"^    private (?:weak var|unowned let) delegate: ViewController\??$", source, re.M).group()
FIXTURE = r'''
import Foundation
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
extension Date { func isGreaterThan(_ other: Date) -> Bool { self > other } }
extension NSMutableAttributedString { func loadAttachments(_ note: Note) -> NSMutableAttributedString { self } }
final class Note: NSObject {
    var isBlocked = false
    var shielded = false
    var encrypted = true
    var lastWriteError: String?
    var modifiedLocalAt = Date(timeIntervalSince1970: 1)
    var creationDate: Date? = Date(timeIntervalSince1970: 1)
    var cacheHash: Int? = 42
    var content = NSMutableAttributedString(string: "unsaved retained edits")
    var url = URL(fileURLWithPath: "/synthetic/note.etp")
    var password: String? = "synthetic"
    var reads = 0
    var unlocks = 0
    var duringRead: (() -> Void)?
    var failReload = false
    var changeTags = false
    func isEncryptedAndLocked() -> Bool { shielded }
    func isEncrypted() -> Bool { encrypted }
    func getFileModifiedDate() -> Date? { Date(timeIntervalSince1970: 2) }
    func getFileCreationDate() -> Date? { creationDate }
    func getContent() -> NSMutableAttributedString? {
        reads += 1
        duringRead?()
        return NSMutableAttributedString(string: "older disk contents")
    }
    func unLock(password: String, reload: Bool) -> Bool {
        unlocks += 1
        guard !shielded else { return false }
        if failReload { lastWriteError = "synthetic reload failure"; return false }
        content = NSMutableAttributedString(string: "authenticated incoming content")
        return true
    }
    func scanContentTags() -> ([String], [String]) { changeTags ? (["new"], ["old"]) : ([], []) }
    func loadPreviewInfo() { }
}
final class Sidebar { func insertTags(note: Note) { }; func removeTags(_ tags: [String]) { } }
final class Table { func reloadRow(note: Note) { }; func reloadDate(note: Note) { } }
final class Delegate { let sidebarOutlineView = Sidebar(); let notesTableView = Table(); func reSort(note: Note) { } }
typealias ViewController = Delegate
final class Controller { func refillEditArea(force: Bool) { } }
final class Editor { var note: Note?; var editorViewController: Controller? }
enum AppDelegate { static func getEditTextViews() -> [Editor] { [] } }
final class Watcher {
''' + delegate_declaration + r'''
    init(delegate: Delegate) { self.delegate = delegate }
    func perform(_ note: Note) { reloadNote(note: note) }
''' + method + r'''
}
let delegate = Delegate()
let watcher = Watcher(delegate: delegate)
let shielded = Note()
shielded.shielded = true
watcher.perform(shielded)
expect(shielded.reads == 0 && shielded.unlocks == 0, "Watcher read a shielded note")
expect(shielded.content.string == "unsaved retained edits", "Watcher replaced shielded edits")
let failed = Note()
failed.lastWriteError = "synthetic write failure"
watcher.perform(failed)
expect(failed.reads == 0 && failed.unlocks == 0, "Watcher overwrote pending failed save")
let lateShield = Note()
lateShield.duringRead = { lateShield.shielded = true }
watcher.perform(lateShield)
expect(lateShield.content.string == "unsaved retained edits", "Late shield was ignored")
let lateFailure = Note()
lateFailure.duringRead = { lateFailure.lastWriteError = "synthetic late failure" }
lateFailure.failReload = true
watcher.perform(lateFailure)
expect(lateFailure.content.string == "unsaved retained edits", "Late failure replaced retained edits")
let failedDecrypt = Note()
failedDecrypt.failReload = true
watcher.perform(failedDecrypt)
expect(failedDecrypt.content.string == "unsaved retained edits", "Failed decryption replaced retained edits")
let normal = Note()
watcher.perform(normal)
expect(normal.content.string == "authenticated incoming content", "Valid encrypted reload stopped working")
var departingDelegate: Delegate? = Delegate()
weak var releasedDelegate = departingDelegate
let retainedWatcher = Watcher(delegate: departingDelegate!)
let pending = Note()
pending.changeTags = true
retainedWatcher.perform(pending)
departingDelegate = nil
expect(releasedDelegate == nil, "Queued watcher work retained its view controller")
// Production reloadNote queued tag updates while the owner was still present.
// Their callback manager remains alive after the view controller is released.
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
retainedWatcher.perform(Note())
print("PASS: production watcher shields, pending failed saves, late privacy/failure transitions, decryption failure, authenticated reload and owner teardown before queued UI work")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-watcher-privacy-") as temporary:
    work = Path(temporary)
    main = work / "main.swift"
    main.write_text(FIXTURE)
    binary = work / "test"
    subprocess.run(["swiftc", "-module-cache-path", str(work / "modules"), str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
