//
//  MasterPasswordViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/20/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class MasterPasswordViewController: NSViewController {
    private var isSaving = false

    override func viewDidAppear() {
        super.viewDidAppear()
        title = "Saved Unlock Password"
        hint.stringValue = UserDefaultsManagement.masterPasswordHint
        currentPassword.placeholderString = "Blank for first secure save"
        currentPassword.toolTip = "Enter the current securely saved password when replacing it. Earlier versions' saved passwords are not read."
        hint.toolTip = "Hints are stored in plain text. Do not put a password or other sensitive information here."
    }

    @IBOutlet weak var hint: NSTextField!

    @IBOutlet weak var currentPassword: NSSecureTextField!

    @IBOutlet weak var newPassword: NSSecureTextField!

    @IBOutlet weak var repeatedPassword: NSSecureTextField!


    @IBAction func close(_ sender: Any) {
        guard !isSaving else { return }
        clearPasswordFields()
        dismiss(self)
    }

    @IBAction func change(_ sender: Any) {
        guard !isSaving else { return }

        if !newPassword.stringValue.utf8.elementsEqual(repeatedPassword.stringValue.utf8) {
            wrongRepeatAlert()
            return
        }

        if newPassword.stringValue.count == 0 {
            emptyPassword()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Save an unlock password on this Mac?"
        alert.informativeText = "macOS authentication will protect this device-only saved password. After verification, consolinotes removes its older saved copy. Existing encrypted notes keep their current passwords; keep those passwords so you can still open the notes. Any password hint is stored in plain text."
        alert.addButton(withTitle: "Save Password")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let password = newPassword.stringValue
        let current = currentPassword.stringValue
        let savedHint = hint.stringValue
        let button = sender as? NSButton
        isSaving = true
        button?.isEnabled = false
        // SecItem calls may display authentication UI and must not block the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try KeychainConfiguration.saveMasterPassword(password, currentPassword: current) }
            DispatchQueue.main.async {
                self.isSaving = false
                button?.isEnabled = true
                switch result {
                case .failure(KeychainPasswordItem.KeychainError.incorrectCurrentPassword):
                    self.wrongCurrentPassword()
                case .failure(let error):
                    if !KeychainConfiguration.isAuthenticationCancelled(error) { self.showKeychainFailure(error) }
                case .success(let saved):
                    if case .savedLegacyCleanupFailed = saved {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Saved securely; older copy remains"
                        alert.informativeText = "The protected password was saved and verified, but Keychain did not allow removal of consolinotes' older saved copy. You can retry saving or remove the old consolinotes / Master Password item in Keychain Access. The FSNotes application's item is unchanged."
                        alert.runModal()
                    }
                    UserDefaultsManagement.masterPasswordHint = savedHint
                    self.clearPasswordFields()
                    self.dismiss(self)
                }
            }
        }
    }

    private func showKeychainFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The protected password could not be verified"
        if KeychainConfiguration.isMissingEntitlement(error) {
            alert.informativeText = "This local build cannot use protected saved passwords. Enter each note's password manually. No unprotected replacement is saved, and encrypted note passwords are unchanged."
        } else {
            alert.informativeText = "macOS could not complete authenticated Keychain access. No unprotected replacement is saved, and encrypted note passwords are unchanged. You can still enter a note's password manually. If a save had already completed, the protected copy may remain."
        }
        alert.runModal()
    }

    private func clearPasswordFields() {
        currentPassword.stringValue = ""
        newPassword.stringValue = ""
        repeatedPassword.stringValue = ""
    }

    private func wrongRepeatAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.informativeText = NSLocalizedString("Please try again", comment: "")
        alert.messageText = NSLocalizedString("Wrong repeated password", comment: "")
        alert.runModal()
    }

    private func wrongCurrentPassword() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.informativeText = NSLocalizedString("Please try again", comment: "")
        alert.messageText = NSLocalizedString("Current password does not match with password in keychain", comment: "")
        alert.runModal()
    }

    private func emptyPassword() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.informativeText = NSLocalizedString("Please try again", comment: "")
        alert.messageText = NSLocalizedString("Empty password", comment: "")
        alert.runModal()
    }

}

