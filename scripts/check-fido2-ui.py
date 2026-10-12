#!/usr/bin/env python3
"""Exercise the production AppKit YubiKey workflow using only a fake provider.

The fixture drives its own temporary windows, never the installed app. Each
synthetic hardware operation blocks until released by the scenario, so tests
can distinguish a displayed prompt from an operation actually being started.
No USB, Keychain, note files, enrollment files, or real secrets are accessed.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = r'''
import Cocoa

final class FIDO2PasswordProvider {
    struct Protection { let group: String; let mode: String }
    struct Envelope { var protection: Protection? = nil }
    struct Enrollment { let id: String; var name: String; var envelope = Envelope() }
    struct PasswordProof {}
    final class StrongProtectionPlan {
        init() throws {}
        var recoverySecret = "synthetic-recovery-password"
        func verifyRecovery(_ entered: String) throws -> PasswordProof {
            guard entered == recoverySecret else { throw Failure("Recovery mismatch") }; return PasswordProof()
        }
        func clear() { recoverySecret = "" }
    }
    static func verifyPassword(_ password: String, using verify: (String) -> Bool) throws -> PasswordProof {
        guard verify(password) else { throw Failure("Password does not unlock selected note") }; return PasswordProof()
    }
    static func verifyBackupPassword(_ password: String, of entry: Enrollment, using verify: (String) -> Bool) throws -> PasswordProof {
        try verifyPassword(password, using: verify)
    }
    struct ImportSummary { let added: Int; let alreadyPresent: Int }
    func exportFile(_ url: URL, ticket: UInt64) throws {}
    func importFile(_ url: URL, ticket: UInt64) throws -> ImportSummary { ImportSummary(added: 0, alreadyPresent: 0) }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
    static let shared = FIDO2PasswordProvider()
    static let worker = DispatchQueue(label: "consolinotes.fixture.fido")
    private let lock = NSLock()
    private let hardwareGate = DispatchSemaphore(value: 0)
    private var generation: UInt64 = 0
    private var records = [Enrollment(id: "everyday", name: "Everyday"), Enrollment(id: "backup", name: "Backup")]
    private var operationLog = [String]()
    private var mutationLog = [String]()
    var failUnlock = false
    var failEnrollment = false
    private func guarded<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func ticket() -> UInt64 { guarded { generation } }
    func current(_ ticket: UInt64) -> Bool { guarded { generation == ticket } }
    func cancel() { guarded { generation += 1 } }
    func enrollments() throws -> [Enrollment] { guarded { records } }
    func load() -> Bool? { guarded { records.isEmpty ? nil : true } }
    var operations: [String] { guarded { operationLog } }
    var mutations: [String] { guarded { mutationLog } }
    func releaseActivation() { hardwareGate.signal() }
    private func activate(_ name: String, ticket: UInt64) throws {
        guarded { operationLog.append(name) }
        guard hardwareGate.wait(timeout: .now() + 8) == .success else { throw Failure("Fixture operation timed out") }
        guard current(ticket) else { throw Failure("Cancelled") }
    }
    @discardableResult
    func enroll(name: String, password: String, proof: PasswordProof, pin: String, ticket: UInt64, beforeActivation: (Int) -> Bool) throws -> Enrollment {
        guard ["synthetic-password", "synthetic-password-for-backup", "synthetic-recovery-password"].contains(password), pin == "synthetic-pin" else { throw Failure("Fixture credentials mismatch") }
        for step in 1...3 {
            guard current(ticket), beforeActivation(step), current(ticket) else { throw Failure("Cancelled") }
            try activate("enroll-\(step)", ticket: ticket)
        }
        guard !failEnrollment else { throw Failure("Synthetic final verification failure") }
        return guarded { let record = Enrollment(id: "new", name: name); records.append(record); mutationLog.append("add:new"); return record }
    }
    func unlock(id: String, pin: String, ticket: UInt64, beforeActivation: () -> Bool) throws -> String {
        guard pin == "synthetic-pin", current(ticket), beforeActivation(), current(ticket) else { throw Failure("Cancelled") }
        try activate("unlock:\(id)", ticket: ticket)
        if failUnlock { throw Failure("Synthetic wrong-key failure") }
        return "synthetic-password-for-\(id)"
    }
    func rename(id: String, name: String) throws {
        guarded {
            if let index = records.firstIndex(where: { $0.id == id }) { records[index].name = name; mutationLog.append("rename:\(id)") }
        }
    }
    func remove(id: String) throws {
        guarded { records.removeAll { $0.id == id }; mutationLog.append("remove:\(id)"); generation += 1 }
    }
}

final class Note {
    static let fixture = Note()
    var acceptsPassword = true
    var verificationCalls = 0
    var rotations = [String]()
    var lastWriteError: String?
    func isEncrypted() -> Bool { true }
    func isEncryptedAndLocked() -> Bool { false }
    func isUnlocked() -> Bool { true }
    func verifyEncryptionPassword(_ password: String) -> Bool { verificationCalls += 1; return acceptsPassword }
    func rotateEncryptionSecret(to secret: String, isCancelled: () -> Bool) -> Bool {
        expect(Thread.isMainThread, "Rotation read mutable editor state off-main")
        guard !isCancelled() else { return false }; rotations.append(secret); return true
    }
}
final class NoteTable {
    func getSelectedNotes() -> [Note] { [Note.fixture] }
    func reloadData() {}
}
final class ViewController {
    static let instance = ViewController()
    static func shared() -> ViewController? { instance }
    let notesTableView = NoteTable()
}
enum SensitiveClipboard { static func writeString(_ value: String) {} }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}
func expect(_ value: Bool, _ message: String) { if !value { fail(message) } }
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func views(_ window: NSWindow) -> [NSView] { window.contentView.map(descendants) ?? [] }
func alert(_ title: String) -> NSWindow? {
    NSApplication.shared.windows.first { window in
        window.isVisible && views(window).contains { ($0 as? NSTextField)?.stringValue == title }
    }
}
func button(_ title: String, in window: NSWindow) -> NSButton {
    guard let button = views(window).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { fail("Missing button: \(title)") }
    return button
}
func click(_ title: String, in window: NSWindow) {
    let item = button(title, in: window)
    expect(item.isEnabled, "Disabled button: \(title)")
    item.performClick(nil)
}
func input(_ placeholder: String, in window: NSWindow) -> NSTextField {
    guard let input = views(window).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == placeholder }) else { fail("Missing input: \(placeholder)") }
    return input
}
func picker(in window: NSWindow) -> NSPopUpButton {
    guard let picker = views(window).compactMap({ $0 as? NSPopUpButton }).first else { fail("Missing enrollment picker") }
    return picker
}

struct Stage { let name: String; let ready: () -> Bool; let action: () -> Void }
var stages = [Stage]()
func stage(_ name: String, when ready: @escaping () -> Bool, _ action: @escaping () -> Void = {}) {
    stages.append(Stage(name: name, ready: ready, action: action))
}
func onAlert(_ title: String, _ action: @escaping (NSWindow) -> Void) {
    stage(title, when: { alert(title) != nil }) { action(alert(title)!) }
}
var pauseEnds: Date?
func pause(_ name: String, _ action: @escaping () -> Void) {
    stage(name, when: {
        if pauseEnds == nil { pauseEnds = Date().addingTimeInterval(0.35) }
        return Date() >= pauseEnds!
    }) { pauseEnds = nil; action() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = NSViewController()
controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "consolinotes synthetic YubiKey UI test"
window.contentViewController = controller
window.makeKeyAndOrderFront(nil)
let provider = FIDO2PasswordProvider.shared
let scenario = CommandLine.arguments[1]
var received = [String]()
var fallbackCount = 0
func beginEnrollment() {
    onAlert("YubiKey enrollments") { dialog in
        expect(picker(in: dialog).itemTitles == ["Everyday", "Backup"], "Existing named enrollments missing")
        click("Add YubiKey…", in: dialog)
    }
    onAlert("Add a YubiKey") { dialog in
        input("Enrollment name (e.g. Everyday or Backup)", in: dialog).stringValue = "Travel"
        input("Existing note password", in: dialog).stringValue = "synthetic-password"
        input("FIDO2 PIN", in: dialog).stringValue = "synthetic-pin"
        click("Continue", in: dialog)
        expect(input("Existing note password", in: dialog).stringValue.isEmpty, "Password input not cleared")
        expect(input("FIDO2 PIN", in: dialog).stringValue.isEmpty, "PIN input not cleared")
    }
}
let activationTitles = ["Create this key's credential", "Protect the saved password", "Verify this key can unlock it"]
func activation(_ step: Int, cancel: Bool = false, release: Bool = true, offset: Int = 0) {
    let title = "Activation \(step) of 3: \(activationTitles[step - 1])"
    onAlert(title) { _ in expect(provider.operations.count == offset + step - 1, "Hardware began before Continue for step \(step)") }
    pause("step \(step) waits for Continue") {
        expect(provider.operations.count == offset + step - 1, "Prompt did not gate hardware step \(step)")
        click(cancel ? "Cancel" : "Continue", in: alert(title)!)
    }
    if !cancel {
        let waiting = "Activation \(step) of 3: Touch your YubiKey now"
        stage("activation \(step) running", when: { alert(waiting) != nil && provider.operations.count == offset + step }) {
            expect(provider.operations.last == "enroll-\(step)", "Wrong hardware operation")
            expect(Note.fixture.rotations.isEmpty, "Note changed before final hardware verification completed")
            if release { provider.releaseActivation() }
        }
    }
}
func verifyUnchanged() {
    expect((try! provider.enrollments()).map { $0.id } == ["everyday", "backup"], "Cancellation changed enrollments")
    expect(provider.mutations.isEmpty, "Cancellation wrote enrollment")
}
func beginUnlock(release: Bool = true, fixedSelection: Bool = false) {
    onAlert("Choose a YubiKey to unlock") { dialog in
        let selection = picker(in: dialog)
        expect(selection.itemTitles == ["Everyday", "Backup"], "Unlock picker missing named enrollments")
        if fixedSelection { expect(!selection.isEnabled && selection.indexOfSelectedItem == 1, "Management unlock did not bind selected enrollment") }
        selection.selectItem(at: 1)
        input("FIDO2 PIN", in: dialog).stringValue = "synthetic-pin"
        click("Continue", in: dialog)
    }
    let title = "Activation 1 of 1: Unlock with “Backup”"
    onAlert(title) { _ in expect(provider.operations.isEmpty, "Unlock began before activation prompt") }
    pause("unlock waits for Continue") {
        expect(provider.operations.isEmpty, "Unlock bypassed Continue")
        click("Continue", in: alert(title)!)
    }
    stage("selected-key unlock running", when: { provider.operations == ["unlock:backup"] && alert("Activation 1 of 1: Touch your YubiKey now") != nil }) {
        expect(received.isEmpty && fallbackCount == 0, "Password delivered before hardware completed")
        if release { provider.releaseActivation() }
    }
}

func managementAction(_ title: String) {
    onAlert("YubiKey enrollments") { dialog in
        picker(in: dialog).selectItem(at: 1); click(title, in: dialog)
    }
}
func sourceEnrollment() {
    onAlert("Add a YubiKey") { dialog in
        expect(!views(dialog).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Existing note password" }, "Verified source asked for another note password")
        input("Enrollment name (e.g. Everyday or Backup)", in: dialog).stringValue = "Travel"
        input("FIDO2 PIN", in: dialog).stringValue = "synthetic-pin"
        click("Continue", in: dialog)
    }
}
func startStrongRecovery() {
    onAlert("Protect this note with YubiKey and recovery?") { dialog in
        expect(Note.fixture.rotations.isEmpty, "Rotation before confirmation")
        click("Set Up Recovery", in: dialog)
    }
    onAlert("Save this recovery password offline") { dialog in
        expect(provider.operations.isEmpty && Note.fixture.rotations.isEmpty, "Hardware or note changed before recovery")
        expect(views(dialog).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "synthetic-recovery-password" }, "Recovery secret missing")
        click("I Saved It Offline", in: dialog)
    }
}
switch scenario {
case "wrong-note":
    Note.fixture.acceptsPassword = false
    beginEnrollment()
    onAlert("YubiKey was not added") { dialog in
        expect(Note.fixture.verificationCalls == 1 && provider.operations.isEmpty, "Wrong note password reached hardware")
        verifyUnchanged(); click("Close", in: dialog)
    }
case "test-enrollment", "test-wrong-note":
    Note.fixture.acceptsPassword = scenario == "test-enrollment"
    managementAction("Test Enrollment…"); beginUnlock(fixedSelection: true)
    onAlert(scenario == "test-enrollment" ? "Enrollment verified" : "This enrollment does not unlock the selected note") { dialog in
        expect(Note.fixture.verificationCalls == 1 && Note.fixture.rotations.isEmpty, "Test did not authenticate without mutation")
        expect(provider.operations == ["unlock:backup"], "Test retried hardware")
        click("OK", in: dialog)
    }
case "add-backup", "backup-wrong-note":
    Note.fixture.acceptsPassword = scenario == "add-backup"
    managementAction("Add Backup Key…"); beginUnlock(fixedSelection: true)
    if scenario == "backup-wrong-note" {
        onAlert("YubiKey request could not be completed") { dialog in
            verifyUnchanged(); expect(provider.operations == ["unlock:backup"], "Wrong backup password began enrollment")
            click("OK", in: dialog)
        }
    } else {
        onAlert("Connect your backup YubiKey") { dialog in
            expect(Note.fixture.verificationCalls == 1, "Backup did not authenticate selected note")
            click("Backup Key Connected", in: dialog)
        }
        sourceEnrollment()
        for step in 1...3 { activation(step, offset: 1) }
        onAlert("“Travel” is ready") { dialog in
            expect(provider.operations == ["unlock:backup", "enroll-1", "enroll-2", "enroll-3"], "Backup activation sequence")
            expect((try! provider.enrollments()).count == 3, "Backup replaced previous enrollment")
            click("Done", in: dialog)
        }
    }
case "strong", "strong-wrong-recovery", "strong-cancel", "strong-hardware-failure", "strong-lock-recovery", "strong-durability-warning":
    let strongSuccess = ["strong", "strong-durability-warning"].contains(scenario)
    if scenario == "strong-durability-warning" { Note.fixture.lastWriteError = "The new secret applies; an encrypted recovery snapshot was retained." }
    startStrongRecovery()
    onAlert("Verify your saved recovery password") { dialog in
        let entered = input("Recovery password", in: dialog)
        entered.stringValue = scenario == "strong-wrong-recovery" ? "wrong" : "synthetic-recovery-password"
        if scenario == "strong-lock-recovery" {
            FIDO2UnlockUI.cancelPendingRequests()
            expect(entered.stringValue.isEmpty, "Lock retained recovery password")
        } else { click("Verify Recovery", in: dialog) }
    }
    if scenario == "strong-lock-recovery" {
        pause("recovery lock settled") { verifyUnchanged(); expect(provider.operations.isEmpty && Note.fixture.rotations.isEmpty, "Locked recovery changed note or key") }
    } else if scenario == "strong-wrong-recovery" {
        onAlert("YubiKey request could not be completed") { dialog in
            expect(provider.operations.isEmpty && Note.fixture.rotations.isEmpty, "Wrong recovery changed note or key")
            click("OK", in: dialog)
        }
    } else {
        sourceEnrollment()
        activation(1); activation(2)
        if scenario == "strong-cancel" {
            activation(3, cancel: true)
            pause("strong cancellation settled") { verifyUnchanged(); expect(Note.fixture.rotations.isEmpty, "Cancelled setup rotated note") }
        } else {
            provider.failEnrollment = scenario == "strong-hardware-failure"
            activation(3)
            onAlert(strongSuccess ? "Note protection updated" : "YubiKey was not added") { dialog in
                expect(provider.operations.count == 3, "Strong mode missing verified hardware operations")
                if strongSuccess {
                    expect(Note.fixture.rotations == ["synthetic-recovery-password"], "Strong mode used wrong or repeated secret")
                    if let warning = Note.fixture.lastWriteError { expect(views(dialog).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(warning) }, "Successful publication lost durability warning") }
                }
                else { verifyUnchanged(); expect(Note.fixture.rotations.isEmpty, "Failed hardware verification rotated note") }
                click(strongSuccess ? "OK" : "Close", in: dialog)
            }
        }
    }
case "enroll":
    beginEnrollment()
    for step in 1...3 { activation(step) }
    onAlert("“Travel” is ready") { dialog in
        expect((try! provider.enrollments()).map { $0.name } == ["Everyday", "Backup", "Travel"], "Adding key replaced another enrollment")
        expect(provider.operations == ["enroll-1", "enroll-2", "enroll-3"], "Unexpected activation count")
        click("Done", in: dialog)
    }
case "cancel-first":
    beginEnrollment(); activation(1, cancel: true)
    stage("first cancellation dismissed", when: { window.attachedSheet == nil }) { verifyUnchanged(); expect(provider.operations.isEmpty, "First cancellation invoked hardware") }
case "cancel-between":
    beginEnrollment(); activation(1); activation(2, cancel: true)
    stage("between cancellation dismissed", when: { window.attachedSheet == nil }) { verifyUnchanged(); expect(provider.operations == ["enroll-1"], "Between cancellation invoked later hardware") }
case "cancel-running":
    beginEnrollment(); activation(1); activation(2, release: false)
    onAlert("Activation 2 of 3: Touch your YubiKey now") { click("Cancel", in: $0) }
    onAlert("Cancelling YubiKey request…") { _ in verifyUnchanged() }
    pause("cancel waits for worker") {
        expect(provider.operations == ["enroll-1", "enroll-2"], "Cancelled worker advanced")
        provider.releaseActivation()
    }
    stage("running cancellation dismissed", when: { window.attachedSheet == nil }) { verifyUnchanged(); expect(provider.operations.count == 2, "Third activation ran after cancellation") }
case "external-cancel":
    beginEnrollment(); activation(1)
    onAlert("Activation 2 of 3: Protect the saved password") { _ in provider.cancel() }
    stage("external cancellation dismissed", when: { window.attachedSheet == nil }) { verifyUnchanged(); expect(provider.operations == ["enroll-1"], "Lock invalidation allowed another activation") }
case "close-window":
    beginEnrollment()
    onAlert("Activation 1 of 3: Create this key's credential") { _ in window.orderOut(nil) }
    stage("closed parent cancellation", when: { window.attachedSheet == nil }) { verifyUnchanged(); expect(provider.operations.isEmpty, "Closed parent allowed an activation") }
case "lock-management":
    onAlert("YubiKey enrollments") { dialog in picker(in: dialog).selectItem(at: 1); click("Rename…", in: dialog) }
    onAlert("Rename enrollment") { dialog in
        let name = input("Enrollment name", in: dialog)
        name.stringValue = "private key name"
        FIDO2UnlockUI.cancelPendingRequests()
        expect(name.stringValue.isEmpty, "Lock retained enrollment name")
    }
    pause("management cancellation settled") {
        verifyUnchanged()
        expect(alert("YubiKey enrollments") == nil && alert("Rename enrollment") == nil, "Cancelled settings reopened")
    }
case "lock-initial":
    onAlert("YubiKey enrollments") { click("Add YubiKey…", in: $0) }
    onAlert("Add a YubiKey") { dialog in
        let pin = input("FIDO2 PIN", in: dialog)
        let password = input("Existing note password", in: dialog)
        pin.stringValue = "synthetic-pin"; password.stringValue = "synthetic-password"
        FIDO2UnlockUI.cancelPendingRequests()
        expect(pin.stringValue.isEmpty && password.stringValue.isEmpty, "Lock retained prompt secrets")
    }
    stage("initial lock dismissed", when: { window.attachedSheet == nil }) {
        verifyUnchanged(); expect(provider.operations.isEmpty, "Initial lock activated hardware")
    }
case "lock-activation":
    beginEnrollment(); activation(1, release: false)
    onAlert("Activation 1 of 3: Touch your YubiKey now") { _ in
        FIDO2UnlockUI.cancelPendingRequests()
        expect(window.attachedSheet == nil, "Lock left activation prompt visible")
        provider.releaseActivation()
    }
    pause("locked worker settles") { verifyUnchanged(); expect(provider.operations == ["enroll-1"], "Locked worker advanced") }
case "close-initial":
    onAlert("YubiKey enrollments") { click("Add YubiKey…", in: $0) }
    onAlert("Add a YubiKey") { dialog in
        let pin = input("FIDO2 PIN", in: dialog)
        pin.stringValue = "synthetic-pin"
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        expect(pin.stringValue.isEmpty, "Window close retained PIN")
    }
    stage("initial closed window dismissed", when: { window.attachedSheet == nil }) {
        verifyUnchanged(); expect(provider.operations.isEmpty, "Window close activated hardware")
    }
case "rename-remove":
    onAlert("YubiKey enrollments") { dialog in picker(in: dialog).selectItem(at: 1); click("Rename…", in: dialog) }
    onAlert("Rename enrollment") { dialog in
        expect(input("Enrollment name", in: dialog).stringValue == "Backup", "Rename chose wrong entry")
        input("Enrollment name", in: dialog).stringValue = "Spare"
        click("Rename", in: dialog)
    }
    onAlert("YubiKey enrollments") { dialog in
        expect(picker(in: dialog).itemTitles == ["Everyday", "Spare"], "Rename changed wrong entry")
        picker(in: dialog).selectItem(at: 1); click("Remove…", in: dialog)
    }
    onAlert("Remove “Spare”?") { click("Remove Enrollment", in: $0) }
    onAlert("YubiKey enrollments") { dialog in
        expect(picker(in: dialog).itemTitles == ["Everyday"], "Removal changed wrong entry")
        expect(provider.mutations == ["rename:backup", "remove:backup"], "Wrong selected ID mutated")
        expect(provider.operations.isEmpty, "Management activated hardware")
        click("Done", in: dialog)
    }
case "unlock":
    beginUnlock()
    stage("selected password delivered", when: { received == ["synthetic-password-for-backup"] }) { expect(fallbackCount == 0, "Unexpected fallback") }
case "cancel-unlock":
    beginUnlock(release: false)
    onAlert("Activation 1 of 1: Touch your YubiKey now") { click("Cancel", in: $0) }
    onAlert("Cancelling YubiKey request…") { _ in provider.releaseActivation() }
    stage("unlock cancellation dismissed", when: { window.attachedSheet == nil }) {
        expect(received.isEmpty && fallbackCount == 0, "Cancelled unlock delivered a password or fell back")
        expect(provider.operations == ["unlock:backup"], "Cancelled unlock retried hardware")
    }
case "fallback":
    provider.failUnlock = true
    beginUnlock()
    onAlert("YubiKey could not unlock this password") { dialog in expect(received.isEmpty && fallbackCount == 0, "Failure returned a password or silently fell back"); click("Enter Note Password…", in: dialog) }
    stage("explicit fallback", when: { fallbackCount == 1 }) { expect(received.isEmpty, "Failure delivered hardware password") }
default: fail("Unknown scenario")
}

pause("settled") {
    expect(window.attachedSheet == nil, "Workflow left a sheet open")
    print("PASS: AppKit \(scenario)")
    window.orderOut(nil)
    exit(0)
}
var stageStarted = Date()
let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
    guard let next = stages.first else { fail("No completion stage") }
    if Date().timeIntervalSince(stageStarted) > 10 { fail("Timed out waiting for \(next.name)") }
    if next.ready() {
        stages.removeFirst(); stageStarted = Date()
        next.action()
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.add(timer, forMode: .modalPanel)
DispatchQueue.main.async {
    if scenario == "unlock" || scenario == "fallback" || scenario == "cancel-unlock" {
        FIDO2UnlockUI.unlock(from: controller, completion: { received.append($0) }, manualFallback: { fallbackCount += 1 })
    } else if scenario.hasPrefix("strong") { FIDO2UnlockUI.protectSelectedNote(from: controller) }
    else { FIDO2UnlockUI.settings(from: controller) }
}
app.run()
'''


def main():
    with tempfile.TemporaryDirectory(prefix="consolinotes-fido-ui-") as temporary:
        work = Path(temporary)
        (work / "main.swift").write_text(FIXTURE)
        subprocess.run([
            "xcrun", "swiftc", "-module-cache-path", str(work / "modules"),
            str(ROOT / "FSNotes/Preferences/FIDO2UnlockUI.swift"),
            str(work / "main.swift"), "-o", str(work / "test")
        ], check=True)
        for scenario in sys.argv[1:] or ["enroll", "cancel-first", "cancel-between", "cancel-running", "external-cancel", "close-window", "rename-remove", "unlock", "cancel-unlock", "fallback", "lock-initial", "lock-activation", "close-initial", "lock-management", "wrong-note", "test-enrollment", "test-wrong-note", "add-backup", "backup-wrong-note", "strong", "strong-wrong-recovery", "strong-cancel", "strong-hardware-failure", "strong-lock-recovery", "strong-durability-warning"]:
            subprocess.run([str(work / "test"), scenario], check=True, timeout=45)


if __name__ == "__main__":
    main()
