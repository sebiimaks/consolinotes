#!/usr/bin/env python3
"""Run production lock orchestration and editor shielding in synthetic AppKit windows.

The storage double injects successful writes and disk-full failures, asserting
that *all* editors are blank before the first write. Storage's own regression
suite checks the real encrypted save and authenticated recovery methods.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
def method(path, name):
    text = (ROOT / path).read_text()
    start = text.index(name)
    brace = text.index('{', start)
    level = 1
    end = brace + 1
    while level:
        if text[end] == '{': level += 1
        elif text[end] == '}': level -= 1
        end += 1
    return text[start:end]

fixture = r'''
import Cocoa
func expect(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
enum SensitiveClipboard { static var cleared = false; static func clearOwned() { cleared = true } }
enum LocalFindState { static var query = "synthetic-find" }
enum UserDefaultsManagement { static var recentSearches: [String]? = ["synthetic-search"] }
enum MPreviewView { static var cleared = false; static func purgeSensitivePreviews() { cleared = true } }
final class Note: NSObject {
    var isPrivacyShielded = false
    var unlocked = true
    var hasPendingPlaintextCleanup = false
    let fail: Bool
    var content = "retained synthetic edits"
    var password: String? = "retained-note-password"
    var lastWriteError: String?
    var lockCalls = 0
    init(fail: Bool) { self.fail = fail }
    func isUnlocked() -> Bool { unlocked }
    func isEncryptedAndLocked() -> Bool { isPrivacyShielded || !unlocked }
    func unLock(password: String) -> Bool { unlocked = true; isPrivacyShielded = false; return true }
    func scanContentTags() -> ([String], [String]) { (["private-tag"], []) }
    func save() -> Bool { !fail }
    func lock() -> Bool {
        lockCalls += 1
        expect(AppDelegate.editors.filter { $0.note != nil }.allSatisfy { $0.string.isEmpty && !$0.isEditable }, "A write began before all windows were hidden")
        expect(AppDelegate.editors.filter { $0.note != nil }.allSatisfy { $0.markdownView == nil }, "A preview survived lock request")
        expect(SensitiveClipboard.cleared && MPreviewView.cleared, "Sensitive caches survived lock request")
        if fail { return false }
        unlocked = false; isPrivacyShielded = false; content = ""; return true
    }
}
final class Project {
    var isEncrypted = true
    var password: String? = "folder-password"
    let storage: Storage
    var notes: [Note]
    init(storage: Storage, notes: [Note]) { self.storage = storage; self.notes = notes }
    func isLocked() -> Bool { isEncrypted && password == nil }
__PROJECTLOCK__
}
final class Storage {
    static var instance: Storage?
    var noteList: [Note] = []
    var projects: [Project] = []
    func getProjects() -> [Project] { projects }
    func getNotesBy(project: Project) -> [Note] { project.notes }
}
final class Search { var cleared = false; func clearPrivateState() { cleared = true } }
final class Table: NSView { func reloadRow(note: Note) {}; func enableLockedProject() {} }
final class Sidebar {
    var tags = [String]()
    func addTags(_ values: [String]) { tags.append(contentsOf: values) }
    func reloadTags() { tags.removeAll() }
    func reloadData() {}
    func getSelectedProject() -> Project? { nil }
}
final class Finder { var cleared = false; func close(clear: Bool) { cleared = clear } }
class EditorViewController: NSViewController {
    static var cancellations = 0
    var vcNonSelectedLabel: NSTextField? = NSTextField(labelWithString: "visible")
    var previewResizeTimer = Timer()
    var alert: NSAlert?
    static func cancelPasswordRequests() { cancellations += 1 }
    func cancelTextSearch() {}
__DISMISS__
    func updateTitle(note: Note) {}
    func updateVimChrome() {}
    func getMasterPassword(allowHardware: Bool, completion: (String) -> Void) { completion("retained-note-password") }
    func reloadAllOpenedWindows(note: Note) {
        for editor in AppDelegate.editors where editor.note === note { editor.lockEncryptedView() }
    }
__SHIELD__
__UNLOCK__
}
class Editor: NSTextView {
    weak var editorViewController: EditorViewController?
    var note: Note?
    var markdownView: NSView?
    var privateFinder: Finder? = Finder()
    func clearPrivateFind() { privateFinder?.close(clear: true) }
__BLANK__
}
class ViewController: EditorViewController {
    static var instance: ViewController?
    static func shared() -> ViewController? { instance }
    let storage = Storage()
    let search = Search()
    let notesTableView = Table()
    var sidebarOutlineView: Sidebar! = Sidebar()
    let editor = Editor()
    var failures = [String]()
    func updateCounters(note: Note?) {}
    func showProtectionFailure(_ message: String) { failures.append(message) }
__LOCKALL__
}
enum AppDelegate {
    static var editors = [Editor]()
    static func getEditTextViews() -> [Editor] { editors }
}
class TerminationDelegate {
    var failures = 0
    func showTerminationSaveFailure() { failures += 1 }
__TERMINATE__
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let main = ViewController()
ViewController.instance = main
let detached = EditorViewController()
let a = Note(fail: false), b = Note(fail: true)
main.storage.noteList = [a, b]
Storage.instance = main.storage
let folder = Project(storage: main.storage, notes: [a, b])
main.storage.projects = [folder]
let editors = [main.editor, Editor(), Editor(), Editor()]
let controllers: [EditorViewController] = [main, detached, EditorViewController(), EditorViewController()]
var windows = [NSWindow]()
for (index, editor) in editors.enumerated() {
    let vc = controllers[index]
    vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let window = NSWindow(contentRect: vc.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = vc
    vc.view.addSubview(editor)
    editor.editorViewController = vc
    editor.note = index == 0 ? a : (index == 3 ? nil : b)
    editor.string = index == 3 ? "plain note" : "sensitive visible text"
    editor.isEditable = true
    editor.markdownView = NSView()
    vc.view.addSubview(editor.markdownView!)
    window.orderFront(nil)
    windows.append(window)
}
main.view.addSubview(main.notesTableView)
AppDelegate.editors = editors
let attachmentDialog = NSAlert()
attachmentDialog.messageText = "private attachment title"
let attachmentField = NSTextField(string: "retained attachment label")
attachmentDialog.accessoryView = attachmentField
attachmentDialog.addButton(withTitle: "Save")
main.alert = attachmentDialog
attachmentDialog.beginSheetModal(for: windows[0])
main.lockAll(main)
expect(attachmentField.stringValue.isEmpty && main.alert == nil, "Lock retained attachment dialog fields")
expect(!attachmentDialog.window.isVisible && windows[0].attachedSheet == nil, "Lock left attachment dialog visible")
expect(a.lockCalls == 1 && b.lockCalls == 1, "Lock did not visit each note exactly once")
expect(!a.unlocked && a.content.isEmpty, "Successful lock did not finish")
expect(b.unlocked && b.isPrivacyShielded && b.content == "retained synthetic edits", "Failed lock lost recoverable edits or exposed them")
expect(main.failures.count == 1, "Failure was not surfaced")
expect(editors.allSatisfy { $0.privateFinder?.cleared == true }, "Find interfaces retained text")
expect(main.search.cleared && LocalFindState.query.isEmpty && UserDefaultsManagement.recentSearches == nil, "Lock retained search state")
expect(controllers.prefix(3).allSatisfy { $0.vcNonSelectedLabel?.isHidden == false }, "Locked state missing in a window")
expect(EditorViewController.cancellations == 1, "Pending prompts not cancelled")
expect(folder.isLocked(), "Failed Lock All retained folder authorization")
expect(b.password == "retained-note-password", "Failed Lock All destroyed the note recovery secret")
folder.password = "folder-password"
_ = folder.lock()
expect(folder.isLocked() && b.isPrivacyShielded && b.password == "retained-note-password", "Failed folder lock retained authorization or lost recovery state")

// Run the actual deferred post-unlock callbacks only after a new lock request.
main.unLock(notes: [b])
main.lockAll(main)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
expect(main.sidebarOutlineView.tags.isEmpty, "A queued unlock restored private tags after locking")

// The first failing note aborts quit. Every protected folder still loses its
// authorization, including folders whose notes have not been visited yet.
let c = Note(fail: false)
let laterFolder = Project(storage: main.storage, notes: [c])
folder.password = "folder-password"
main.storage.projects = [folder, laterFolder]
main.storage.noteList = [b, c]
let termination = TerminationDelegate()
expect(termination.applicationShouldTerminate(app) == .terminateCancel, "Failed save did not cancel quit")
expect(termination.failures == 1, "Cancelled quit did not report the save failure")
expect(folder.isLocked() && laterFolder.isLocked(), "Cancelled quit retained a folder password")
expect(b.isPrivacyShielded && b.password == "retained-note-password" && b.content == "retained synthetic edits", "Cancelled quit lost retained edits or their recovery secret")
print("PASS: all windows shield before writes; disk-full edits retained; previews, find and clipboard cleared")
print("PASS: failed folder/Lock All/quit clear folder authorization; queued unlock cannot restore private tags")
windows.forEach { $0.orderOut(nil) }
'''
fixture = fixture.replace('__DISMISS__', method('FSNotes/EditorViewController.swift', '    func dismissSensitiveDialog()'))
fixture = fixture.replace('__SHIELD__', method('FSNotes/EditorViewController.swift', '    static func shieldForLock('))
fixture = fixture.replace('__LOCKALL__', method('FSNotes/ViewController.swift', '    @IBAction func lockAll('))
fixture = fixture.replace('__BLANK__', method('FSNotes/View/EditTextView.swift', '    public func lockEncryptedView('))
fixture = fixture.replace('__PROJECTLOCK__', method('FSNotesCore/Business/Project.swift', '    public func lock()'))
fixture = fixture.replace('__UNLOCK__', method('FSNotes/EditorViewController.swift', '    public func unLock(notes:'))
fixture = fixture.replace('__TERMINATE__', method('FSNotes/AppDelegate.swift', '    func applicationShouldTerminate('))
with tempfile.TemporaryDirectory(prefix='consolinotes-lock-privacy-') as temporary:
    work = Path(temporary)
    (work / 'main.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'), str(work / 'main.swift'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True, timeout=15)
