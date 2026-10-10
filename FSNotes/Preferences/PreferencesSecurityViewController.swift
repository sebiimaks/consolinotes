//
//  PreferencesSecurityViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/17/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import LocalAuthentication

class PreferencesSecurityViewController: NSViewController {

    @IBOutlet weak var lockOnSleep: NSButton!
    @IBOutlet weak var lockOnScreenActivated: NSButton!
    @IBOutlet weak var lockWhenFastUser: NSButton!
    @IBOutlet weak var allowTouchID: NSButton!
    @IBOutlet weak var masterPassword: NSButton!

    override func viewDidLoad() {
        lockOnSleep.state = UserDefaultsManagement.lockOnSleep ? .on : .off
        lockOnScreenActivated.state = UserDefaultsManagement.lockOnScreenActivated ? .on : .off
        lockWhenFastUser.state = UserDefaultsManagement.lockOnUserSwitch ? .on : .off
        
        allowTouchID.title = "Use saved unlock password"
        allowTouchID.toolTip = "macOS authentication protects the saved password on this Mac. You can always enter each note's password manually."
        masterPassword.title = "Saved Unlock Password…"
        masterPassword.toolTip = "Save a device-only password with macOS authentication. This does not change any encrypted note's password."
        allowTouchID.state = UserDefaultsManagement.allowTouchID ? .on : .off
        let available = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        allowTouchID.isEnabled = available
        masterPassword.isEnabled = available
        if !available { allowTouchID.state = .off }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = NSSize(width: 550, height: 352)
    }

    @IBAction func openMasterPasswordWindow(_ sender: Any) {
        guard let vc = ViewController.shared() else { return }

        if let controller = vc.storyboard?.instantiateController(withIdentifier: "MasterPasswordViewController") as? MasterPasswordViewController {

            presentAsSheet(controller)
        }
    }

    @IBAction func lockOnSleep(_ sender: NSButton) {
        UserDefaultsManagement.lockOnSleep = (sender.state == .on)
    }

    @IBAction func lockOnScreenActivated(_ sender: NSButton) {
        UserDefaultsManagement.lockOnScreenActivated = (sender.state == .on)
    }

    @IBAction func lockWhenSwitched(_ sender: NSButton) {
        UserDefaultsManagement.lockOnUserSwitch = (sender.state == .on)
    }

    @IBAction func allowTouchID(_ sender: NSButton) {
        UserDefaultsManagement.allowTouchID = (sender.state == .on)

        // Turning this off stops convenience unlocking; it does not erase a saved password.
    }

}
