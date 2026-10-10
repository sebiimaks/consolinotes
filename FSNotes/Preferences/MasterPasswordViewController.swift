//
//  MasterPasswordViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/20/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class MasterPasswordViewController: NSViewController {
    override func viewDidAppear() {
        hint.stringValue = UserDefaultsManagement.masterPasswordHint
    }

    @IBOutlet weak var hint: NSTextField!

    @IBOutlet weak var currentPassword: NSSecureTextField!

    @IBOutlet weak var newPassword: NSSecureTextField!

    @IBOutlet weak var repeatedPassword: NSSecureTextField!


    @IBAction func close(_ sender: Any) {
        dismiss(self)
    }

    @IBAction func change(_ sender: Any) {
        var password = String()

        do {
            password = try KeychainConfiguration.readMasterPassword()
        } catch KeychainPasswordItem.KeychainError.noPassword {
            // No stored convenience password yet.
        } catch {
            showKeychainFailure()
            return
        }
        
        if password.count > 0, currentPassword.stringValue != password {
            wrongCurrentPassword()
            return
        }

        if newPassword.stringValue != repeatedPassword.stringValue {
            wrongRepeatAlert()
            return
        }

        if newPassword.stringValue.count == 0 {
            emptyPassword()
            return
        }

        if password != newPassword.stringValue,
           Storage.shared().noteList.contains(where: { $0.isEncrypted() }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Update the saved unlock password?"
            alert.informativeText = "This changes only the password saved in Keychain. Existing encrypted notes keep their current passwords. Keep those passwords so you can still unlock the notes."
            alert.addButton(withTitle: "Update Saved Password")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let item = KeychainPasswordItem(service: KeychainConfiguration.serviceName, account: "Master Password")
        do {
            try item.savePassword(newPassword.stringValue)
        } catch {
            showKeychainFailure()
            return
        }

        UserDefaultsManagement.masterPasswordHint = hint.stringValue

        dismiss(self)
    }

    private func showKeychainFailure() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The saved password could not be accessed"
        alert.informativeText = "Keychain did not allow the operation. No password change has been completed."
        alert.runModal()
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

