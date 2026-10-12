#!/usr/bin/env python3
"""Exercise the production AppKit YubiKey workflow using only a fake provider.

The fixture drives its own temporary windows, never the installed app. Each
synthetic hardware operation blocks until released by the scenario, so tests
can distinguish a displayed prompt from an operation actually being started.
No USB, Keychain, note files, enrollment files, or real secrets are accessed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = r'''
import Cocoa

final class FIDO2PasswordProvider {
    struct Enrollment { let id: String; var name: String }
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
    func enroll(name: String, password: String, pin: String, ticket: UInt64, beforeActivation: (Int) -> Bool) throws {
        guard password == "synthetic-password", pin == "synthetic-pin" else { throw Failure("Fixture credentials mismatch") }
        for step in 1...3 {
            guard current(ticket), beforeActivation(step), current(ticket) else { throw Failure("Cancelled") }
            try activate("enroll-\(step)", ticket: ticket)
        }
        guarded { records.append(Enrollment(id: "new", name: name)); mutationLog.append("add:new") }
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
func activation(_ step: Int, cancel: Bool = false, release: Bool = true) {
    let title = "Activation \(step) of 3: \(activationTitles[step - 1])"
    onAlert(title) { _ in expect(provider.operations.count == step - 1, "Hardware began before Continue for step \(step)") }
    pause("step \(step) waits for Continue") {
        expect(provider.operations.count == step - 1, "Prompt did not gate hardware step \(step)")
        click(cancel ? "Cancel" : "Continue", in: alert(title)!)
    }
    if !cancel {
        let waiting = "Activation \(step) of 3: Touch your YubiKey now"
        stage("activation \(step) running", when: { alert(waiting) != nil && provider.operations.count == step }) {
            expect(provider.operations.last == "enroll-\(step)", "Wrong hardware operation")
            if release { provider.releaseActivation() }
        }
    }
}
func verifyUnchanged() {
    expect((try! provider.enrollments()).map { $0.id } == ["everyday", "backup"], "Cancellation changed enrollments")
    expect(provider.mutations.isEmpty, "Cancellation wrote enrollment")
}
func beginUnlock(release: Bool = true) {
    onAlert("Choose a YubiKey to unlock") { dialog in
        let selection = picker(in: dialog)
        expect(selection.itemTitles == ["Everyday", "Backup"], "Unlock picker missing named enrollments")
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

switch scenario {
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
    } else { FIDO2UnlockUI.settings(from: controller) }
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
        for scenario in ["enroll", "cancel-first", "cancel-between", "cancel-running", "external-cancel", "close-window", "rename-remove", "unlock", "cancel-unlock", "fallback"]:
            subprocess.run([str(work / "test"), scenario], check=True, timeout=45)


if __name__ == "__main__":
    main()
