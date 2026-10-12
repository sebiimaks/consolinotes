//
//  PreferencesSecurityViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/17/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class PreferencesSecurityViewController: NSViewController {

    @IBOutlet weak var lockOnSleep: NSButton!
    @IBOutlet weak var lockOnScreenActivated: NSButton!
    @IBOutlet weak var lockWhenFastUser: NSButton!

    override func viewDidLoad() {
        lockOnSleep.state = UserDefaultsManagement.lockOnSleep ? .on : .off
        lockOnScreenActivated.state = UserDefaultsManagement.lockOnScreenActivated ? .on : .off
        lockWhenFastUser.state = UserDefaultsManagement.lockOnUserSwitch ? .on : .off
        let button = NSButton(title: "YubiKey Unlock…", target: self, action: #selector(openYubiKey))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 35),
            button.topAnchor.constraint(equalTo: lockWhenFastUser.bottomAnchor, constant: 30)
        ])
        let privacy = NSButton(title: "Clipboard Privacy…", target: self, action: #selector(privacyOptions))
        let diagnostics = NSButton(title: "Review Diagnostics…", target: self, action: #selector(diagnostics))
        for control in [privacy, diagnostics] {
            control.bezelStyle = .rounded
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        NSLayoutConstraint.activate([
            privacy.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            privacy.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 12),
            diagnostics.leadingAnchor.constraint(equalTo: privacy.trailingAnchor, constant: 12),
            diagnostics.centerYAnchor.constraint(equalTo: privacy.centerYAnchor)
        ])
        let protection = NSButton(title: "Note Protection…", target: self, action: #selector(protectionOptions))
        protection.bezelStyle = .rounded
        protection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(protection)
        NSLayoutConstraint.activate([
            protection.leadingAnchor.constraint(equalTo: privacy.leadingAnchor),
            protection.topAnchor.constraint(equalTo: privacy.bottomAnchor, constant: 12)
        ])

    }

    @objc private func protectionOptions() {
        let alert = NSAlert()
        alert.messageText = "Note protection"
        alert.informativeText = "Automatic locking saves and hides encrypted notes. New-note encryption asks for a password before creating any file. Key removal locks when any YubiKey is unplugged; it does not change the key."
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        let fresh = NSButton(checkboxWithTitle: "Encrypt new notes by default", target: nil, action: nil)
        let close = NSButton(checkboxWithTitle: "Lock when the last note window closes", target: nil, action: nil)
        let key = NSButton(checkboxWithTitle: "Lock when a YubiKey is removed", target: nil, action: nil)
        fresh.state = PrivacyPreferences.encryptNewNotes ? .on : .off
        close.state = PrivacyPreferences.lockLastWindow ? .on : .off
        key.state = PrivacyPreferences.lockKeyRemoval ? .on : .off
        let idle = NSPopUpButton()
        idle.addItems(withTitles: ["Idle lock: Off", "Idle lock: 1 minute", "Idle lock: 5 minutes", "Idle lock: 15 minutes"])
        let seconds = [0.0, 60, 300, 900]
        idle.selectItem(at: seconds.firstIndex(of: PrivacyPreferences.idleSeconds) ?? 2)
        [fresh, close, key, idle].forEach { stack.addArrangedSubview($0) }
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 140)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stronger YubiKey Protection…")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            PrivacyPreferences.encryptNewNotes = fresh.state == .on
            PrivacyPreferences.lockLastWindow = close.state == .on
            PrivacyLockCoordinator.shared.setKeyRemovalEnabled(key.state == .on)
            PrivacyPreferences.idleSeconds = seconds[idle.indexOfSelectedItem]
        } else if result == .alertThirdButtonReturn {
            let choice = NSAlert()
            choice.messageText = "Protect the selected encrypted note"
            choice.informativeText = "Setup replaces its password with a random secret after a YubiKey and offline recovery have been verified. Rotation replaces an existing secret, for example after losing a key. Previously copied notes and envelopes remain usable with their old secrets."
            choice.addButton(withTitle: "Set Up…")
            choice.addButton(withTitle: "Cancel")
            choice.addButton(withTitle: "Rotate Secret…")
            let response = choice.runModal()
            if response == .alertFirstButtonReturn || response == .alertThirdButtonReturn {
                FIDO2UnlockUI.protectSelectedNote(from: self, rotating: response == .alertThirdButtonReturn)
            }
        }
    }

    @objc private func privacyOptions() {
        let alert = NSAlert()
        alert.messageText = "Clipboard privacy"
        alert.informativeText = "Copies use the local-only clipboard option and are cleared after the selected time, or when notes lock. A newer copy from another app is kept. Clipboard managers may keep their own copies. Search history stays in memory for this session only."
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        choice.addItems(withTitles: ["30 seconds", "1 minute", "2 minutes", "5 minutes"])
        let seconds = [30.0, 60, 120, 300]
        choice.selectItem(at: seconds.firstIndex(of: SensitiveClipboard.expirySeconds) ?? 1)
        alert.accessoryView = choice
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { SensitiveClipboard.expirySeconds = seconds[choice.indexOfSelectedItem] }
        }
    }

    @objc private func diagnostics() {
        let alert = NSAlert()
        alert.messageText = "Review diagnostics"
        alert.informativeText = "Only static event labels from this session are included. Nothing is sent automatically."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.string = PrivacyLog.snapshot()
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = text; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Close")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "consolinotes-diagnostics.txt"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try text.string.write(to: url, atomically: true, encoding: .utf8) }
                catch { PrivacyLog.record("diagnostics.export-failed") }
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = NSSize(width: 550, height: 400)
    }

    @objc private func openYubiKey() { FIDO2UnlockUI.settings(from: self) }

    @IBAction func lockOnSleep(_ sender: NSButton) {
        UserDefaultsManagement.lockOnSleep = (sender.state == .on)
    }

    @IBAction func lockOnScreenActivated(_ sender: NSButton) {
        UserDefaultsManagement.lockOnScreenActivated = (sender.state == .on)
    }

    @IBAction func lockWhenSwitched(_ sender: NSButton) {
        UserDefaultsManagement.lockOnUserSwitch = (sender.state == .on)
    }

}
