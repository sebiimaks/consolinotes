// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.
import AppKit
import IOKit
import IOKit.usb

enum PrivacyPreferences {
    static var encryptNewNotes: Bool {
        get { UserDefaults.standard.bool(forKey: "encryptNewNotes") }
        set { UserDefaults.standard.set(newValue, forKey: "encryptNewNotes") }
    }
    static var idleSeconds: TimeInterval {
        get { let value = UserDefaults.standard.object(forKey: "privateIdleLockSeconds") as? Double ?? 300
            return [0.0, 60, 300, 900].contains(value) ? value : 300 }
        set { UserDefaults.standard.set(newValue, forKey: "privateIdleLockSeconds") }
    }
    static var lockLastWindow: Bool {
        get { UserDefaults.standard.object(forKey: "lockLastNoteWindow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lockLastNoteWindow") }
    }
    static var lockKeyRemoval: Bool {
        get { UserDefaults.standard.bool(forKey: "lockYubiKeyRemoval") }
        set { UserDefaults.standard.set(newValue, forKey: "lockYubiKeyRemoval") }
    }
}

enum PrivateTextServices {
    static func apply(to text: NSTextView) {
        text.isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) { text.inlinePredictionType = .no }
        if #available(macOS 15.0, *) { text.writingToolsBehavior = .none }
    }
}

enum PlaintextDisclosure {
    private static weak var activePanel: NSSavePanel?
    private static weak var activeAlert: NSAlert?
    private static var generation = 0
    static func cancel() {
        generation += 1
        activePanel?.nameFieldStringValue = ""
        activePanel?.cancel(nil)
        if let alert = activeAlert { NSApp.abortModal(); alert.window.orderOut(nil) }
    }
    static func allowUnencryptedCopy(_ action: String) -> Bool {
        guard PrivacyPreferences.encryptNewNotes else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep this copy unencrypted?"
        alert.informativeText = "New-note encryption is enabled. Importing or duplicating existing plaintext preserves its original format and creates an unencrypted copy. To encrypt it, create an encrypted note first and copy its contents there."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
    static func confirm(_ action: String, note: Note) -> Bool {
        guard !note.isEncryptedAndLocked() else { return false }
        guard note.isEncrypted() else { return true }
        let alert = NSAlert()
        alert.messageText = "\(action) decrypted content?"
        alert.informativeText = "This sends plaintext outside the encrypted note. The destination may keep its own copy after the note locks."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        let operation = generation
        activeAlert = alert
        defer { activeAlert = nil }
        return alert.runModal() == .alertSecondButtonReturn && operation == generation && !note.isEncryptedAndLocked()
    }
    static func exportAttachment(_ url: URL, from note: Note, window: NSWindow?) {
        guard confirm("Export Attachment", note: note) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Decrypted Attachment"
        panel.nameFieldStringValue = url.lastPathComponent
        let operation = generation
        activePanel = panel
        defer { activePanel = nil; panel.nameFieldStringValue = "" }
        guard panel.runModal() == .OK, operation == generation, let destination = panel.url,
              !note.isEncryptedAndLocked(), let data = note.memoryAttachmentData(for: url) else { return }
        do {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            let alert = NSAlert(); alert.messageText = "The attachment could not be exported"
            alert.informativeText = "Check the chosen folder and available space, then try again."
            alert.runModal()
        }
    }
}

/// Uses the existing shield/save/lock path for every automatic trigger.
final class PrivacyLockCoordinator {
    static let shared = PrivacyLockCoordinator()
    private let now: () -> TimeInterval
    private let monitorUnavailable: () -> Void
    private var lastActivity: TimeInterval
    private(set) var keyRemovalAvailable = false
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var fieldObserver: NSObjectProtocol?
    private var timer: Timer?
    private var port: IONotificationPortRef?
    private var removed: io_iterator_t = 0
    private var locking = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         monitorUnavailable: (() -> Void)? = nil) {
        self.now = now
        self.lastActivity = now()
        self.monitorUnavailable = monitorUnavailable ?? {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "YubiKey removal locking is unavailable"
            alert.informativeText = "macOS did not allow consolinotes to monitor YubiKey removal. That option is off. Idle locking and manual Lock All still work. Restart the app to try the removal monitor again."
            alert.runModal()
        }
    }

    @discardableResult
    func setKeyRemovalEnabled(_ enabled: Bool) -> Bool {
        guard !enabled || keyRemovalAvailable else {
            PrivacyPreferences.lockKeyRemoval = false
            monitorUnavailable()
            return false
        }
        PrivacyPreferences.lockKeyRemoval = enabled
        return true
    }

    private func removalMonitorFailed() {
        keyRemovalAvailable = false
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let port = port { IONotificationPortDestroy(port); self.port = nil }
        PrivacyLog.record("privacy.usb-removal-monitor-unavailable")
        if PrivacyPreferences.lockKeyRemoval {
            PrivacyPreferences.lockKeyRemoval = false
            monitorUnavailable()
        }
    }

    private func recordActivity() { lastActivity = now() }

    private func keyRemoved() {
        if keyRemovalAvailable && PrivacyPreferences.lockKeyRemoval { lock() }
    }

    func start() {
        guard timer == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            self?.recordActivity()
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: NSText.didBeginEditingNotification, object: nil, queue: .main) { notification in
            if let text = notification.object as? NSTextView { PrivateTextServices.apply(to: text) }
        }
        fieldObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidBeginEditingNotification, object: nil, queue: .main) { notification in
            if let control = notification.object as? NSControl,
               let text = control.currentEditor() as? NSTextView { PrivateTextServices.apply(to: text) }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkIdle() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { removalMonitorFailed(); return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary? else { removalMonitorFailed(); return }
        matching[kUSBVendorID] = NSNumber(value: 0x1050)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching, { context, iterator in
            guard let context = context else { return }
            let coordinator = Unmanaged<PrivacyLockCoordinator>.fromOpaque(context).takeUnretainedValue()
            var found = false
            while case let device = IOIteratorNext(iterator), device != 0 { found = true; IOObjectRelease(device) }
            if found { coordinator.keyRemoved() }
        }, context, &removed)
        if result == KERN_SUCCESS {
            keyRemovalAvailable = true
            while case let device = IOIteratorNext(removed), device != 0 { IOObjectRelease(device) }
        } else { removalMonitorFailed() }
    }
    private func checkIdle() {
        let seconds = PrivacyPreferences.idleSeconds
        guard seconds > 0, now() - lastActivity >= seconds else { return }
        lock()
    }
    func closing(_ window: NSWindow?) {
        guard PrivacyPreferences.lockLastWindow else { return }
        let windows = [AppDelegate.mainWindowController?.window].compactMap { $0 } + AppDelegate.noteWindows.compactMap { $0.window }
        if !windows.contains(where: { $0 !== window && $0.isVisible }) { lock() }
    }
    func lock() {
        guard !locking, Storage.instance != nil, let controller = ViewController.shared() else { return }
        locking = true
        defer { locking = false }
        // Lock All also cancels pending passwords, confirmations and hardware
        // operations when no note has finished unlocking yet.
        controller.lockAll(self)
        lastActivity = now()
    }
    deinit {
        timer?.invalidate()
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        if let fieldObserver = fieldObserver { NotificationCenter.default.removeObserver(fieldObserver) }
        if removed != 0 { IOObjectRelease(removed) }
        if let port = port { IONotificationPortDestroy(port) }
    }
}
