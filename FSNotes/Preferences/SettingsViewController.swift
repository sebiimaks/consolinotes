// Based on FSNotes, copyright © 2023 Oleksandr Hlushchenko. All rights reserved.
import AppKit

/// Controls local history only; no transport, origin or credentials are exposed.
class SettingsViewController: NSViewController {
    public var gitProject: Project?
    public var project: Project?
    public var progress: GitProgress?
    @IBOutlet weak var localHistoryContainer: NSView?
    private let snapshotButton = NSButton(title: "Enable Local History", target: nil, action: nil)
    private let removeButton = NSButton(title: "Delete Local History…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var controlsAdded = false

    public func loadGit(project: Project) {
        gitProject = project.isVirtual ? Storage.shared().getDefault() : project
        guard let project = gitProject, let container = localHistoryContainer else { return }
        if !controlsAdded {
            let description = NSTextField(wrappingLabelWithString: "Local history retains earlier note contents, including plaintext saved before encryption. It never syncs. Enable it only for notes whose history you want to keep.")
            snapshotButton.target = self
            snapshotButton.action = #selector(saveLocalSnapshot(_:))
            removeButton.target = self
            removeButton.action = #selector(removeRepository(_:))
            let buttons = NSStackView(views: [snapshotButton, removeButton])
            buttons.spacing = 12
            let stack = NSStackView(views: [description, buttons, status])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
            ])
            controlsAdded = true
        }
        progress = GitProgress(statusTextField: status, project: project)
        updateButtons()
    }

    @objc private func saveLocalSnapshot(_ sender: Any) {
        guard let project = gitProject else { return }
        snapshotButton.isEnabled = false
        removeButton.isEnabled = false
        ViewController.gitQueue.addOperation { [weak self] in
            guard let self = self else { return }
            let message = project.gitDo(project.getRepositoryState(), progress: self.progress)
            DispatchQueue.main.async {
                if let message = message { self.status.stringValue = message }
                self.updateButtons()
            }
        }
    }

    @objc func removeRepository(_ sender: Any) {
        guard let project = gitProject else { return }
        let alert = NSAlert()
        alert.messageText = "Delete local history?"
        alert.informativeText = "This permanently deletes saved revisions for this folder. Your current notes remain. Copies in external backups are unaffected."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete History")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        snapshotButton.isEnabled = false
        removeButton.isEnabled = false
        ViewController.gitQueue.addOperation { [weak self] in
            guard let self = self else { return }
            project.removeRepository(progress: self.progress)
            DispatchQueue.main.async { self.updateButtons() }
        }
    }

    private func updateButtons() {
        guard let project = gitProject else { return }
        snapshotButton.title = project.getRepositoryState().title
        snapshotButton.isEnabled = !project.isEncrypted
        removeButton.isEnabled = project.hasRepository()
    }
}
