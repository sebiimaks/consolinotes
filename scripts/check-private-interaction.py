#!/usr/bin/env python3
"""Production idle/window/key lock triggers and text services, without hardware or app preferences."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'FSNotes/Helpers/PrivateInteraction.swift').read_text()
text_services = source[source.index('enum PrivateTextServices {'):source.index('enum PlaintextDisclosure {')]
coordinator = source[source.index('final class PrivacyLockCoordinator {'):]
fixture = r'''
import AppKit
import IOKit
import IOKit.usb
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
enum PrivacyPreferences {
    static var idleSeconds: TimeInterval = 300
    static var lockLastWindow = true
    static var lockKeyRemoval = false
}
enum PrivacyLog { static var events = [String](); static func record(_ event: StaticString) { events.append(event.description) } }
final class Note {
    var unlocked = false
    var hasPendingPlaintextCleanup = false
    func isUnlocked() -> Bool { unlocked }
}
final class Storage {
    static var instance: Storage?
    var noteList = [Note]()
}
enum AppDelegate {
    static var mainWindowController: NSWindowController?
    static var noteWindows = [NSWindowController]()
}
final class ViewController {
    static let instance = ViewController()
    static func shared() -> ViewController? { instance }
    var locks = 0
    var pendingPassword = false
    var callback: (() -> Void)?
    func lockAll(_ sender: Any) { locks += 1; pendingPassword = false; callback?() }
}
final class TestWindow: NSWindow {
    var shown = true
    override var isVisible: Bool { shown }
}
'''
checks = r'''
extension PrivacyLockCoordinator {
    func testTick() { checkIdle() }
    func testActivity() { recordActivity() }
    func testKeyRemoved() { keyRemoved() }
    func testKeyAvailable() { keyRemovalAvailable = true }
    func testMonitorFailure() { removalMonitorFailed() }
}
let application = NSApplication.shared
let text = NSTextView()
text.isAutomaticTextCompletionEnabled = true
if #available(macOS 14.0, *) { text.inlinePredictionType = .yes }
if #available(macOS 15.0, *) { text.writingToolsBehavior = .complete }
PrivateTextServices.apply(to: text)
expect(!text.isAutomaticTextCompletionEnabled, "Text completion remained enabled")
if #available(macOS 14.0, *) { expect(text.inlinePredictionType == .no, "Inline predictions remained enabled") }
if #available(macOS 15.0, *) { expect(text.writingToolsBehavior == .none, "Writing Tools remained enabled") }

var time: TimeInterval = 0
var warnings = 0
let coordinator = PrivacyLockCoordinator(now: { time }, monitorUnavailable: { warnings += 1 })
let view = ViewController.instance
coordinator.lock()
expect(view.locks == 0, "Lock created storage during startup")
let storage = Storage(); Storage.instance = storage
let note = Note(); storage.noteList = [note]
view.pendingPassword = true
coordinator.lock()
expect(view.locks == 1 && !view.pendingPassword, "Locked-only state skipped cancellation of a pending password")
note.unlocked = true
time = 299; coordinator.testTick()
expect(view.locks == 1, "Idle lock ran before timeout")
time = 300; coordinator.testTick()
expect(view.locks == 2, "Idle timeout did not lock")
time = 301; coordinator.testTick()
expect(view.locks == 2, "Idle lock repeated without a new timeout")
time = 590; coordinator.testActivity()
time = 889; coordinator.testTick()
expect(view.locks == 2, "Activity failed to reset idle timeout")
time = 890; coordinator.testTick()
expect(view.locks == 3, "New idle timeout did not lock")
PrivacyPreferences.idleSeconds = 0
time = 10_000; coordinator.testTick()
expect(view.locks == 3, "Disabled idle lock still ran")

let main = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
let other = TestWindow(contentRect: main.frame, styleMask: [], backing: .buffered, defer: true)
AppDelegate.mainWindowController = NSWindowController(window: main)
AppDelegate.noteWindows = [NSWindowController(window: other)]
coordinator.closing(main)
expect(view.locks == 3, "Closing one of two visible note windows locked")
other.shown = false
coordinator.closing(main)
expect(view.locks == 4, "Closing the last visible note window did not lock")
PrivacyPreferences.lockLastWindow = false
coordinator.closing(main)
expect(view.locks == 4, "Disabled last-window locking still ran")

expect(!coordinator.setKeyRemovalEnabled(true), "Unavailable monitor accepted enablement")
expect(!PrivacyPreferences.lockKeyRemoval && warnings == 1, "Unavailable monitor did not warn and disable")
coordinator.testKeyRemoved()
expect(view.locks == 4, "Unavailable monitor triggered a key lock")
coordinator.testKeyAvailable()
expect(coordinator.setKeyRemovalEnabled(true), "Working monitor refused enablement")
coordinator.testKeyRemoved()
expect(view.locks == 5, "Enabled key removal did not lock")
coordinator.setKeyRemovalEnabled(false)
coordinator.testKeyRemoved()
expect(view.locks == 5, "Disabled key removal locked")
coordinator.setKeyRemovalEnabled(true)
coordinator.testMonitorFailure()
expect(!coordinator.keyRemovalAvailable && !PrivacyPreferences.lockKeyRemoval && warnings == 2, "Monitor failure left protection falsely enabled")
coordinator.testMonitorFailure()
expect(warnings == 2, "Monitor failure repeatedly warned for an already disabled setting")

note.unlocked = false; note.hasPendingPlaintextCleanup = true
view.callback = { coordinator.lock() }
coordinator.lock()
expect(view.locks == 6, "Pending cleanup did not lock or reentrant lock was not guarded")
print("PASS: idle timeout/activity/off; last visible window/off; key removal/off/unavailable; pending cleanup and reentrancy")
print("PASS: production text policy disables completion, inline prediction and Writing Tools")
'''
with tempfile.TemporaryDirectory(prefix='consolinotes-private-interaction-') as temporary:
    work = Path(temporary)
    (work / 'main.swift').write_text(fixture + text_services + coordinator + checks)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'),
                    str(work / 'main.swift'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True, timeout=30)
settings = (ROOT / 'FSNotes/Preferences/PreferencesSecurityViewController.swift').read_text()
assert 'PrivacyLockCoordinator.shared.setKeyRemovalEnabled(key.state == .on)' in settings
assert 'NSControl.textDidBeginEditingNotification' in source
assert 'PrivateTextServices.apply(to: editor)' in (ROOT / 'FSNotes/EditorViewController.swift').read_text()
view_controller = (ROOT / 'FSNotes/ViewController.swift').read_text()
lock_all = view_controller[view_controller.index('@IBAction func lockAll('):view_controller.index('func controlTextDidEndEditing', view_controller.index('@IBAction func lockAll('))]
assert lock_all.index('Self.shieldForLock(notes: notes)') < lock_all.index('for note in notes')
editor = (ROOT / 'FSNotes/EditorViewController.swift').read_text()
shield = editor[editor.index('static func shieldForLock(notes:'):editor.index('public func lockUnlocked(', editor.index('static func shieldForLock(notes:'))]
assert shield.index('cancelPasswordRequests()') < shield.index('for note in notes')
assert 'PlaintextDisclosure.cancel()' in editor[editor.index('public static func cancelPasswordRequests()'):editor.index('public var alert:')]
print('PASS: settings checks availability; editors use private text policy; empty Lock All cancels pending passwords and disclosure')
