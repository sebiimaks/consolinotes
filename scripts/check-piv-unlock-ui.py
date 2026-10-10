#!/usr/bin/env python3
"""Exercise the real enrollment sheet with a synthetic provider; no key or Keychain access."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Cocoa

final class PIVPasswordProvider {
    struct Identity { let fingerprint: String; let tokenID: String; let displayName: String }
    struct Enrollment { let fingerprint: String; let tokenID: String; let displayName: String }
    enum Failure: Error { case cancelled }
    static let shared = PIVPasswordProvider()
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    var keyPresent = true
    var enrolled = false
    func identities() throws -> [Identity] {
        keyPresent ? [Identity(fingerprint: String(repeating: "ab", count: 32), tokenID: "fixture", displayName: "Synthetic PIV identity")] : []
    }
    func enrollment() throws -> Enrollment? {
        enrolled ? Enrollment(fingerprint: String(repeating: "ab", count: 32), tokenID: "fixture", displayName: "Synthetic PIV identity") : nil
    }
    func enroll(password: String, identity: Identity) throws {
        precondition(!Thread.isMainThread, "Hardware operation must not block the main thread")
        precondition(password == "synthetic note password")
        started.signal()
        precondition(finish.wait(timeout: .now() + 5) == .success)
        throw Failure.cancelled
    }
    func unlock() throws -> String { fatalError("UI must not unlock merely by opening settings") }
    func removeEnrollment() throws { fatalError("Removal must require explicit confirmation") }
    static func isCancellation(_ error: Error) -> Bool { error is Failure }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func spin(until predicate: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !predicate() && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    require(predicate(), "UI operation did not finish")
}
func find(_ identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier { return view }
    for child in view.subviews {
        if let match = find(identifier, in: child) { return match }
    }
    return nil
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let controller = PIVUnlockViewController()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.contentViewController = controller
controller.viewDidAppear()
let refresh = find("piv.refresh", in: controller.view) as! NSButton
let save = find("piv.save", in: controller.view) as! NSButton
let done = find("piv.done", in: controller.view) as! NSButton
let policy = find("piv.policy-confirmation", in: controller.view) as! NSButton
let password = find("piv.password", in: controller.view) as! NSSecureTextField
let repeated = find("piv.repeat-password", in: controller.view) as! NSSecureTextField
let status = find("piv.status", in: controller.view) as! NSTextField
spin { refresh.isEnabled }
require(!save.isEnabled, "Enrollment requires explicit policy acknowledgement")
policy.performClick(nil)
require(save.isEnabled, "Enrollment should become available after acknowledgement")
password.stringValue = "\u{e9}"
repeated.stringValue = "e\u{301}"
save.performClick(nil)
require(status.stringValue.contains("does not match"), "Canonical-equivalent but byte-different passwords must not match")
require(PIVPasswordProvider.shared.started.wait(timeout: .now()) == .timedOut, "Mismatch must not reach the key")
password.stringValue = "synthetic note password"
repeated.stringValue = password.stringValue
save.performClick(nil)
require(PIVPasswordProvider.shared.started.wait(timeout: .now() + 2) == .success, "Expected enrollment operation")
require(password.stringValue.isEmpty && repeated.stringValue.isEmpty, "Secure fields must clear before the private operation")
require(!save.isEnabled && !refresh.isEnabled && !done.isEnabled && !password.isEnabled, "Controls must be disabled during the private operation")
require(!controller.windowShouldClose(window), "Sheet must not close during the private operation")
PIVPasswordProvider.shared.finish.signal()
spin { done.isEnabled }
require(status.stringValue.hasPrefix("Canceled."), "Cancellation should preserve manual fallback guidance")
require(password.stringValue.isEmpty && repeated.stringValue.isEmpty, "Cancellation must not retain field contents")
require(controller.windowShouldClose(window), "Sheet should close after operation completes")
PIVPasswordProvider.shared.enrolled = true
PIVPasswordProvider.shared.keyPresent = false
refresh.performClick(nil)
spin { refresh.isEnabled }
require((find("piv.remove", in: controller.view) as! NSButton).isEnabled, "Saved ciphertext must remain removable while key is absent")
require((find("piv.saved-identity", in: controller.view) as! NSTextField).stringValue.contains("Synthetic PIV identity"), "Enrollment metadata should persist without an inserted key")
require(!save.isEnabled, "Missing key must not allow enrollment")
controller.view.layoutSubtreeIfNeeded()
func checkLayout(_ view: NSView) {
    require(!view.hasAmbiguousLayout, "Enrollment UI has ambiguous layout")
    for child in view.subviews { checkLayout(child) }
}
checkLayout(controller.view)
print("PIV enrollment UI: exact password bytes, cancellation, private-operation controls, absent-key metadata and layout passed; no key or Keychain accessed")
'''

with tempfile.TemporaryDirectory(prefix="consolinotes-piv-ui-") as directory:
    temp = pathlib.Path(directory)
    main = temp / "main.swift"
    main.write_text(FIXTURE)
    executable = temp / "fixture"
    subprocess.run([
        "xcrun", "swiftc", "-module-cache-path", str(temp / "module-cache"),
        str(ROOT / "FSNotes/Preferences/PIVUnlockViewController.swift"),
        str(main), "-o", str(executable)
    ], check=True, cwd=ROOT)
    subprocess.run([str(executable)], check=True, cwd=ROOT)
