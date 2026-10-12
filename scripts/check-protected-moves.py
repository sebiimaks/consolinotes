#!/usr/bin/env python3
"""Exercise production protected-folder move ordering with isolated model doubles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / "FSNotes/ViewController.swift").read_text()

def extract(signature):
    start = text.index(signature)
    end = text.index("\n    }", start) + len("\n    }")
    return text[start:end]

source = r'''
import Foundation
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
final class Project: Equatable {
    let url: URL; var isEncrypted: Bool; var password: String?
    init(_ path: String, encrypted: Bool = false, unlocked: Bool = false) {
        url = URL(fileURLWithPath: path); isEncrypted = encrypted
        password = unlocked ? "test" : nil
    }
    func isLocked() -> Bool { isEncrypted && password == nil }
    static func == (lhs: Project, rhs: Project) -> Bool { lhs === rhs }
}
final class Note {
    var project: Project; var name = "fixture.md"
    var encrypted = false; var unlocked = false
    var failEncrypt = false; var failMove = false; var failLock = false
    var moved = false; var plaintextEnteredProtectedFolder = false
    var events = [String]()
    init(_ project: Project) { self.project = project }
    func isEncrypted() -> Bool { encrypted }
    func isUnlocked() -> Bool { unlocked }
    func encrypt(password: String) -> Bool {
        events.append("encrypt")
        if failEncrypt { return false }
        encrypted = true; unlocked = false; name = "fixture.etp"; return true
    }
    func unLock(password: String) -> Bool { events.append("unlock"); unlocked = true; return true }
    func lock() -> Bool {
        events.append("lock")
        if failLock { return false }
        unlocked = false; return true
    }
    func move(to: URL, project: Project) -> Bool {
        events.append("move")
        plaintextEnteredProtectedFolder = project.isEncrypted && !encrypted
        if failMove { return false }
        self.project = project; moved = true; return true
    }
    func moveImages(to: Project) {}
    func invalidateCache() {}
    func presentSaveFailure() { events.append("error") }
}
final class Sidebar {
    func reloadTags() {}
    func unlock(projects: [Project], password: String) { for project in projects { project.password = password } }
}
final class Table {
    var selectedRowIndexes = IndexSet()
    func removeRows(notes: [Note]) {}
    func countNotes() -> Int { 0 }
    func selectRow(_ row: Int) {}
}
struct Search { func isFit(note: Note) -> Bool { true } }
struct Storage { let searchQuery = Search() }
final class Editor { var cleared = false; func clear() { cleared = true } }
final class ViewController {
    let sidebarOutlineView = Sidebar(); let notesTableView = Table()
    let storage = Storage(); let editor = Editor()
    var failures = 0
    func showProtectionFailure(_ value: String) { failures += 1 }
    func reloadAllOpenedWindows(note: Note) { note.events.append("refresh") }
    func getMasterPassword(completion: @escaping (String) -> ()) {
        completion("test")
    }
''' + extract("    public func moveReq(notes:") + "\n" + extract("    private func move(notes:") + r'''
}
let source = Project("/synthetic/source")
let destination = Project("/synthetic/private", encrypted: true, unlocked: true)
let controller = ViewController()
let note = Note(source)
var completed: Bool?
controller.moveReq(notes: [note], project: destination) { completed = $0 }
expect(completed == true && note.project === destination && note.encrypted, "protected move must succeed with ciphertext")
expect(!note.plaintextEnteredProtectedFolder, "protected folder must not receive plaintext even briefly")
expect(note.events.first == "encrypt" && note.events.firstIndex(of: "refresh")! < note.events.firstIndex(of: "move")!, "conversion must precede move and clear open plaintext editors")

let failedConversion = Note(source); failedConversion.failEncrypt = true
completed = nil
controller.moveReq(notes: [failedConversion], project: destination) { completed = $0 }
expect(completed == false && !failedConversion.moved && failedConversion.project === source, "failed conversion must preserve source and report failure")

let failedMove = Note(source); failedMove.failMove = true
let failedController = ViewController(); completed = nil
failedController.moveReq(notes: [failedMove], project: destination) { completed = $0 }
expect(completed == false && failedMove.project === source && failedMove.encrypted && !failedMove.unlocked, "failed move must retain encrypted source")
expect(failedMove.events.contains("refresh"), "failed move must not leave original plaintext displayed")
expect(!failedController.editor.cleared, "failed move must not clear the active working editor")

let failedLock = Note(source); failedLock.encrypted = true; failedLock.unlocked = true; failedLock.failLock = true
let ordinary = Project("/synthetic/ordinary")
let lockController = ViewController(); completed = nil
lockController.moveReq(notes: [failedLock], project: ordinary) { completed = $0 }
expect(completed == false && !failedLock.moved && failedLock.unlocked, "failed lock must block the move and keep working state")
expect(!lockController.editor.cleared, "failed lock must keep the working editor")

let alreadyEncrypted = Note(source); alreadyEncrypted.encrypted = true
completed = nil
controller.moveReq(notes: [alreadyEncrypted], project: destination) { completed = $0 }
expect(completed == false && !alreadyEncrypted.moved, "incompatible already-encrypted move must explicitly fail")
print("Verified protected moves: encryption before move, source preservation on failure, failed-lock handling, completion status and editor refresh.")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-protected-move-check-") as temp:
    work = Path(temp)
    main = work / "main.swift"
    main.write_text(source)
    subprocess.run(["xcrun", "swift", "-module-cache-path", str(work / "module-cache"), str(main)], check=True)
