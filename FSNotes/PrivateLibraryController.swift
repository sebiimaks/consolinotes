// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import AppKit
import Darwin

/// Runs before Storage exists. Existing libraries are never silently replaced by
/// an empty fallback when a bookmark is missing or a volume is unavailable.
enum PrivateLibraryController {
    static func prepareForLaunch() -> Bool {
        umask(0o077)
        let bookmarks = SandboxBookmark.sharedInstance()
        bookmarks.load()
        do {
            if UserDefaultsManagement.librarySetupVersion >= 3,
               let selected = UserDefaultsManagement.configuredStorageURL {
                let url = PrivateLibraryManager.system?.contains(selected) == true
                    ? selected : bookmarks.resolvedURL(for: selected)
                if let url = url, isAccessibleDirectory(url) {
                    if url != selected {
                        guard bookmarks.authorize(url: url, role: .library) else { throw CocoaError(.fileWriteNoPermission) }
                        try commit(url: url, isPrivate: false, backupIncluded: UserDefaultsManagement.privateLibraryBackupIncluded)
                    }
                    if PrivateLibraryManager.system?.contains(url) == true {
                        try PrivateLibraryManager.system?.setBackupIncluded(UserDefaultsManagement.privateLibraryBackupIncluded, at: url)
                    }
                    warnAboutUnavailableFolders(bookmarks)
                    return true
                }
                return chooseExistingLibrary(reconnecting: true)
            }
            if !UserDefaultsManagement.hasPreviousLibraryConfiguration && !hasLegacySandboxNotes() {
                guard let manager = PrivateLibraryManager.system else { throw CocoaError(.fileWriteUnknown) }
                let library = try manager.create(backupIncluded: false)
                try commit(url: library, isPrivate: true, backupIncluded: false)
                warnAboutUnavailableFolders(bookmarks)
                return true
            }
            return chooseExistingLibrary(reconnecting: false)
        } catch {
            showFailure(error)
            return false
        }
    }

    static func manageStorage() {
        let alert = NSAlert()
        alert.messageText = "Library storage and backups"
        alert.informativeText = "Private storage is inside this app’s Application Support folder. Ordinary notes are still plaintext. Copying verifies every file and keeps your original library. Choosing an existing folder changes which library opens; it does not move or delete files."
        alert.addButton(withTitle: "Copy Library into Private Storage…")
        alert.addButton(withTitle: "Choose Existing Folder…")
        alert.addButton(withTitle: "Apply Backup Preference")
        alert.addButton(withTitle: "Cancel")
        let checkbox = backupCheckbox()
        alert.accessoryView = checkbox
        let response = alert.runModal()
        guard response != NSApplication.ModalResponse(rawValue: 1003) else { return }
        do {
            if response == .alertThirdButtonReturn {
                guard let library = UserDefaultsManagement.configuredStorageURL,
                      let manager = PrivateLibraryManager.system, manager.contains(library) else {
                    let notice = NSAlert()
                    notice.messageText = "Backup preference applies to private storage"
                    notice.informativeText = "Your current library is an external folder. Its backup and sync behavior is controlled by the services that manage that folder."
                    notice.runModal()
                    return
                }
                try manager.setBackupIncluded(checkbox.state == .on, at: library)
                UserDefaultsManagement.privateLibraryBackupIncluded = checkbox.state == .on
                return
            }
            guard finishPendingWrites() else { return }
            if response == .alertFirstButtonReturn {
                guard let source = UserDefaultsManagement.configuredStorageURL,
                      let manager = PrivateLibraryManager.system else { return }
                let destination = try manager.copy(source: source, backupIncluded: checkbox.state == .on)
                try commit(url: destination, isPrivate: true, backupIncluded: checkbox.state == .on)
            } else if response == .alertSecondButtonReturn {
                guard let source = selectFolder(message: "Choose the existing library to open. Your current files will be kept.") else { return }
                try useExisting(source)
            } else { return }
            Storage.instance?.removeCachedTree()
            AppDelegate.relaunch()
        } catch { showFailure(error) }
    }

    private static func chooseExistingLibrary(reconnecting: Bool) -> Bool {
        while true {
            let alert = NSAlert()
            alert.messageText = reconnecting ? "Reconnect your note library" : "Choose how to keep your existing notes"
            alert.informativeText = "This version uses private app storage for new libraries and no longer has automatic access to Documents. Select your existing library to continue using it, or copy it into private storage. The copy is verified before settings change, and originals are kept. Cancel leaves your library unchanged and closes the app."
            alert.addButton(withTitle: "Copy into Private Storage…")
            alert.addButton(withTitle: "Use Existing Folder…")
            alert.addButton(withTitle: "Cancel")
            let checkbox = backupCheckbox()
            alert.accessoryView = checkbox
            let choice = alert.runModal()
            guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return false }
            guard let source = selectFolder(message: "Select your existing consolinotes library to authorize access. Check that this is the folder containing your notes.") else { continue }
            do {
                if choice == .alertFirstButtonReturn {
                    let accessed = source.startAccessingSecurityScopedResource()
                    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                    guard let manager = PrivateLibraryManager.system else { throw CocoaError(.fileWriteUnknown) }
                    let destination = try manager.copy(source: source, backupIncluded: checkbox.state == .on)
                    try commit(url: destination, isPrivate: true, backupIncluded: checkbox.state == .on)
                } else { try useExisting(source) }
                warnAboutUnavailableFolders(SandboxBookmark.sharedInstance())
                return true
            } catch { showFailure(error) }
        }
    }

    private static func useExisting(_ source: URL) throws {
        guard isAccessibleDirectory(source) else { throw CocoaError(.fileReadNoPermission) }
        let isPrivate = PrivateLibraryManager.system?.contains(source) == true
        if !isPrivate {
            guard SandboxBookmark.sharedInstance().authorize(url: source, role: .library) else { throw CocoaError(.fileWriteNoPermission) }
        }
        try commit(url: source, isPrivate: isPrivate, backupIncluded: UserDefaultsManagement.privateLibraryBackupIncluded)
    }

    private static func commit(url: URL, isPrivate: Bool, backupIncluded: Bool) throws {
        guard let preferences = UserDefaultsManagement.shared else { throw CocoaError(.fileWriteUnknown) }
        let keys = ["storageUrl", "storageType", "privateLibraryURL", "privateLibraryBackupIncluded", "librarySetupVersion"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, preferences.object(forKey: $0)) })
        let old = UserDefaultsManagement.configuredStorageURL
        UserDefaultsManagement.privateLibraryURL = isPrivate ? url : nil
        UserDefaultsManagement.customStoragePath = isPrivate ? nil : url.path
        UserDefaultsManagement.storageType = isPrivate ? .local : .custom
        UserDefaultsManagement.privateLibraryBackupIncluded = backupIncluded
        UserDefaultsManagement.librarySetupVersion = 3
        guard preferences.synchronize() else {
            for key in keys { preferences.set(previous[key] ?? nil, forKey: key) }
            _ = preferences.synchronize()
            SandboxBookmark.sharedInstance().load()
            throw CocoaError(.fileWriteUnknown)
        }
        let bookmarks = SandboxBookmark.sharedInstance()
        if let old = old, old != url { bookmarks.remove(url: old, role: .library) }
        bookmarks.load()
    }

    private static func backupCheckbox() -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "Include private library in system backups", target: nil, action: nil)
        checkbox.state = UserDefaultsManagement.privateLibraryBackupIncluded ? .on : .off
        checkbox.toolTip = "Off excludes the private library from standard system backups. Backups can contain plaintext ordinary notes. This does not control third-party copying or existing backups."
        return checkbox
    }

    private static func selectFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Note Library"
        panel.message = message
        panel.prompt = "Use This Folder"
        panel.directoryURL = UserDefaultsManagement.configuredStorageURL ?? UserDefaultsManagement.legacyDocumentsURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    private static func finishPendingWrites() -> Bool {
        guard let storage = Storage.instance else { return true }
        ViewController.shared()?.lockAll(self)
        guard !storage.noteList.contains(where: { $0.isUnlocked() || $0.hasPendingPlaintextCleanup || (!$0.isEncryptedAndLocked() && $0.lastWriteError != nil) }) else {
            let alert = NSAlert()
            alert.messageText = "Finish saving before changing libraries"
            alert.informativeText = "Some edits or cleanup are still pending. Resolve the storage problem and retry. Your current library remains selected."
            alert.runModal()
            return false
        }
        return true
    }

    private static func isAccessibleDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path) && FileManager.default.isWritableFile(atPath: url.path)
    }

    private static func hasLegacySandboxNotes() -> Bool {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        return entries.contains { !["projects.state", ".DS_Store"].contains($0.lastPathComponent) }
    }

    private static func warnAboutUnavailableFolders(_ bookmarks: SandboxBookmark) {
        guard bookmarks.unavailableFolders > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Some attached folders need access"
        alert.informativeText = "Their files and saved folder selections were kept. Reattach the folders using Add Folder when their drives are available."
        alert.runModal()
    }

    private static func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Library setup could not finish"
        alert.informativeText = "Your original library files have been kept. Any completed copy is also kept. Check access and available space, then try again.\n\n" + error.localizedDescription
        alert.runModal()
    }
}
