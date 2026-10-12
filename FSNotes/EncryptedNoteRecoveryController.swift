// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import AppKit
import UniformTypeIdentifiers

/// Interrupted files are never discarded automatically. Recovery creates a new
/// encrypted copy, so restoring older edits cannot overwrite the current note.
enum EncryptedNoteRecoveryController {
    private static var presented = false
    private static weak var activeAlert: NSAlert?
    private static weak var activePanel: NSSavePanel?
    private static var passwordFields = [NSSecureTextField]()
    private static var cancelled = false

    static func cancel() {
        cancelled = true
        passwordFields.forEach { $0.currentEditor()?.string = ""; $0.stringValue = "" }
        activePanel?.cancel(nil)
        if let alert = activeAlert { NSApp.abortModal(); alert.window.orderOut(nil) }
    }

    static func presentIfNeeded() {
        guard !presented else { return }
        presented = true
        presentRecovery()
    }

    static func presentRecovery() {
        cancelled = false
        recoverEncryptedJournals()
        guard !cancelled else { return }
        let entries = EncryptedNoteRecovery.interrupted()
        for entry in entries {
            guard !cancelled else { return }
            let alert = NSAlert()
            alert.messageText = "Interrupted encrypted-note session"
            let date = DateFormatter.localizedString(from: entry.created, dateStyle: .medium, timeStyle: .short)
            alert.informativeText = "A private working copy from \(date) remains on this Mac and may contain unsaved edits. It is plaintext. Restore it as a separate encrypted note, discard it, or keep it for later. Your existing notes will not be replaced."
            alert.addButton(withTitle: entry.bundle == nil ? "Save Recovery Files…" : "Restore Encrypted Copy…")
            alert.addButton(withTitle: "Discard…")
            alert.addButton(withTitle: "Later")
            activeAlert = alert
            let response = run(alert)
            activeAlert = nil
            guard !cancelled else { return }
            if response == .alertFirstButtonReturn {
                do {
                    if entry.bundle != nil {
                        let panel = NSSavePanel()
                        panel.title = "Restore Encrypted Note"
                        panel.nameFieldStringValue = "Recovered note.etp"
                        panel.allowedContentTypes = [UTType(filenameExtension: "etp") ?? .data]
                        guard run(panel) == .OK, let destination = panel.url, !cancelled else { return }
                        guard let password = requestPassword(), !cancelled else { return }
                        try EncryptedNoteRecovery.restore(entry, password: password, to: destination)
                    } else {
                        let explanation = NSAlert()
                        explanation.messageText = "Save incomplete recovery files"
                        explanation.informativeText = "This interrupted copy is incomplete. Save its files to a private folder for manual recovery. These files remain plaintext."
                        explanation.addButton(withTitle: "Choose Folder…")
                        explanation.addButton(withTitle: "Cancel")
                        guard run(explanation) == .alertFirstButtonReturn else { return }
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        guard run(panel) == .OK, let destination = panel.url, !cancelled else { return }
                        let copy = destination.appendingPathComponent("Recovered files " + UUID().uuidString + ".noindex", isDirectory: true)
                        try PrivateWorkingDirectory.protectTree(entry.directory)
                        try FileManager.default.copyItem(at: entry.directory, to: copy)
                        try PrivateWorkingDirectory.protectTree(copy)
                        try PrivateWorkingDirectory.excludeFromBackup(copy)
                    }
                    try EncryptedNoteRecovery.remove(entry.directory)
                } catch {
                    let failure = NSAlert()
                    failure.alertStyle = .warning
                    failure.messageText = "Recovery is incomplete"
                    failure.informativeText = "The working files have been kept wherever cleanup has not completed. Check the chosen location and available space, then use File > Recover Interrupted Notes to try again."
                    _ = run(failure)
                }
            } else if response == .alertSecondButtonReturn {
                let confirmation = NSAlert()
                confirmation.alertStyle = .warning
                confirmation.messageText = "Discard this working copy?"
                confirmation.informativeText = "Any edits that were not saved to the encrypted note will be lost. Existing encrypted notes will not be changed."
                confirmation.addButton(withTitle: "Keep")
                confirmation.addButton(withTitle: "Discard Working Copy")
                activeAlert = confirmation
                let discard = run(confirmation) == .alertSecondButtonReturn
                activeAlert = nil
                if discard && !cancelled {
                    do { try EncryptedNoteRecovery.remove(entry.directory) }
                    catch {
                        let failure = NSAlert()
                        failure.messageText = "Some working files could not be removed"
                        failure.informativeText = "Use File > Recover Interrupted Notes to retry cleanup."
                        _ = run(failure)
                    }
                }
            } else { return }
        }
    }

    private static func recoverEncryptedJournals() {
        for entry in EncryptedNoteJournal.interrupted() {
            guard !cancelled else { return }
            let alert = NSAlert()
            alert.messageText = "Encrypted recovery snapshot"
            alert.informativeText = "An interrupted save left an encrypted snapshot from \(DateFormatter.localizedString(from: entry.created, dateStyle: .medium, timeStyle: .short)). Restore it as a separate note using the password or offline recovery secret used at that time. Your current note will not be replaced."
            alert.addButton(withTitle: "Restore…")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Discard…")
            let response = run(alert)
            if response == .alertFirstButtonReturn {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Recovered note.etp"
                panel.allowedContentTypes = [UTType(filenameExtension: "etp") ?? .data]
                guard run(panel) == .OK, let destination = panel.url, !cancelled else { return }
                guard let password = requestPassword(existing: true), !cancelled else { return }
                do {
                    try EncryptedNoteJournal.restore(entry, password: password, to: destination)
                    try EncryptedNoteJournal.discard(entry)
                } catch {
                    let failure = NSAlert()
                    failure.messageText = "The snapshot could not be restored"
                    failure.informativeText = "Check the original password or recovery secret, choose a new filename, and check available space. The encrypted snapshot has been kept."
                    _ = run(failure)
                }
            } else if response == .alertThirdButtonReturn {
                let confirmation = NSAlert()
                confirmation.messageText = "Discard the encrypted snapshot?"
                confirmation.informativeText = "Edits not saved to the original note will be lost."
                confirmation.addButton(withTitle: "Keep")
                confirmation.addButton(withTitle: "Discard")
                if run(confirmation) == .alertSecondButtonReturn && !cancelled {
                    do { try EncryptedNoteJournal.discard(entry) }
                    catch { PrivacyLog.record("recovery.journal-discard-failed") }
                }
            } else { return }
        }
    }

    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard !cancelled else { return .abort }
        activeAlert = alert
        defer { activeAlert = nil }
        return alert.runModal()
    }

    private static func run(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        guard !cancelled else { return .cancel }
        activePanel = panel
        defer { activePanel = nil }
        return panel.runModal()
    }

    private static func requestPassword(existing: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = existing ? "Unlock the recovery snapshot" : "Protect the recovered note"
        alert.informativeText = existing ? "Enter the password or offline recovery secret used when this snapshot was saved." : "Choose a password for the new encrypted copy. Keep this password to open the recovered note."
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 40, width: 300, height: 24))
        password.placeholderString = "Password"
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 5, width: 300, height: 24))
        confirmation.placeholderString = "Confirm password"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))
        view.addSubview(password)
        if !existing { view.addSubview(confirmation) }
        alert.accessoryView = view
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        passwordFields = [password, confirmation]
        activeAlert = alert
        defer {
            passwordFields.forEach { $0.currentEditor()?.string = ""; $0.stringValue = "" }
            passwordFields.removeAll()
            activeAlert = nil
        }
        alert.window.initialFirstResponder = password
        while !cancelled {
            guard run(alert) == .alertFirstButtonReturn, !cancelled else { return nil }
            guard !password.stringValue.isEmpty, password.stringValue.utf8.count <= 4096 else {
                alert.informativeText = "Use a nonempty password of at most 4096 UTF-8 bytes."
                continue
            }
            guard existing || password.stringValue.utf8.elementsEqual(confirmation.stringValue.utf8) else {
                confirmation.currentEditor()?.string = ""
                confirmation.stringValue = ""
                alert.informativeText = "The passwords do not match. Enter them again."
                continue
            }
            return password.stringValue
        }
        return nil
    }
}
