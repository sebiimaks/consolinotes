// Based on FSNotes, copyright © 2019 Oleksandr Glushchenko. All rights reserved.
import Cocoa

class PreferencesGitViewController: SettingsViewController {
    private let historyView = NSView()
    private let repositoriesPath = NSPathControl()
    private let scheduled = NSButton(checkboxWithTitle: "Save local snapshots on a schedule", target: nil, action: nil)
    private let hours = NSTextField(string: "1")
    private let minutes = NSTextField(string: "5")
    private let askMessage = NSButton(checkboxWithTitle: "Ask for a snapshot message", target: nil, action: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Local History"
        preferredContentSize = NSSize(width: 560, height: 420)
        localHistoryContainer = historyView
        historyView.translatesAutoresizingMaskIntoConstraints = false
        historyView.heightAnchor.constraint(equalToConstant: 145).isActive = true
        scheduled.target = self
        scheduled.action = #selector(changeSchedule(_:))
        askMessage.target = self
        askMessage.action = #selector(changeMessage(_:))
        hours.target = self
        hours.action = #selector(changeSchedule(_:))
        minutes.target = self
        minutes.action = #selector(changeSchedule(_:))
        hours.widthAnchor.constraint(equalToConstant: 42).isActive = true
        minutes.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let timing = NSStackView(views: [NSTextField(labelWithString: "Every"), hours, NSTextField(labelWithString: "hours, at minute"), minutes])
        timing.spacing = 8
        let show = NSButton(title: "Show History Folder", target: self, action: #selector(showFolder(_:)))
        let stack = NSStackView(views: [historyView, scheduled, timing, askMessage, repositoriesPath, show])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
            historyView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            repositoriesPath.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let project = Storage.shared().getDefault() { loadGit(project: project) }
        repositoriesPath.url = UserDefaultsManagement.gitStorage
        scheduled.state = UserDefaultsManagement.backupManually ? .off : .on
        hours.integerValue = UserDefaultsManagement.snapshotsInterval
        minutes.integerValue = UserDefaultsManagement.snapshotsIntervalMinutes
        askMessage.state = UserDefaultsManagement.askCommitMessage ? .on : .off
    }

    @objc private func changeSchedule(_ sender: Any) {
        UserDefaultsManagement.backupManually = scheduled.state != .on
        let interval = min(24, max(1, hours.integerValue))
        let minute = min(59, max(0, minutes.integerValue))
        hours.integerValue = interval
        minutes.integerValue = minute
        UserDefaultsManagement.snapshotsInterval = interval
        UserDefaultsManagement.snapshotsIntervalMinutes = minute
        ViewController.shared()?.scheduleSnapshots()
    }

    @objc private func changeMessage(_ sender: Any) {
        UserDefaultsManagement.askCommitMessage = askMessage.state == .on
    }

    @objc private func showFolder(_ sender: Any) {
        guard let folder = UserDefaultsManagement.gitStorage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
