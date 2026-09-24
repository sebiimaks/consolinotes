//
//  ThanksViewController.swift
//  FSNotes iOS
//
//  Created by Александр on 06.03.2022.
//  Copyright © 2022 Oleksandr Glushchenko. All rights reserved.
//

import UIKit

class ThanksViewController: UITableViewController {
    private var rows = [
        "FSNotes — original project",
        "Radio-T",
        "Matt Septhon",
        "Dylan Seeger (Icon design)"
    ]

    private var urls = [
        "https://github.com/glushchenko/fsnotes",
        "https://radio-t.com",
        "https://www.gingerbeardman.com",
        "https://lovably.com"
    ]

    override func viewDidLoad() {
        self.title = NSLocalizedString("Acknowledgements", comment: "Settings")

        super.viewDidLoad()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let url = URL(string: urls[indexPath.row]) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }

        tableView.deselectRow(at: indexPath, animated: false)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return NSLocalizedString("Original FSNotes project", comment: "Upstream acknowledgements")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return NSLocalizedString("FSNotes was originally developed by Oleksandr Glushchenko and contributors. These acknowledgements credit the original project and do not imply involvement in or endorsement of consolinotes.", comment: "Upstream acknowledgements")
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 50
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.textLabel?.text = rows[indexPath.row]
        return cell
    }

    @objc func cancel() {
        navigationController?.popViewController(animated: true)
    }
}

