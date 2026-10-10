#!/usr/bin/env python3
"""Exercise production password routing with synthetic UI, token and Keychain sources."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]

editor = (ROOT / "FSNotes/EditorViewController.swift").read_text()
defaults = (ROOT / "FSNotesCore/UserDefaultsManagement.swift").read_text()
methods = "\n".join(method(editor, signature) for signature in [
    "    public static func cancelPasswordRequests(",
    "    public func getMasterPassword(", "    private func choosePasswordSource(",
    "    private func getYubiKeyPassword(", "    private func offerPasswordFallback(",
    "    private func getSavedOrManualPassword(",
])
fixture = r'''
import Foundation
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
enum FixtureError: Error { case cancelled, unavailable }
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
final class DispatchQueue {
    enum QoS { case userInitiated }
    static let main = DispatchQueue()
    static func global(qos: QoS) -> DispatchQueue {
        let queue = DispatchQueue(); queue.background = true; return queue
    }
    static var holdBackground = false
    static var pending = [() -> Void]()
    private var background = false
    func async(execute: @escaping () -> Void) {
        if background && Self.holdBackground { Self.pending.append(execute) }
        else { execute() }
    }
}
final class PIVPasswordProvider {
    struct Enrollment { let displayName: String }
    static let shared = PIVPasswordProvider()
    var saved: Enrollment?
    var readFails = false
    var error: FixtureError?
    var calls = 0
    func cancelPendingOperations() {}
    func enrollment() throws -> Enrollment? {
        if readFails { throw FixtureError.unavailable }
        return saved
    }
    func unlock() throws -> String {
        calls += 1
        if let error = error { throw error }
        return "token password"
    }
    static func isCancellation(_ error: Error) -> Bool { (error as? FixtureError) == .cancelled }
}
struct KeychainPasswordItem { enum KeychainError: Error { case noPassword } }
enum KeychainConfiguration {
    static var calls = 0
    static var error: FixtureError?
    static func readMasterPassword() throws -> String {
        calls += 1
        if let error = error { throw error }
        return "keychain password"
    }
    static func isAuthenticationCancelled(_ error: Error) -> Bool { (error as? FixtureError) == .cancelled }
    static func isMissingEntitlement(_ error: Error) -> Bool { false }
}
final class UserDefaultsManagement {
    static var shared: UserDefaults?
    static var allowTouchID = false
    struct Constants { static let SuppressNewEncryptionFormatNotice = "suppressNewEncryptionFormatNotice" }
''' + method(defaults, "    static var suppressNewEncryptionFormatNotice:") + r'''
}
final class EditorViewController {
    private static var retrievingPIVPassword = false
    private static var passwordRequestGeneration: UInt64 = 0
    var prompts = 0
    var validated = false
    func masterPasswordPrompt(validation: Bool = false, reason: String? = nil, completion: @escaping (String) -> ()) {
        prompts += 1; validated = validation; completion("manual password")
    }
''' + methods + r'''
}
let suite = "consolinotes-password-routing-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
UserDefaultsManagement.shared = defaults
defer { defaults.removePersistentDomain(forName: suite) }
func reset() {
    defaults.removePersistentDomain(forName: suite)
    UserDefaultsManagement.allowTouchID = false
    PIVPasswordProvider.shared.saved = nil
    PIVPasswordProvider.shared.error = nil
    PIVPasswordProvider.shared.readFails = false
    PIVPasswordProvider.shared.calls = 0
    KeychainConfiguration.calls = 0
    KeychainConfiguration.error = nil
    NSAlert.choices = []; NSAlert.shown = []
    DispatchQueue.holdBackground = false; DispatchQueue.pending = []
}
func run(_ encrypt: Bool = false) -> (EditorViewController, String?) {
    let editor = EditorViewController(); var received: String?
    editor.getMasterPassword(forEncrypt: encrypt, allowPIV: true) { received = $0 }
    expect(NSAlert.choices.isEmpty, "Expected dialog did not appear")
    return (editor, received)
}
reset()
expect(!UserDefaultsManagement.suppressNewEncryptionFormatNotice, "First encryption must show notice")
NSAlert.choices = [(.alertSecondButtonReturn, true)]
expect(run(true).1 == nil && !UserDefaultsManagement.suppressNewEncryptionFormatNotice, "Cancel persisted suppression or retrieved password")
expect(PIVPasswordProvider.shared.calls == 0 && KeychainConfiguration.calls == 0, "Cancel accessed a secret")
NSAlert.choices = [(.alertFirstButtonReturn, true)]
let initial = run(true)
expect(initial.1 == "manual password" && initial.0.validated, "Encryption lost password validation")
expect(UserDefaultsManagement.suppressNewEncryptionFormatNotice, "Confirmed opt-out not saved")
UserDefaultsManagement.shared = UserDefaults(suiteName: suite)
expect(UserDefaultsManagement.suppressNewEncryptionFormatNotice, "Opt-out did not survive new defaults instance")
expect(run(true).1 == "manual password", "Suppressed notice interrupted encryption")
PIVPasswordProvider.shared.saved = .init(displayName: "Synthetic identity")
expect(run(true).1 == "manual password" && PIVPasswordProvider.shared.calls == 0,
       "An optional public-key envelope must not choose the password of new ciphertext")
let folderEditor = EditorViewController()
var folderPassword: String?
folderEditor.getMasterPassword(allowPIV: false) { folderPassword = $0 }
expect(folderPassword == "manual password" && PIVPasswordProvider.shared.calls == 0,
       "Folder protection must not accept a password from an optional envelope")
reset()
NSAlert.choices = [(.alertFirstButtonReturn, false)]
_ = run(true)
expect(!UserDefaultsManagement.suppressNewEncryptionFormatNotice, "Unchecked notice was suppressed")
reset()
expect(run().1 == "manual password", "Default manual source changed")
UserDefaultsManagement.allowTouchID = true
expect(run().1 == "keychain password", "Existing saved source broken")
for response in [Response.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn, .cancel] {
    reset(); UserDefaultsManagement.allowTouchID = true
    PIVPasswordProvider.shared.saved = .init(displayName: "Synthetic identity")
    NSAlert.choices = [(response, false)]
    let result = run()
    switch response {
    case .alertFirstButtonReturn:
        expect(result.1 == "token password" && PIVPasswordProvider.shared.calls == 1 && KeychainConfiguration.calls == 0, "Hardware source bypassed")
    case .alertSecondButtonReturn:
        expect(result.1 == "manual password" && PIVPasswordProvider.shared.calls == 0 && KeychainConfiguration.calls == 0, "Manual source accessed saved secret")
    case .alertThirdButtonReturn:
        expect(result.1 == "keychain password" && PIVPasswordProvider.shared.calls == 0, "Keychain source accessed token")
    case .cancel:
        expect(result.1 == nil && PIVPasswordProvider.shared.calls == 0 && KeychainConfiguration.calls == 0, "Cancel accessed a secret")
    }
}
for error in [FixtureError.cancelled, .unavailable] {
    reset(); UserDefaultsManagement.allowTouchID = true
    PIVPasswordProvider.shared.saved = .init(displayName: "Synthetic identity")
    PIVPasswordProvider.shared.error = error
    NSAlert.choices = [(.alertFirstButtonReturn, false)]
    if error == .unavailable { NSAlert.choices.append((.alertSecondButtonReturn, false)) }
    let result = run()
    expect(result.1 == nil && result.0.prompts == 0 && KeychainConfiguration.calls == 0, "Token failure silently fell back")
    expect(PIVPasswordProvider.shared.calls == 1, "Token failure retried PIN operation")
}
reset(); PIVPasswordProvider.shared.saved = .init(displayName: "Synthetic identity")
PIVPasswordProvider.shared.error = .unavailable
NSAlert.choices = [(.alertFirstButtonReturn, false), (.alertFirstButtonReturn, false)]
expect(run().1 == "manual password" && KeychainConfiguration.calls == 0, "Explicit manual fallback broken")
reset(); PIVPasswordProvider.shared.readFails = true
NSAlert.choices = [(.alertSecondButtonReturn, false)]
expect(run().1 == nil && PIVPasswordProvider.shared.calls == 0, "Corrupt enrollment invoked token")
// An OS authentication result arriving after Lock All/sleep/quit must not unlock.
for useToken in [true, false] {
    reset(); UserDefaultsManagement.allowTouchID = true
    if useToken {
        PIVPasswordProvider.shared.saved = .init(displayName: "Synthetic identity")
        NSAlert.choices = [(.alertFirstButtonReturn, false)]
    }
    DispatchQueue.holdBackground = true
    var received: String?
    let editor = EditorViewController()
    editor.getMasterPassword(allowPIV: true) { received = $0 }
    expect(DispatchQueue.pending.count == 1, "Expected an outstanding authentication request")
    EditorViewController.cancelPasswordRequests()
    DispatchQueue.pending.removeFirst()()
    expect(received == nil && editor.prompts == 0, "Delayed authentication reversed a lock")
}
print("PASS: encryption opt-out persistence/cancel; explicit password sources; token cancellation/failure and manual fallback; no real credentials accessed")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-password-routing-") as directory:
    directory = Path(directory)
    source = directory / "main.swift"
    source.write_text(fixture)
    binary = directory / "routing-tests"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(directory / "modules"), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
