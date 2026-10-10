// Optional PIV-backed saved passwords. Enrolling never changes note files or the key.
import Cocoa

final class PIVUnlockViewController: NSViewController, NSWindowDelegate {
    private let provider = PIVPasswordProvider.shared
    private var identities = [PIVPasswordProvider.Identity]()
    private var isBusy = false
    private var hasSavedPassword = false

    private let savedIdentity = NSTextField(wrappingLabelWithString: "No password is enrolled.")
    private let identityPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let password = NSSecureTextField()
    private let repeatedPassword = NSSecureTextField()
    private let policyConfirmation = NSButton(checkboxWithTitle: "This is my dedicated identity, with PIN and touch policies configured.", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save Password", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Saved Password…", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 540))
        preferredContentSize = view.frame.size
        title = "Unlock with YubiKey"

        let heading = NSTextField(labelWithString: "Unlock with YubiKey")
        heading.font = .boldSystemFont(ofSize: 17)
        let introduction = label("Save an existing note password encrypted for your PIV key. Your original password still works. New encryption and folder protection continue to use manual or Keychain passwords.")
        savedIdentity.font = .systemFont(ofSize: 12)
        savedIdentity.maximumNumberOfLines = 3
        savedIdentity.setAccessibilityIdentifier("piv.saved-identity")

        identityPicker.setAccessibilityLabel("PIV encryption identity")
        identityPicker.setAccessibilityIdentifier("piv.identity")
        identityPicker.target = self
        identityPicker.action = #selector(identityChanged)
        refreshButton.target = self
        refreshButton.action = #selector(refreshIdentities)
        refreshButton.setAccessibilityIdentifier("piv.refresh")
        let identityRow = NSStackView(views: [identityPicker, refreshButton])
        identityRow.orientation = .horizontal
        identityRow.spacing = 8
        identityPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        identityPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

        let setup = label("Requires a configured PIV encryption identity and a provisioned app signature. First use Yubico tools to prepare a dedicated RSA 2048-bit or stronger identity with a certificate and PIN/touch policies. Insert the key, then Refresh. This app does not provision, reset or overwrite keys.")
        setup.textColor = .secondaryLabelColor

        password.placeholderString = "Existing note password"
        password.setAccessibilityLabel("Existing note password")
        password.setAccessibilityIdentifier("piv.password")
        repeatedPassword.placeholderString = "Repeat existing note password"
        repeatedPassword.setAccessibilityLabel("Repeat existing note password")
        repeatedPassword.setAccessibilityIdentifier("piv.repeat-password")
        let passwordGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Password:"), password],
            [NSTextField(labelWithString: "Repeat:"), repeatedPassword]
        ])
        passwordGrid.column(at: 0).xPlacement = .trailing
        passwordGrid.column(at: 1).xPlacement = .fill
        passwordGrid.rowSpacing = 8
        passwordGrid.columnSpacing = 10
        password.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

        policyConfirmation.font = .systemFont(ofSize: 12)
        policyConfirmation.target = self
        policyConfirmation.action = #selector(updateControls)
        policyConfirmation.setAccessibilityIdentifier("piv.policy-confirmation")
        let policy = label("macOS prompts for the PIN and the key requests a touch according to its configured policy. This app cannot infer or change that policy; macOS may cache PIN authorization.")
        policy.textColor = .secondaryLabelColor

        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityIdentifier("piv.status")
        saveButton.target = self
        saveButton.action = #selector(savePassword)
        saveButton.setAccessibilityIdentifier("piv.save")
        removeButton.target = self
        removeButton.action = #selector(removePassword)
        removeButton.setAccessibilityIdentifier("piv.remove")
        doneButton.target = self
        doneButton.action = #selector(closeSheet)
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityIdentifier("piv.done")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [removeButton, spacer, saveButton, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let footerSpacing = NSView()
        footerSpacing.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        let content = NSStackView(views: [heading, introduction, savedIdentity, identityRow, setup, passwordGrid, policyConfirmation, policy, status, footerSpacing, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22)
        ])
        for item in [introduction, savedIdentity, identityRow, setup, passwordGrid, policyConfirmation, policy, status, footerSpacing, buttons] {
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        for text in [introduction, savedIdentity, setup, policy, status] {
            text.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        updateControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
        refreshIdentities()
    }

    override func viewDidDisappear() {
        clearPasswordFields()
        super.viewDidDisappear()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isBusy else { return false }
        clearPasswordFields()
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        closeSheet()
    }

    @objc private func closeSheet() {
        guard !isBusy else { return }
        clearPasswordFields()
        dismiss(self)
    }

    @objc private func refreshIdentities() {
        guard !isBusy else { return }
        setBusy(true, message: "Looking for compatible PIV identities…")
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = Result { try self.provider.enrollment() }
            let available = Result { try self.provider.identities() }
            DispatchQueue.main.async {
                self.identityPicker.removeAllItems()
                self.identities = (try? available.get()) ?? []
                for identity in self.identities {
                    self.identityPicker.addItem(withTitle: "\(identity.displayName) — \(identity.fingerprint.prefix(16))")
                }
                if self.identities.isEmpty { self.identityPicker.addItem(withTitle: "No compatible PIV identity found") }
                switch saved {
                case .success(let enrollment):
                    self.hasSavedPassword = enrollment != nil
                    if let enrollment = enrollment {
                        self.savedIdentity.stringValue = "Saved for \(enrollment.displayName)\nCertificate SHA-256: \(enrollment.fingerprint.prefix(16))… (available when this key is inserted)"
                    } else {
                        self.savedIdentity.stringValue = "No password is enrolled. A saved password is kept only as ciphertext on this Mac."
                    }
                case .failure(let error):
                    self.hasSavedPassword = true
                    self.savedIdentity.stringValue = "Saved password could not be read. \(error.localizedDescription)"
                }
                self.policyConfirmation.state = .off
                let message: String
                switch available {
                case .success:
                    message = self.identities.isEmpty ? "Insert a PIV-capable key with a configured encryption identity. The FIDO-only Security Key series cannot be used here." : "Select the dedicated identity and enter the password you already use for your notes."
                case .failure(let error):
                    message = error.localizedDescription
                }
                self.setBusy(false, message: message)
            }
        }
    }

    @objc private func identityChanged() {
        policyConfirmation.state = .off
        updateControls()
    }

    @objc private func updateControls() {
        identityPicker.isEnabled = !isBusy && !identities.isEmpty
        refreshButton.isEnabled = !isBusy
        password.isEnabled = !isBusy
        repeatedPassword.isEnabled = !isBusy
        policyConfirmation.isEnabled = !isBusy && !identities.isEmpty
        saveButton.isEnabled = !isBusy && !identities.isEmpty && policyConfirmation.state == .on
        removeButton.isEnabled = !isBusy && hasSavedPassword
        doneButton.isEnabled = !isBusy
        view.window?.standardWindowButton(.closeButton)?.isEnabled = !isBusy
    }

    @objc private func savePassword() {
        guard !isBusy, policyConfirmation.state == .on,
              identities.indices.contains(identityPicker.indexOfSelectedItem) else { return }
        guard !password.stringValue.isEmpty, password.stringValue.utf8.count <= 4096 else {
            status.stringValue = "Enter the existing note password (1–4096 UTF-8 bytes)."
            return
        }
        guard password.stringValue.utf8.elementsEqual(repeatedPassword.stringValue.utf8) else {
            status.stringValue = "The repeated password does not match. Enter the same password in both fields."
            return
        }
        if hasSavedPassword {
            let confirmation = NSAlert()
            confirmation.messageText = "Replace the saved YubiKey password?"
            confirmation.informativeText = "After the new key decrypts and verifies the password, its encrypted copy replaces the previous saved copy. Keep your original note passwords; note files and key credentials are unchanged."
            confirmation.addButton(withTitle: "Replace")
            confirmation.addButton(withTitle: "Cancel")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        }
        let secret = password.stringValue
        let identity = identities[identityPicker.indexOfSelectedItem]
        clearPasswordFields()
        setBusy(true, message: "Keep the key inserted. Follow the macOS PIN prompt and touch the key if requested. Verifying hardware decryption…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.provider.enroll(password: secret, identity: identity) }
            DispatchQueue.main.async {
                self.clearPasswordFields()
                switch result {
                case .success:
                    self.hasSavedPassword = true
                    self.savedIdentity.stringValue = "Saved for \(identity.displayName)\nCertificate SHA-256: \(identity.fingerprint.prefix(16))…"
                    self.setBusy(false, message: "Password encrypted and verified with the key. Choose Use YubiKey when opening an encrypted note. Keep your original password as a fallback.")
                case .failure(let error):
                    self.setBusy(false, message: PIVPasswordProvider.isCancellation(error) ? "Canceled. You can still enter your note password manually." : error.localizedDescription)
                }
            }
        }
    }

    @objc private func removePassword() {
        guard !isBusy, hasSavedPassword else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "Remove the saved YubiKey password?"
        confirmation.informativeText = "This removes only this app's encrypted saved password. It does not change any note file or credential on your key. You can still enter your original note password manually."
        confirmation.addButton(withTitle: "Remove Saved Password")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        clearPasswordFields()
        setBusy(true, message: "Removing the encrypted saved password…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.provider.removeEnrollment() }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.hasSavedPassword = false
                    self.savedIdentity.stringValue = "No password is enrolled."
                    self.setBusy(false, message: "Saved ciphertext removed. Your note files and key are unchanged.")
                case .failure(let error):
                    self.setBusy(false, message: error.localizedDescription)
                }
            }
        }
    }

    private func setBusy(_ busy: Bool, message: String) {
        isBusy = busy
        status.stringValue = message
        updateControls()
    }

    private func clearPasswordFields() {
        password.stringValue = ""
        repeatedPassword.stringValue = ""
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        return field
    }
}
