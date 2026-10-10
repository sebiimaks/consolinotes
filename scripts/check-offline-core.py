#!/usr/bin/env python3
"""Exercise production URL routes and quit policy with in-memory stubs.

No app launches, user preferences, Keychain access, or real note files. The
optional --app check reads a built app's signed entitlements and metadata.
"""
from pathlib import Path
import argparse
import json
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


def check_entitlements(data):
    assert data.get("com.apple.security.app-sandbox") is True, "Sandbox must remain enabled"
    assert data.get("com.apple.security.smartcard") is True, "PIV inventory requires scoped smart-card access"
    for key in ["com.apple.security.network.client", "com.apple.security.network.server",
                "com.apple.security.get-task-allow", "get-task-allow"]:
        assert not data.get(key), f"Unexpected entitlement: {key}"


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path)
args = parser.parse_args()
check_entitlements(plistlib.loads((ROOT / "FSNotes/FSNotes.entitlements").read_bytes()))
info = plistlib.loads((ROOT / "FSNotes/Info.plist").read_bytes())
assert not info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads"), "ATS must not allow arbitrary loads"
assert not info.get("NSUserActivityTypes"), "Handoff must not remain registered"
pins = json.loads((ROOT / "FSNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
identities = {pin["identity"] for pin in pins["pins"]}
assert not identities.intersection({"shout", "bluesocket", "swift-git", "swift-system", "swift-cgit2", "libssh2prebuild"}), "Unused transport packages returned"
project = plistlib.loads(subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(ROOT / "FSNotes.xcodeproj/project.pbxproj")]))
objects = project["objects"]
for target in [x for x in objects.values() if x.get("isa") == "PBXNativeTarget"]:
    for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
        config = objects[config_id]
        if config["name"] == "Release":
            build = config["buildSettings"]
            assert build.get("ENABLE_HARDENED_RUNTIME") == "YES"
            assert build.get("CODE_SIGN_INJECT_BASE_ENTITLEMENTS") == "NO"
            assert build.get("ENABLE_TESTABILITY") == "NO"
for root in [ROOT / "FSNotes", ROOT / "FSNotesCore"]:
    for path in root.rglob("*.swift"):
        source = path.read_text()
        for forbidden in [r"import\s+Shout", r"git_remote_", r"git_clone\(", r"\bURLSession\s*[.(]", r"\bNSURLConnection\s*[.(]"]:
            assert re.search(forbidden, source) is None, f"Unexpected transport API {forbidden}: {path.relative_to(ROOT)}"

routes = (ROOT / "FSNotes/AppDelegate+URLRoutes.swift").read_text()
assert "RouteFSNotesNew" not in routes, "Deep links must not create notes"
methods = "\n".join(method(routes, signature) for signature in [
    "    enum HandledSchemes:", "    enum FSNotesRoutes:", "    enum NvALTRoutes:",
    "    func application(_ application:", "    func FSNotesRouter(",
    "    func RouteFSNotesOpen(", "    func RouteFSNotesFind(",
    "    public func search(url:", "    func NvALTRouter(",
    "    func RouteNvAltFind(", "    func RouteNvAltBlank(",
])
quit_policy = method((ROOT / "FSNotes/AppDelegate.swift").read_text(), "    func applicationShouldTerminate(")
string_helper = method((ROOT / "FSNotesCore/Extensions/String+.swift").read_text(), "    func escapePlus()")
url_helper = method((ROOT / "FSNotesCore/Extensions/URL+.swift").read_text(), "    subscript(queryParam:")
source = r'''
import Foundation
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
final class NSApplication {
    enum TerminateReply { case terminateNow, terminateCancel }
    var mainWindow: Window? = Window()
}
let NSApp = NSApplication()
final class Window { func makeFirstResponder(_ responder: Any) {} }
final class Search { let window: Window? = Window() }
final class Project {
    let isEncrypted: Bool
    var password: String? = "fixture-password"
    init(encrypted: Bool = true) { isEncrypted = encrypted }
}
final class Note {
    let title: String; let project: Project
    var content = NSMutableAttributedString(string: "original fixture")
    var unlocked = false; var encrypted = true
    var hasPendingPlaintextCleanup = false
    var lastWriteError: String?; var lockSucceeds = true; var saveSucceeds = true
    var saveCalls = 0; var lockCalls = 0; var appendCalls = 0
    init(_ title: String, project: Project = Project()) { self.title = title; self.project = project }
    func isUnlocked() -> Bool { unlocked }
    func isEncryptedAndLocked() -> Bool { encrypted && !unlocked }
    func lock() -> Bool {
        lockCalls += 1
        if lockSucceeds { unlocked = false; hasPendingPlaintextCleanup = false }
        return lockSucceeds
    }
    func save() -> Bool { saveCalls += 1; return saveSucceeds }
    func append(string: NSAttributedString) { appendCalls += 1; content.append(string) }
    func setSelectedRange(range: NSRange) {}
}
final class Storage {
    static var instance: Storage? = Storage()
    static func shared() -> Storage { instance! }
    var noteList = [Note]()
    func getBy(titleOrName: String) -> Note? { noteList.first { $0.title == titleOrName } }
    func getProjects() -> [Project] { noteList.map { $0.project } }
    func getNotesBy(project: Project) -> [Note] { noteList.filter { $0.project === project } }
}
final class Sidebar {
    var tag: String?; var tagReloads = 0; var dataReloads = 0
    func select(tag: String) { self.tag = tag }
    func reloadTags() { tagReloads += 1 }
    func reloadData() { dataReloads += 1 }
}
final class Table {
    var selected: Note?; var refreshed = [String]()
    func selectRowAndSidebarItem(note: Note) { selected = note }
    func saveNavigationHistory(note: Note) {}
    func reloadRow(note: Note) { refreshed.append(note.title) }
}
final class ViewController {
    static var instance: ViewController? = ViewController()
    static func shared() -> ViewController? { instance }
    let sidebarOutlineView = Sidebar(); let notesTableView = Table()
    let editor = NSObject(); let search = Search()
    var refreshed = [String]()
    func cleanSearchAndEditArea(shouldBecomeFirstResponder: Bool, completion: () -> Void) { completion() }
    func reloadAllOpenedWindows(note: Note) { refreshed.append(note.title) }
}
final class AppDelegate {
    var urls = [URL](); var url: URL?
    var queries = [String](); var imported = [URL](); var failures = 0
    func importNotes(urls: [URL]) { imported += urls }
    func search(query: String) { queries.append(query) }
    func showTerminationSaveFailure() { failures += 1 }
''' + methods + "\n" + quit_policy + r'''
}
enum EditorViewController {
    static var cancellations = 0
    static func cancelPasswordRequests() { cancellations += 1 }
}
extension String {
''' + string_helper + r'''
}
extension URL {
''' + url_helper + r'''
}
let delegate = AppDelegate()
let existing = Note("Existing Note")
Storage.shared().noteList = [existing]
let vc = ViewController.shared()!
for scheme in ["consolinotes", "fsnotes"] {
    delegate.application(NSApp, open: [URL(string: "\(scheme)://open/?title=Existing+Note&txt=malicious+append")!])
    expect(vc.notesTableView.selected === existing, "existing note link must still navigate")
    expect(existing.content.string == "original fixture" && existing.appendCalls == 0 && existing.saveCalls == 0, "deep links must not append or save")
    delegate.application(NSApp, open: [URL(string: "\(scheme)://open/?title=Missing+Note&txt=malicious+create")!])
    expect(Storage.shared().noteList.count == 1 && delegate.queries.last == "Missing Note", "unknown note must search without creating")
    delegate.application(NSApp, open: [URL(string: "\(scheme)://open/?tag=Private+Tag&txt=ignored")!])
    expect(vc.sidebarOutlineView.tag == "Private Tag", "tag navigation must work")
    vc.notesTableView.selected = nil
    delegate.application(NSApp, open: [URL(string: "\(scheme)://find?id=Existing%20Note")!])
    expect(vc.notesTableView.selected === existing, "find-by-id must navigate")
    let before = delegate.queries.count
    delegate.application(NSApp, open: [URL(string: "\(scheme)://new/?title=Forbidden&txt=ignored")!])
    expect(delegate.queries.count == before && Storage.shared().noteList.count == 1, "retired creation route must do nothing")
}
for url in ["nv://find/legacy%20query", "nvalt://legacy%20query"] {
    delegate.application(NSApp, open: [URL(string: url)!])
    expect(delegate.queries.last == "legacy query", "legacy search must remain read-only")
}
let queryCount = delegate.queries.count
delegate.application(NSApp, open: [URL(string: "https://open/?title=Forbidden&txt=ignored")!])
expect(delegate.queries.count == queryCount, "unhandled scheme must do nothing")
ViewController.instance = nil
let pending = URL(string: "consolinotes://find/pending")!
delegate.application(NSApp, open: [pending])
expect(delegate.url == pending, "search before launch must defer")
ViewController.instance = vc

// A failed password attempt on an already locked note is not an unsaved edit.
existing.lastWriteError = "wrong password fixture"
existing.saveSucceeds = false
expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "locked wrong-password note must not block quit")
expect(existing.saveCalls == 0 && existing.lockCalls == 0, "locked note must not be rewritten at quit")
expect(existing.project.password == nil, "fully locked project must clear cached password")

let good = Note("locked-first")
good.unlocked = true
let failed = Note("failed-second")
failed.unlocked = true; failed.lockSucceeds = false
Storage.shared().noteList = [good, failed]
expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "failed encrypted write must cancel quit")
expect(!good.unlocked && failed.unlocked && failed.project.password != nil, "failure must preserve recoverable note and password")
expect(vc.refreshed.contains(good.title) && vc.notesTableView.refreshed.contains(good.title), "a cancelled quit must clear windows for notes already locked")
expect(!vc.refreshed.contains(failed.title), "failed note must stay visible")
expect(good.project.password == nil && delegate.failures == 1, "finished projects must clear secrets and failure must be reported")
expect(vc.sidebarOutlineView.tagReloads >= 2 && vc.sidebarOutlineView.dataReloads >= 2, "sidebar must refresh even on cancellation")
failed.lockSucceeds = true
expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "successful retry must permit quit")

let cleanup = Note("cleanup-only")
cleanup.hasPendingPlaintextCleanup = true; cleanup.lockSucceeds = false
Storage.shared().noteList = [cleanup]
expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "locked cleanup-only notes must block quit until cleanup completes")
expect(cleanup.lockCalls == 1 && cleanup.saveCalls == 0, "quit must retry cleanup through lock without a normal save")
cleanup.lockSucceeds = true
expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow && !cleanup.hasPendingPlaintextCleanup, "successful cleanup retry must permit quit")

let plain = Note("plain")
plain.encrypted = false; plain.lastWriteError = "write failed"; plain.saveSucceeds = false
Storage.shared().noteList = [plain]
expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "failed plain write retry must cancel quit")
plain.saveSucceeds = true
expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "successful plain retry must permit quit")
Storage.instance = nil
expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "quit before storage initialization must work")
print("Verified read-only deep links and safe quit/retry/window refresh with synthetic notes.")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-offline-check-") as temp:
    work = Path(temp)
    main = work / "main.swift"
    main.write_text(source)
    subprocess.run(["xcrun", "swift", "-module-cache-path", str(work / "module-cache"), str(main)], check=True)

if args.app:
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(args.app)], capture_output=True, check=True)
    check_entitlements(plistlib.loads(result.stdout))
    details = subprocess.run(["codesign", "-d", "--verbose=4", str(args.app)], capture_output=True, text=True, check=True)
    assert re.search(r"flags=0x[0-9a-fA-F]+\([^)]*\bruntime\b", details.stderr), "Release app must use hardened runtime"
    built_info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    assert not built_info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads")
    assert not built_info.get("NSUserActivityTypes")
    print("Verified app signature, sandbox, no network/debug entitlements, hardened runtime, and metadata.")
print("Verified offline source, dependency and Release build configuration.")
