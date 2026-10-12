import Cocoa

/// Named enrollments and one explicit, user-paced prompt per hardware activation.
enum FIDO2UnlockUI {
    private static var busy = false
    private static let provider = FIDO2PasswordProvider.shared

    private static func available(from controller: NSViewController) -> Bool {
        guard busy else { return true }
        let alert = NSAlert()
        alert.messageText = "Finishing the previous YubiKey request"
        alert.informativeText = "A cancelled USB request can take up to 25 seconds to finish. Please wait before starting another request."
        alert.runModal()
        return false
    }
    private static func field(_ placeholder: String, secure: Bool = false) -> NSTextField {
        let result = secure ? NSSecureTextField() : NSTextField()
        result.placeholderString = placeholder
        result.setAccessibilityLabel(placeholder)
        result.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return result
    }
    private static func accessory(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(views.count * 34))
        return stack
    }
    private static func picker(_ entries: [FIDO2PasswordProvider.Enrollment]) -> NSPopUpButton {
        let result = NSPopUpButton()
        result.addItems(withTitles: entries.map { $0.name })
        result.widthAnchor.constraint(equalToConstant: 360).isActive = true
        result.setAccessibilityLabel("YubiKey enrollment")
        return result
    }
    static func settings(from controller: NSViewController) {
        guard available(from: controller) else { return }
        while true {
            let entries: [FIDO2PasswordProvider.Enrollment]
            do { entries = try provider.enrollments() }
            catch { report(error, from: controller); return }
            let alert = NSAlert()
            alert.messageText = "YubiKey enrollments"
            alert.informativeText = entries.isEmpty
                ? "Add a YubiKey to unlock your encrypted notes. Your original note password remains your recovery method."
                : "Each enrollment stores a password protected by that key. To add a backup, unplug your current key and connect a different YubiKey. Adding an enrollment keeps all existing enrollments."
            let selection = picker(entries)
            if !entries.isEmpty { alert.accessoryView = accessory([selection]) }
            alert.addButton(withTitle: "Add YubiKey…")
            alert.addButton(withTitle: "Rename…").isEnabled = !entries.isEmpty
            alert.addButton(withTitle: "Remove…").isEnabled = !entries.isEmpty
            alert.addButton(withTitle: "Done")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { perform(enrolling: true, from: controller, completion: { _ in }); return }
            guard entries.indices.contains(selection.indexOfSelectedItem) else { return }
            let entry = entries[selection.indexOfSelectedItem]
            if response == .alertSecondButtonReturn {
                let rename = NSAlert(); rename.messageText = "Rename enrollment"
                rename.informativeText = "Choose a name that helps you identify this key, such as Everyday or Backup."
                let name = field("Enrollment name"); name.stringValue = entry.name
                rename.accessoryView = accessory([name])
                rename.addButton(withTitle: "Rename"); rename.addButton(withTitle: "Cancel")
                if rename.runModal() == .alertFirstButtonReturn {
                    do { try provider.rename(id: entry.id, name: name.stringValue) }
                    catch { report(error, from: controller) }
                }
            } else if response == .alertThirdButtonReturn {
                let remove = NSAlert(); remove.messageText = "Remove “\(entry.name)”?"
                remove.informativeText = "Only this local enrollment will be removed. Other enrolled keys and your original note password will still work. This does not reset the YubiKey or change any notes."
                remove.addButton(withTitle: "Remove Enrollment"); remove.addButton(withTitle: "Cancel")
                if remove.runModal() == .alertFirstButtonReturn {
                    do { try provider.remove(id: entry.id) }
                    catch { report(error, from: controller) }
                }
            } else { return }
        }
    }
    static func unlock(from controller: NSViewController, completion: @escaping (String) -> Void,
                       manualFallback: (() -> Void)? = nil) {
        perform(enrolling: false, from: controller, completion: completion, manualFallback: manualFallback)
    }
    private static func report(_ error: Error, from controller: NSViewController) {
        let alert = NSAlert(); alert.messageText = "YubiKey request could not be completed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// Main-thread UI; the worker waits for an explicit Continue before each CTAP operation.
    private final class ActivationSession {
        let window: NSWindow
        let ticket: UInt64
        let enrolling: Bool
        let name: String
        var alert: NSAlert?
        var finished = false
        var cancellationTimer: Timer?
        init(window: NSWindow, ticket: UInt64, enrolling: Bool, name: String) {
            self.window = window; self.ticket = ticket; self.enrolling = enrolling; self.name = name
        }
        func dismiss() {
            if let alert = alert {
                if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .abort) }
                alert.window.orderOut(nil)
            }
            alert = nil
        }
        func cancellationState() {
            guard !finished, !provider.current(ticket) else { return }
            if let alert = alert {
                alert.messageText = "Cancelling YubiKey request…"
                alert.informativeText = "The result will be discarded. The current USB request can take up to 25 seconds to finish."
                alert.buttons.forEach { $0.isEnabled = false }
            }
        }
        func startMonitoring() {
            cancellationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if !self.window.isVisible { provider.cancel() }
                self.cancellationState()
            }
        }
        func finish() {
            finished = true; cancellationTimer?.invalidate(); cancellationTimer = nil; dismiss()
        }
        // Called only by the serial hardware worker, never by the main thread.
        func beforeActivation(_ step: Int) -> Bool {
            let gate = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                guard !self.finished, provider.current(self.ticket) else { gate.signal(); return }
                self.dismiss()
                let total = self.enrolling ? 3 : 1
                let titles = ["Create this key's credential", "Protect the saved password", "Verify this key can unlock it"]
                let prompt = NSAlert()
                prompt.messageText = "Activation \(step) of \(total): \(self.enrolling ? titles[step - 1] : "Unlock with “\(self.name)”")"
                prompt.informativeText = (step > 1 ? "Activation \(step - 1) completed. " : "")
                    + "When you are ready, click Continue. Then touch the gold contact on your YubiKey once."
                prompt.addButton(withTitle: "Continue"); prompt.addButton(withTitle: "Cancel")
                self.alert = prompt
                prompt.beginSheetModal(for: self.window) { response in
                    guard response == .alertFirstButtonReturn, provider.current(self.ticket), !self.finished else {
                        if !self.finished && provider.current(self.ticket) { provider.cancel() }
                        gate.signal(); return
                    }
                    let waiting = NSAlert()
                    waiting.messageText = "Activation \(step) of \(total): Touch your YubiKey now"
                    waiting.informativeText = "Touch the gold contact once. The app will tell you when this activation has completed."
                    waiting.addButton(withTitle: "Cancel")
                    self.alert = waiting
                    waiting.beginSheetModal(for: self.window) { result in
                        if result == .alertFirstButtonReturn, !self.finished {
                            provider.cancel()
                            // Keep cancellation visible until the worker has returned.
                            let cancelling = NSAlert(); cancelling.messageText = "Cancelling YubiKey request…"
                            cancelling.informativeText = "The result will be discarded. Waiting for the current USB request to finish (up to 25 seconds)."
                            cancelling.addButton(withTitle: "Please wait").isEnabled = false
                            self.alert = cancelling
                            cancelling.beginSheetModal(for: self.window)
                        }
                    }
                    DispatchQueue.main.async { gate.signal() }
                }
            }
            while gate.wait(timeout: .now() + 0.2) == .timedOut {
                if !provider.current(ticket) { return false }
            }
            return provider.current(ticket)
        }
    }
    private static func perform(enrolling: Bool, from controller: NSViewController, completion: @escaping (String) -> Void,
                                manualFallback: (() -> Void)? = nil) {
        guard available(from: controller), let window = controller.view.window else { return }
        let entries: [FIDO2PasswordProvider.Enrollment]
        do { entries = try provider.enrollments() }
        catch { report(error, from: controller); return }
        guard enrolling || !entries.isEmpty else { report(FIDO2PasswordProvider.Failure("No YubiKey is enrolled. Use your original note password."), from: controller); return }
        busy = true
        let ticket = provider.ticket()
        let prompt = NSAlert(); prompt.messageText = enrolling ? "Add a YubiKey" : "Choose a YubiKey to unlock"
        prompt.informativeText = enrolling
            ? "Connect only the key you want to add. Give it a name, enter the note password it should unlock, and enter its FIDO2 PIN. The app will guide you through three activations, one at a time. Existing enrollments will be kept."
            : "Select an enrollment, connect only that key, and enter its FIDO2 PIN. You will be prompted before touching the key."
        let pin = field("FIDO2 PIN", secure: true), password = field("Existing note password", secure: true), name = field("Enrollment name (e.g. Everyday or Backup)")
        let selection = picker(entries)
        prompt.accessoryView = accessory(enrolling ? [name, password, pin] : [selection, pin])
        prompt.addButton(withTitle: "Continue"); prompt.addButton(withTitle: "Cancel")
        prompt.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, provider.current(ticket) else {
                pin.stringValue = ""; password.stringValue = ""; busy = false; return
            }
            var enteredPIN = pin.stringValue, enteredPassword = password.stringValue
            let enteredName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            pin.stringValue = ""; password.stringValue = ""
            guard !enteredPIN.isEmpty, enteredPIN.utf8.count <= 63, !enteredPIN.contains("\0"),
                  (!enrolling || (!enteredName.isEmpty && enteredName.count <= 80 && !enteredPassword.isEmpty && enteredPassword.utf8.count <= 4096)) else {
                busy = false
                report(FIDO2PasswordProvider.Failure("Enter a valid name, note password and FIDO2 PIN. Names may contain up to 80 characters."), from: controller); return
            }
            let entry = enrolling ? nil : entries[selection.indexOfSelectedItem]
            let session = ActivationSession(window: window, ticket: ticket, enrolling: enrolling, name: entry?.name ?? enteredName)
            session.startMonitoring()
            FIDO2PasswordProvider.worker.async {
                let result = Result<String, Error> {
                    if enrolling {
                        try provider.enroll(name: enteredName, password: enteredPassword, pin: enteredPIN, ticket: ticket, beforeActivation: session.beforeActivation)
                        return ""
                    }
                    return try provider.unlock(id: entry!.id, pin: enteredPIN, ticket: ticket, beforeActivation: { session.beforeActivation(1) })
                }
                enteredPIN = ""; enteredPassword = ""
                DispatchQueue.main.async {
                    session.finish(); busy = false
                    guard provider.current(ticket) else { return }
                    switch result {
                    case .success(let value):
                        if enrolling {
                            let done = NSAlert(); done.messageText = "“\(enteredName)” is ready"
                            done.informativeText = "All three activations completed. This enrollment was added; other enrollments were kept. Your original note password still works. To add a backup, connect a different physical YubiKey."
                            done.addButton(withTitle: "Done"); done.addButton(withTitle: "Add Another YubiKey…")
                            done.beginSheetModal(for: window) { result in
                                if result == .alertSecondButtonReturn { perform(enrolling: true, from: controller, completion: { _ in }) }
                            }
                        } else { completion(value) }
                    case .failure(let error):
                        let failure = NSAlert(); failure.messageText = enrolling ? "YubiKey was not added" : "YubiKey could not unlock this password"
                        failure.informativeText = error.localizedDescription + (enrolling ? " Existing enrollments were kept." : " Your original note password still works.")
                        failure.addButton(withTitle: "Close")
                        if !enrolling, manualFallback != nil { failure.addButton(withTitle: "Enter Note Password…") }
                        failure.beginSheetModal(for: window) { answer in
                            if answer == .alertSecondButtonReturn { manualFallback?() }
                        }
                    }
                }
            }
        }
    }
}
