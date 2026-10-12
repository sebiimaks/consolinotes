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
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = NSSize(width: 550, height: 352)
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
