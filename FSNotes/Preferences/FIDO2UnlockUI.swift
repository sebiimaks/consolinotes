import Cocoa

/// Named enrollments and one explicit, user-paced prompt per hardware activation.
enum FIDO2UnlockUI {
    private static var busy = false
    private static let provider = FIDO2PasswordProvider.shared
    private static var cancelRequestUI: (() -> Void)?
    private static var requestWindowObserver: NSObjectProtocol?
    private static var managementAlert: NSAlert?

    /// Locking and window closure dismiss PIN/password fields immediately. A
    /// hardware request already in progress remains busy until its worker exits.
    static func cancelPendingRequests() {
        provider.cancel()
        let dismiss = cancelRequestUI
        cancelRequestUI = nil
        dismiss?()
        if let alert = managementAlert {
            managementAlert = nil
            func clearFields(_ view: NSView) {
                if let field = view as? NSTextField { field.currentEditor()?.string = ""; field.stringValue = "" }
                if let picker = view as? NSPopUpButton { picker.removeAllItems() }
                for child in view.subviews { clearFields(child) }
            }
            if let accessory = alert.accessoryView { clearFields(accessory) }
            alert.accessoryView = nil
            alert.messageText = ""; alert.informativeText = ""
            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            alert.window.orderOut(nil)
        }
        clearWindowObserver()
    }

    private static func clearWindowObserver() {
        if let observer = requestWindowObserver { NotificationCenter.default.removeObserver(observer) }
        requestWindowObserver = nil
    }

    @discardableResult
    private static func runManagementAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        managementAlert = alert
        defer { if managementAlert === alert { managementAlert = nil } }
        return alert.runModal()
    }

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
    private final class ActionButton: NSButton {
        private let invoke: () -> Void
        init(_ title: String, enabled: Bool = true, invoke: @escaping () -> Void) {
            self.invoke = invoke
            super.init(frame: .zero)
            self.title = title; bezelStyle = .rounded; isEnabled = enabled
            target = self; action = #selector(pressed)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func pressed() { invoke() }
    }
    private final class EnrollmentInput {
        private let lock = NSLock()
        private var secret: String
        var password: String { lock.lock(); defer { lock.unlock() }; return secret }
        let proof: FIDO2PasswordProvider.PasswordProof
        init(password: String, proof: FIDO2PasswordProvider.PasswordProof) { self.secret = password; self.proof = proof }
        func clear() { lock.lock(); secret = ""; lock.unlock() }
        deinit { clear() }
    }
    private static func selectedNote(from controller: NSViewController, unlocked: Bool = false) -> Note? {
        let notes = ViewController.shared()?.notesTableView.getSelectedNotes() ?? []
        guard notes.count == 1, let note = notes.first, note.isEncrypted(),
              !unlocked || (!note.isEncryptedAndLocked() && note.isUnlocked()) else {
            report(FIDO2PasswordProvider.Failure(unlocked
                ? "Select one encrypted note and unlock it first. Only that note will be changed."
                : "Select one encrypted note in the main window first. Enrollment will verify its password before contacting the YubiKey."), from: controller)
            return nil
        }
        return note
    }
    static func settings(from controller: NSViewController) {
        guard available(from: controller) else { return }
        var managementTicket = provider.ticket()
        while provider.current(managementTicket) {
            let entries: [FIDO2PasswordProvider.Enrollment]
            do { entries = try provider.enrollments() }
            catch { report(error, from: controller); return }
            let alert = NSAlert()
            alert.messageText = "YubiKey enrollments"
            alert.informativeText = entries.isEmpty
                ? "Select an encrypted note, then add a YubiKey. Its password will be verified before enrollment. Your note password remains a recovery method."
                : "Test an enrollment against the selected encrypted note, or add a backup for the same password. Export the encrypted enrollment collection for recovery after losing this Mac; a spare key alone is not enough."
            let selection = picker(entries)
            func action(_ title: String, code: Int, enabled: Bool = true) -> NSButton {
                ActionButton(title, enabled: enabled) { [weak alert] in
                    NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: code)); alert?.window.orderOut(nil)
                }
            }
            let tests = NSStackView(views: [action("Test Enrollment…", code: 1101, enabled: !entries.isEmpty), action("Add Backup Key…", code: 1102, enabled: !entries.isEmpty)])
            let backups = NSStackView(views: [action("Export Enrollments…", code: 1103, enabled: !entries.isEmpty), action("Import Enrollments…", code: 1104)])
            alert.accessoryView = accessory((entries.isEmpty ? [] : [selection]) + [tests, backups])
            alert.addButton(withTitle: "Add YubiKey…")
            alert.addButton(withTitle: "Rename…").isEnabled = !entries.isEmpty
            alert.addButton(withTitle: "Remove…").isEnabled = !entries.isEmpty
            alert.addButton(withTitle: "Done")
            let response = runManagementAlert(alert)
            guard provider.current(managementTicket) else { return }
            if response == .alertFirstButtonReturn { perform(enrolling: true, from: controller, completion: { _ in }); return }
            if response.rawValue == 1103 { exportEnrollments(from: controller); return }
            if response.rawValue == 1104 { importEnrollments(from: controller); return }
            guard entries.indices.contains(selection.indexOfSelectedItem) else { return }
            let entry = entries[selection.indexOfSelectedItem]
            if response.rawValue == 1101 { testEnrollment(entry, from: controller); return }
            if response.rawValue == 1102 { addBackup(entry, from: controller); return }
            if response == .alertSecondButtonReturn {
                let rename = NSAlert(); rename.messageText = "Rename enrollment"
                rename.informativeText = "Choose a name that helps you identify this key, such as Everyday or Backup."
                let name = field("Enrollment name"); name.stringValue = entry.name
                rename.accessoryView = accessory([name])
                rename.addButton(withTitle: "Rename"); rename.addButton(withTitle: "Cancel")
                if runManagementAlert(rename) == .alertFirstButtonReturn, provider.current(managementTicket) {
                    do { try provider.rename(id: entry.id, name: name.stringValue) }
                    catch { report(error, from: controller) }
                }
            } else if response == .alertThirdButtonReturn {
                let remove = NSAlert(); remove.messageText = "Remove “\(entry.name)”?"
                remove.informativeText = "Only this local enrollment will be removed. This does not revoke exported copies or change any note secret. If a key was lost, use Rotate Note Secret for each affected note before removing its old enrollments. Your other keys and manual recovery password are kept."
                remove.addButton(withTitle: "Remove Enrollment"); remove.addButton(withTitle: "Cancel")
                if runManagementAlert(remove) == .alertFirstButtonReturn, provider.current(managementTicket) {
                    do { try provider.remove(id: entry.id); managementTicket = provider.ticket() }
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

    private static func testEnrollment(_ entry: FIDO2PasswordProvider.Enrollment, from controller: NSViewController) {
        guard let note = selectedNote(from: controller) else { return }
        perform(enrolling: false, from: controller, completion: { password in
            let ticket = provider.ticket()
            busy = true
            FIDO2PasswordProvider.worker.async {
                let verified = provider.current(ticket) && note.verifyEncryptionPassword(password)
                DispatchQueue.main.async {
                    busy = false
                    guard provider.current(ticket) else { return }
                    let alert = NSAlert()
                    alert.messageText = verified ? "Enrollment verified" : "This enrollment does not unlock the selected note"
                    alert.informativeText = verified
                        ? "The selected YubiKey recovered a password that authenticated this note. No note content was opened or changed. Repeat this test with each physical backup key and keep an exported enrollment collection."
                        : "The hardware activation succeeded, but its saved password did not authenticate this note. Choose the intended note or enroll its correct password. Nothing was changed."
                    runManagementAlert(alert)
                }
            }
        }, selectedID: entry.id)
    }

    private static func addBackup(_ entry: FIDO2PasswordProvider.Enrollment, from controller: NSViewController) {
        guard let note = selectedNote(from: controller) else { return }
        perform(enrolling: false, from: controller, completion: { password in
            let ticket = provider.ticket()
            busy = true
            FIDO2PasswordProvider.worker.async {
                let verified = Result { try FIDO2PasswordProvider.verifyBackupPassword(password, of: entry, using: note.verifyEncryptionPassword) }
                DispatchQueue.main.async {
                    busy = false
                    guard provider.current(ticket) else { return }
                    switch verified {
                    case .failure(let error): report(error, from: controller)
                    case .success(let proof):
                        let prompt = NSAlert()
                        prompt.messageText = "Connect your backup YubiKey"
                        prompt.informativeText = "The existing key and selected note's password were verified. Unplug that key and connect a different physical YubiKey. The new enrollment will protect the same password. The app cannot determine whether two credentials are on different physical keys; choose your spare deliberately."
                        prompt.addButton(withTitle: "Backup Key Connected"); prompt.addButton(withTitle: "Cancel")
                        guard runManagementAlert(prompt) == .alertFirstButtonReturn, provider.current(ticket) else { return }
                        perform(enrolling: true, from: controller, completion: { _ in }, source: EnrollmentInput(password: password, proof: proof))
                    }
                }
            }
        }, selectedID: entry.id)
    }

    private static func exportEnrollments(from controller: NSViewController) {
        guard let window = controller.view.window else { return }
        let ticket = provider.ticket()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "consolinotes-yubikey-enrollments.json"
        panel.message = "This backup contains encrypted password envelopes and key names. It needs the matching physical key and PIN to unlock. It contains no plaintext note passwords. Keep a copy separate from this Mac."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, provider.current(ticket) else { return }
            do { try provider.exportFile(url, ticket: ticket) }
            catch { report(error, from: controller) }
        }
    }

    private static func importEnrollments(from controller: NSViewController) {
        guard let window = controller.view.window else { return }
        let ticket = provider.ticket()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Import an exported enrollment collection. Existing enrollments are kept; conflicting records are rejected. Test every imported key against its intended encrypted note."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, provider.current(ticket) else { return }
            do {
                let result = try provider.importFile(url, ticket: ticket)
                let done = NSAlert()
                done.messageText = "Enrollment import completed"
                done.informativeText = "Added \(result.added) enrollment(s); kept \(result.alreadyPresent) already present. No existing password envelope was replaced. Select an encrypted note and use Test Enrollment with each physical key before relying on this backup."
                runManagementAlert(done)
            } catch { report(error, from: controller) }
        }
    }

    /// Strong mode deliberately changes only the selected, authenticated note.
    /// A typed-back random recovery password qualifies independently of hardware.
    static func protectSelectedNote(from controller: NSViewController, rotating: Bool = false) {
        guard available(from: controller), let note = selectedNote(from: controller, unlocked: true) else { return }
        let ticket = provider.ticket()
        let confirm = NSAlert()
        confirm.messageText = rotating ? "Rotate the selected note's secret?" : "Protect this note with YubiKey and recovery?"
        confirm.informativeText = "The selected note will get a new random encryption secret. You must first save and verify an offline recovery password, then enroll a YubiKey. The current note is changed only after both checks succeed. Its old password and old key enrollments will no longer unlock the new ciphertext. Earlier backups and exported copies still use their old secret; removing an enrollment does not revoke those copies."
        confirm.addButton(withTitle: "Set Up Recovery"); confirm.addButton(withTitle: "Cancel")
        guard runManagementAlert(confirm) == .alertFirstButtonReturn, provider.current(ticket) else { return }
        let plan: FIDO2PasswordProvider.StrongProtectionPlan
        do { plan = try .init() } catch { report(error, from: controller); return }
        let recovery = NSAlert()
        recovery.messageText = "Save this recovery password offline"
        recovery.informativeText = "Write down the complete password, including CN1 and every hyphen. Store it away from this Mac. It can unlock this note without the YubiKey. The app will hide it before asking you to re-enter your saved copy."
        let value = NSTextField(wrappingLabelWithString: plan.recoverySecret)
        value.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        value.widthAnchor.constraint(equalToConstant: 360).isActive = true
        value.preferredMaxLayoutWidth = 360
        value.isSelectable = false
        recovery.accessoryView = accessory([value])
        recovery.addButton(withTitle: "I Saved It Offline"); recovery.addButton(withTitle: "Cancel")
        recovery.addButton(withTitle: "Copy Temporarily")
        var response = runManagementAlert(recovery)
        while response == .alertThirdButtonReturn && provider.current(ticket) {
            SensitiveClipboard.writeString(plan.recoverySecret)
            response = runManagementAlert(recovery)
        }
        value.stringValue = ""; recovery.accessoryView = nil
        guard response == .alertFirstButtonReturn, provider.current(ticket) else { plan.clear(); return }
        let verify = NSAlert()
        verify.messageText = "Verify your saved recovery password"
        verify.informativeText = "Enter the recovery password from the copy you saved. Nothing has been changed yet."
        let entered = field("Recovery password", secure: true)
        verify.accessoryView = accessory([entered])
        verify.addButton(withTitle: "Verify Recovery"); verify.addButton(withTitle: "Cancel")
        guard runManagementAlert(verify) == .alertFirstButtonReturn, provider.current(ticket) else {
            entered.stringValue = ""; plan.clear(); return
        }
        let proof: FIDO2PasswordProvider.PasswordProof
        do { proof = try plan.verifyRecovery(entered.stringValue) }
        catch { entered.stringValue = ""; plan.clear(); report(error, from: controller); return }
        entered.stringValue = ""; verify.accessoryView = nil
        perform(enrolling: true, from: controller, completion: { _ in },
                source: EnrollmentInput(password: plan.recoverySecret, proof: proof), enrolled: { record in
            guard record != nil, provider.current(ticket), !plan.recoverySecret.isEmpty else { plan.clear(); return }
            busy = true
            cancelRequestUI = { plan.clear() }
            if let window = controller.view.window {
                requestWindowObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in cancelPendingRequests() }
            }
            // Note serialization reads mutable editor state and must stay on the
            // main thread. Storage checks cancellation again before publication.
            let secret = plan.recoverySecret
            let changed = !secret.isEmpty && provider.current(ticket)
                && note.rotateEncryptionSecret(to: secret, isCancelled: { !provider.current(ticket) })
            plan.clear()
            busy = false; cancelRequestUI = nil; clearWindowObserver()
            guard provider.current(ticket) else { return }
            let done = NSAlert()
            done.messageText = changed ? "Note protection updated" : "The note secret was not changed"
            done.informativeText = changed
                ? "This note now uses the verified random secret. Unlock it with the new YubiKey enrollment or your offline recovery password. Test the key against this note, add a backup key, and export the updated enrollment collection. Old enrollments do not unlock this note's new ciphertext."
                : "The existing note and its current secret were kept. The newly created key enrollment remains separate and does not unlock that existing ciphertext. Check the note's save status before trying again."
            if changed, let warning = note.lastWriteError { done.informativeText += "\n\n" + warning }
            runManagementAlert(done)
            if changed {
                ViewController.shared()?.notesTableView.reloadData()
            }
        })
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
                                manualFallback: (() -> Void)? = nil, selectedID: String? = nil,
                                source: EnrollmentInput? = nil, enrolled: ((FIDO2PasswordProvider.Enrollment?) -> Void)? = nil) {
        guard available(from: controller), let window = controller.view.window else { return }
        let note = enrolling && source == nil ? selectedNote(from: controller) : nil
        if enrolling && source == nil && note == nil { return }
        let entries: [FIDO2PasswordProvider.Enrollment]
        do { entries = try provider.enrollments() }
        catch { report(error, from: controller); return }
        guard enrolling || !entries.isEmpty else { report(FIDO2PasswordProvider.Failure("No YubiKey is enrolled. Enter your note password or offline recovery password."), from: controller); return }
        if let selectedID = selectedID, !entries.contains(where: { $0.id == selectedID }) {
            report(FIDO2PasswordProvider.Failure("This enrollment is no longer available. Select it again from YubiKey settings."), from: controller)
            return
        }
        busy = true
        clearWindowObserver()
        requestWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in cancelPendingRequests() }
        let ticket = provider.ticket()
        let prompt = NSAlert(); prompt.messageText = enrolling ? "Add a YubiKey" : "Choose a YubiKey to unlock"
        prompt.informativeText = enrolling
            ? (source == nil
                ? "Connect only the key you want to add. Enter a name, the selected note's password and the key's FIDO2 PIN. The password is checked before the three guided activations. Existing enrollments are kept."
                : "Connect only the key you want to add. Enter a name and its FIDO2 PIN. The already verified note secret will be protected by this key, with three guided activations. Existing enrollments are kept.")
            : "Select an enrollment, connect only that key, and enter its FIDO2 PIN. You will be prompted before touching the key."
        let pin = field("FIDO2 PIN", secure: true), password = field("Existing note password", secure: true), name = field("Enrollment name (e.g. Everyday or Backup)")
        let selection = picker(entries)
        if let selectedID = selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) { selection.selectItem(at: index); selection.isEnabled = false }
        prompt.accessoryView = accessory(enrolling ? (source == nil ? [name, password, pin] : [name, pin]) : [selection, pin])
        prompt.addButton(withTitle: "Continue"); prompt.addButton(withTitle: "Cancel")
        cancelRequestUI = {
            pin.currentEditor()?.string = ""; pin.stringValue = ""
            password.currentEditor()?.string = ""; password.stringValue = ""
            source?.clear(); enrolled?(nil)
            if prompt.window.sheetParent != nil { window.endSheet(prompt.window, returnCode: .abort) }
            prompt.window.orderOut(nil)
        }
        prompt.beginSheetModal(for: window) { response in
            cancelRequestUI = nil
            guard response == .alertFirstButtonReturn, provider.current(ticket) else {
                pin.stringValue = ""; password.stringValue = ""; source?.clear(); enrolled?(nil); busy = false; clearWindowObserver(); return
            }
            var enteredPIN = pin.stringValue, enteredPassword = source?.password ?? password.stringValue
            let enteredName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            pin.stringValue = ""; password.stringValue = ""
            guard !enteredPIN.isEmpty, enteredPIN.utf8.count <= 63, !enteredPIN.contains("\0"),
                  (!enrolling || (!enteredName.isEmpty && enteredName.count <= 80 && !enteredPassword.isEmpty && enteredPassword.utf8.count <= 4096)) else {
                busy = false; clearWindowObserver()
                source?.clear(); enrolled?(nil)
                report(FIDO2PasswordProvider.Failure("Enter a valid name, note password and FIDO2 PIN. Names may contain up to 80 characters."), from: controller); return
            }
            let entry = enrolling ? nil : entries[selection.indexOfSelectedItem]
            let session = ActivationSession(window: window, ticket: ticket, enrolling: enrolling, name: entry?.name ?? enteredName)
            cancelRequestUI = { session.dismiss(); source?.clear(); enrolled?(nil) }
            session.startMonitoring()
            FIDO2PasswordProvider.worker.async {
                let result = Result<(String, FIDO2PasswordProvider.Enrollment?), Error> {
                    if enrolling {
                        let proof: FIDO2PasswordProvider.PasswordProof
                        if let source = source { proof = source.proof }
                        else if let note = note { proof = try FIDO2PasswordProvider.verifyPassword(enteredPassword, using: note.verifyEncryptionPassword) }
                        else { throw FIDO2PasswordProvider.Failure("Select the encrypted note again.") }
                        let record = try provider.enroll(name: enteredName, password: enteredPassword, proof: proof, pin: enteredPIN, ticket: ticket, beforeActivation: session.beforeActivation)
                        return ("", record)
                    }
                    return (try provider.unlock(id: entry!.id, pin: enteredPIN, ticket: ticket, beforeActivation: { session.beforeActivation(1) }), nil)
                }
                enteredPIN = ""; enteredPassword = ""; source?.clear()
                DispatchQueue.main.async {
                    session.finish(); busy = false; cancelRequestUI = nil; clearWindowObserver()
                    guard provider.current(ticket) else { enrolled?(nil); return }
                    switch result {
                    case .success(let value):
                        if enrolling {
                            if let enrolled = enrolled { enrolled(value.1); return }
                            let done = NSAlert(); done.messageText = "“\(enteredName)” is ready"
                            done.informativeText = "The selected note's password and all three hardware activations were verified. Other enrollments were kept. Your manual password still works. Use Add Backup Key to protect the same password with another physical key, and export your enrollments for recovery after losing this Mac."
                            done.addButton(withTitle: "Done"); done.addButton(withTitle: "Add Another YubiKey…")
                            done.beginSheetModal(for: window) { result in
                                if result == .alertSecondButtonReturn { perform(enrolling: true, from: controller, completion: { _ in }) }
                            }
                        } else { completion(value.0) }
                    case .failure(let error):
                        enrolled?(nil)
                        let failure = NSAlert(); failure.messageText = enrolling ? "YubiKey was not added" : "YubiKey could not unlock this password"
                        failure.informativeText = error.localizedDescription + (enrolling ? " Existing enrollments were kept." : " You can enter this note's password or offline recovery password instead.")
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
