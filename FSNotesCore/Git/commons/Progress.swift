//  Adapted from Git2Swift for FSNotes and distributed in consolinotes.
//  See Licenses/native/Git2Swift.txt and THIRD_PARTY_NOTICES.md.
//
//  Progress.swift
//  Git2Swift
//
//  Created by Dami on 24/09/2016.
//  Copyright © 2016 Creabox. All rights reserved.
//

import Foundation
import Cgit2

import AppKit

/// Define progress protocol
public class GitProgress {
    public var project: Project

    public var statusTextField: NSTextField

    init(statusTextField: NSTextField, project: Project) {
        self.statusTextField = statusTextField
        self.project = project
    }
    
    func log(current: Int, total: Int, action: String) {
        let message = "git \(action): chunk \(current) from \(total)"
        send(message: message)
    }
    
    func log(message: String) {
        project.gitStatus = message
        send(message: message)
    }

    func send(message: String) {
        PrivacyLog.record("progress.event-38")

        DispatchQueue.main.async {
            self.statusTextField.stringValue = message
        }
    }
}

final class ProgressDelegate {
    static let checkoutIgnoreFilesProgressCallback: git_checkout_notify_cb = {a,b,c,d,e,f in
        // Dirty found – skip checkout, commit before
        if a.rawValue == 2 {
            return -1
        }

        return 0
    }

    
    

    static let checkoutProgressCallback: git_checkout_progress_cb = { path, completed, total, payload in
        AppDelegate.gitProgress?.log(current: Int(completed), total: Int(total), action: "checkout")
    }
}
