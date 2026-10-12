#!/usr/bin/env python3
"""Exercise manual password routing, lock cancellation and encryption notice suppression."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]

editor = (ROOT / "FSNotes/EditorViewController.swift").read_text()
methods = "\n".join(method(editor, signature) for signature in [
    "    public static func cancelPasswordRequests(", "    public func getMasterPassword(",
])
fixture = r'''
import Foundation
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
enum Response { case alertFirstButtonReturn, alertSecondButtonReturn, alertThirdButtonReturn, cancel }
final class Button {
    enum State { case on, off }
    var state: State = .off
    var title = ""
}
final class NSAlert {
    enum Style { case informational, warning }
    static var choices = [(Response, Bool)]()
    static var shown = [String]()
    var alertStyle: Style = .informational
    var messageText = ""
    var informativeText = ""
    var showsSuppressionButton = false
    var suppressionButton: Button? = Button()
    func addButton(withTitle title: String) {}
    func runModal() -> Response {
        Self.shown.append(messageText)
        expect(!Self.choices.isEmpty, "Unexpected dialog: " + messageText)
        let choice = Self.choices.removeFirst()
        suppressionButton?.state = choice.1 ? .on : .off
        if showsSuppressionButton { expect(suppressionButton?.title == "Do not ask again.", "Wrong checkbox title") }
        return choice.0
    }
}
final class FIDO2PasswordProvider {
 static let shared = FIDO2PasswordProvider()
 var enrolled = false
 func load() throws -> Bool? { enrolled ? true : nil }
 func cancel() {}
}
enum FIDO2UnlockUI {
 static var callback: ((String) -> Void)?
 static func cancelPendingRequests() {}
 static func unlock(from: EditorViewController, completion: @escaping (String) -> Void, manualFallback: (() -> Void)? = nil) { callback = completion }
}
enum EncryptedNoteRecoveryController { static func cancel() {} }
enum PlaintextDisclosure { static func cancel() {} }
enum PrivateNoteArchive { static func cancelOperations() {} }
enum UserDefaultsManagement { static var suppressNewEncryptionFormatNotice = false }
final class EditorViewController {
    private static var passwordRequestGeneration: UInt64 = 0
    private static let passwordControllers = NSHashTable<EditorViewController>.weakObjects()
    func teardownPasswordPrompt() { pending = nil }
    func runPasswordNotice(_ alert: NSAlert) -> Response { alert.runModal() }
    var pending: ((String) -> Void)?
    var validation = false
    func masterPasswordPrompt(validation: Bool, reason: String? = nil, completion: @escaping (String) -> Void) {
        self.validation = validation; pending = completion
    }
''' + methods + r'''
}
let editor = EditorViewController()
var received: String?
editor.getMasterPassword { received = $0 }
editor.pending?("manual")
expect(received == "manual" && !editor.validation, "Manual unlock failed")
received = nil
editor.getMasterPassword { received = $0 }
let cancelledCallback = editor.pending
EditorViewController.cancelPasswordRequests()
cancelledCallback?("late")
expect(received == nil, "Late manual prompt reversed lock")
editor.pending = nil
NSAlert.choices = [(.cancel, true)]
editor.getMasterPassword(forEncrypt: true) { received = $0 }
expect(editor.pending == nil && !UserDefaultsManagement.suppressNewEncryptionFormatNotice, "Cancel persisted suppression")
NSAlert.choices = [(.alertFirstButtonReturn, true)]
editor.getMasterPassword(forEncrypt: true) { received = $0 }
expect(editor.validation && UserDefaultsManagement.suppressNewEncryptionFormatNotice, "Encrypt did not persist suppression")
let count = NSAlert.shown.count
editor.getMasterPassword(forEncrypt: true) { received = $0 }
expect(NSAlert.shown.count == count, "Suppression ignored")
received = nil
FIDO2PasswordProvider.shared.enrolled = true
NSAlert.choices = [(.alertFirstButtonReturn, false)]
editor.getMasterPassword(allowHardware: true) { received = $0 }
expect(received == nil && FIDO2UnlockUI.callback != nil, "Hardware route bypassed")
EditorViewController.cancelPasswordRequests()
FIDO2UnlockUI.callback?("late hardware password")
expect(received == nil, "Late hardware result reversed lock")
FIDO2UnlockUI.callback = nil
editor.getMasterPassword(forEncrypt: true, allowHardware: true) { received = $0 }
expect(FIDO2UnlockUI.callback == nil && editor.validation, "Hardware supplied password for new encryption")
editor.getMasterPassword { received = $0 }
expect(FIDO2UnlockUI.callback == nil, "Default folder flow accessed hardware")
NSAlert.choices = [(.cancel, false)]
editor.pending = nil
editor.getMasterPassword(allowHardware: true) { received = $0 }
expect(editor.pending == nil && FIDO2UnlockUI.callback == nil, "Cancel fell back")
print("PASS: explicit hardware routing, no hardware encryption, manual unlock, cancellation on lock, encryption notice opt-out")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-password-routing-") as directory:
    directory = Path(directory)
    source = directory / "main.swift"
    source.write_text(fixture)
    binary = directory / "routing-tests"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(directory / "modules"), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
