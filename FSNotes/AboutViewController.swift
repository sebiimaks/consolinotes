//
//  AboutViewController.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 5/10/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class AboutViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    
    @IBOutlet weak var translatorsList: NSTableView!

    private var licensesWindowController: NSWindowController?
    
    private var languages = [
        "Deutsch 🇩🇪",
        "Ukrainian🇺🇦",
        "Spanish 🇪🇸",
        "Arabic 🇮🇶",
        "Chinese 🇨🇳",
        "Korean 🇰🇷",
        "French 🇫🇷",
        "Dutch 🇳🇱",
        "Portuguese 🇵🇹",
        "Italian 🇮🇹",
        "Hebrew 🇮🇱",
        "Chinese 🇨🇳",
        "Portuguese 🇵🇹",
        "Czech 🇨🇿",
        "Hindi 🇮🇳",
        "Turkish 🇹🇷",
        "Chinese 🇹🇼🇭🇰🇲🇴"
    ]
    
    private var authors = [
        "Michael Barzmann",
        "Olena Hlushchenko ♥️",
        "aonez (aone@keka.io)",
        "Ayad (@ayad0net)",
        "Pertim (macwk.com@gmail.com)",
        "Wonsup Yoon (pusnow@kaist.ac.kr)",
        "Simon Jornet (github.com/jornetsimon)",
        "Chris Hendriks (github.com/olikilo)",
        "reddit.com/user/endallbeallknowitall",
        "Leonardo Bartoletti - leodmc88@gmail.com",
        "Will Pazner (github.com/pazner)",
        "Holton Jiang (github.com/holton-jiang)",
        "Vanessa C. (github.com/VChristinne)",
        "Max Akrman (github.com/isametry)",
        "Aagman (stscpns@gmail.com)",
        "Bünyamin Erol (bunyaminerol.com.tr)",
        "Wen Xiang (imwwx@icloud.com)"
    ]
    
    override func viewDidLoad() {
        super.viewDidLoad()

        if let dictionary = Bundle.main.infoDictionary,
            let ver = dictionary["CFBundleShortVersionString"] as? String,
            let build = dictionary["CFBundleVersion"] as? String {
            versionLabel.stringValue = "Version \(ver) (\(build))"
            versionLabel.isSelectable = true
        }
        
        translatorsList.delegate = self
        translatorsList.dataSource = self
    }

    @IBOutlet weak var versionLabel: NSTextField!

    @IBAction func openProjectPage(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/sebiimaks/consolinotes")!)
    }
    
    @IBAction func openContributorsPage(_ sender: Any) {
        let url = URL(string: "https://github.com/glushchenko/fsnotes/graphs/contributors")!
        NSWorkspace.shared.open(url)
    }

    @IBAction func showLicenses(_ sender: Any) {
        if let controller = licensesWindowController {
            controller.showWindow(sender)
            controller.window?.makeKeyAndOrderFront(sender)
            return
        }

        do {
            guard let licenseURL = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
                  let noticesURL = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let license = try String(contentsOf: licenseURL, encoding: .utf8)
            let notices = try String(contentsOf: noticesURL, encoding: .utf8)

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.autoresizingMask = [.width, .height]

            let textView = NSTextView(frame: scrollView.contentView.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = .textColor
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.string = "consolinotes — project licence\n\n" + license + "\n\n" + notices
            scrollView.documentView = textView

            let window = NSWindow(contentRect: scrollView.frame,
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "consolinotes — Licences and acknowledgements"
            window.contentView = scrollView
            window.minSize = NSSize(width: 480, height: 320)
            window.center()
            let controller = NSWindowController(window: window)
            licensesWindowController = controller
            controller.showWindow(sender)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to open bundled licences"
            alert.informativeText = "The app's licence files could not be read. Please reinstall consolinotes."
            alert.runModal()
        }
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return languages.count
    }
        
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result  = tableView.makeView(withIdentifier: (tableColumn?.identifier)!, owner: self) as! NSTableCellView
        if  tableColumn?.identifier.rawValue == "table.about.0" {
            result.textField?.stringValue = languages[row]
        } else {
            result.textField?.stringValue = authors[row]
        }
        return result
    }
}
