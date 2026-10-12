#!/usr/bin/env python3
"""Exercise the production AppKit password lifecycle with synthetic windows/secrets.

Extracts the actual prompt methods so no real app, notes, preferences or hardware
are touched. Checks every exit and delayed callbacks, not a mirror implementation.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'FSNotes/EditorViewController.swift').read_text()
methods = source[source.index('    public func getMasterPassword('):source.index('    func dismissSensitiveDialog()')]
cancel = source[source.index('    public static func cancelPasswordRequests()'):source.index('    public var alert:')]
fixture = r'''
import Cocoa
class FIDO2PasswordProvider {
    static let shared = FIDO2PasswordProvider()
    func load() throws -> Bool? { nil }
}
enum FIDO2UnlockUI {
    static var cancellations = 0
    static func cancelPendingRequests() { cancellations += 1 }
    static func unlock(from: NSViewController, completion: @escaping (String) -> Void, manualFallback: @escaping () -> Void) {}
}
enum PrivateNoteArchive { static func cancelOperations() {} }
enum EncryptedNoteRecoveryController { static func cancel() {} }
enum PlaintextDisclosure { static func cancel() {} }
enum UserDefaultsManagement { static var suppressNewEncryptionFormatNotice = true }
class EditorViewController: NSViewController {
    private static var passwordRequestGeneration: UInt64 = 0
    private static let passwordControllers = NSHashTable<EditorViewController>.weakObjects()
    private var passwordAlert: NSAlert?
    private var passwordWindowObserver: NSObjectProtocol?
    var alert: NSAlert?
    var encPassword: NSSecureTextField?
    var encVerifyPassword: NSSecureTextField?
    var encCompletionHandler: ((String) -> Void)?
__CANCEL__
__METHODS__
}
class NoteViewController: EditorViewController {}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1)
}
func expect(_ result: Bool, _ text: String) { if !result { fail(text) } }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let vc = EditorViewController()
vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
let window = NSWindow(contentRect: vc.view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentViewController = vc
window.makeKeyAndOrderFront(nil)
let scenario = CommandLine.arguments[1]
var calls = 0
var passwordRef: NSSecureTextField?
var verifyRef: NSSecureTextField?
var savedCallback: ((String) -> Void)?
var step = 0
let began = Date()
func cleared() -> Bool {
    vc.encPassword == nil && vc.encVerifyPassword == nil && vc.encCompletionHandler == nil && vc.alert == nil
}
let timer = Timer(timeInterval: 0.025, repeats: true) { _ in
    if Date().timeIntervalSince(began) > 8 { fail("Timeout: " + scenario) }
    if step == 0, let field = vc.encPassword, let alert = vc.alert {
        passwordRef = field; verifyRef = vc.encVerifyPassword; savedCallback = vc.encCompletionHandler
        field.stringValue = "synthetic-note-password"
        vc.encVerifyPassword?.stringValue = "synthetic-note-password"
        step = 1
        switch scenario {
        case "manual-success", "validation-success": vc.onOkClick(nil)
        case "cancel": alert.buttons[1].performClick(nil)
        case "window-close": window.close()
        case "lock":
            EditorViewController.cancelPasswordRequests()
            savedCallback?("late-result-must-not-unlock")
        case "mismatch":
            vc.encVerifyPassword?.stringValue = "wrong-repeat"
            vc.onOkClick(nil)
            expect(calls == 0 && vc.encPassword != nil, "Mismatch accepted or prompt destroyed")
            expect(vc.encVerifyPassword?.stringValue == "", "Mismatch retained repeated secret")
            alert.buttons[1].performClick(nil)
        case "empty":
            field.stringValue = ""; vc.onOkClick(nil)
            expect(calls == 0 && vc.encPassword != nil, "Empty password accepted")
            alert.buttons[1].performClick(nil)
        default: fail("Unknown scenario")
        }
    }
    if step == 1 && cleared() && window.attachedSheet == nil {
        expect(passwordRef?.stringValue ?? "" == "", "Password field retained secret")
        expect(verifyRef?.stringValue ?? "" == "", "Repeat field retained secret")
        expect(calls == (scenario.hasSuffix("success") ? 1 : 0), "Unexpected callback count")
        print("PASS: password lifecycle " + scenario)
        window.orderOut(nil); exit(0)
    }
    if scenario == "queued-cancel", Date().timeIntervalSince(began) > 0.4 {
        expect(cleared() && window.attachedSheet == nil && calls == 0, "Queued cancelled prompt appeared")
        print("PASS: password lifecycle queued-cancel"); window.orderOut(nil); exit(0)
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.add(timer, forMode: .modalPanel)
DispatchQueue.main.async {
    let validation = scenario == "validation-success" || scenario == "mismatch"
    vc.getMasterPassword(forEncrypt: validation) { value in
        expect(cleared(), "Callback ran before prompt teardown")
        expect(value == "synthetic-note-password", "Wrong returned password")
        calls += 1
    }
    if scenario == "queued-cancel" { EditorViewController.cancelPasswordRequests() }
}
app.run()
'''.replace('__CANCEL__', cancel).replace('__METHODS__', methods)

with tempfile.TemporaryDirectory(prefix='consolinotes-password-lifecycle-') as temporary:
    work = Path(temporary)
    (work / 'main.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'),
                    str(work / 'main.swift'), '-o', str(work / 'test')], check=True)
    for scenario in ['manual-success', 'validation-success', 'cancel', 'window-close', 'lock', 'queued-cancel', 'mismatch', 'empty']:
        subprocess.run([str(work / 'test'), scenario], check=True, timeout=15)
