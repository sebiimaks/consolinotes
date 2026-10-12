import Foundation

/// Removes only credentials and connection metadata written by older app versions.
/// This does not touch notes, repositories, original SSH key files, or published sites.
enum LegacyNetworkCleanup {
    enum CleanupError: Error { case incomplete }

    private static let preferenceKeys = [
        "gitUsername", "gitPassword", "gitOrigin", "gitPrivateKeyData",
        "gitPasspharse", "gitPassphrase", "pullInterval", "sftpHost", "sftpPort",
        "sftpPath", "sftpPassphrase", "sftpWeb", "sftpUsername", "sftpPassword",
        "sftpKeysAccessData", "sftpPublicKeyData", "sftpUploadBookmarksData"
    ]

    static func run() throws {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CleanupError.incomplete
        }
        try purge(defaults: .standard, applicationSupport: support)
    }

    /// Explicit paths/defaults allow tests to exercise migration with synthetic fixtures.
    static func purge(defaults: UserDefaults, applicationSupport: URL) throws {
        preferenceKeys.forEach { defaults.removeObject(forKey: $0) }
        let files = FileManager.default
        guard files.fileExists(atPath: applicationSupport.path) else { return }
        let supportValues = try applicationSupport.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard supportValues.isDirectory == true, supportValues.isSymbolicLink != true else {
            throw CleanupError.incomplete
        }
        var incomplete = false
        let prefix = "es.fsnot.project-settings"
        let children = try files.contentsOfDirectory(at: applicationSupport, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        NSKeyedUnarchiver.setClass(ProjectSettings.self, forClassName: "ProjectSettings")
        NSKeyedArchiver.setClassName("ProjectSettings", for: ProjectSettings.self)
        for file in children where file.lastPathComponent.hasPrefix(prefix) {
            let suffix = String(file.lastPathComponent.dropFirst(prefix.count))
            guard isProjectKey(suffix) else { continue }
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CleanupError.incomplete
                }
                let data = try Data(contentsOf: file)
                let archive = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                let objects = archive?["$objects"] as? [[String: Any]] ?? (archive?["$objects"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
                let retired = Set(["gitOrigin", "gitAutoPull", "gitPrivateKey", "gitPublicKey", "gitPrivateKeyPassphrase", "notesAPI"])
                guard objects.contains(where: { !retired.isDisjoint(with: $0.keys) }) else { continue }
                guard let settings = try NSKeyedUnarchiver.unarchivedObject(ofClass: ProjectSettings.self, from: data) else {
                    throw CleanupError.incomplete
                }
                // Re-encoding this allowlisted schema also drops unreferenced secret
                // objects from old keyed archives, rather than leaving their bytes behind.
                let clean = try NSKeyedArchiver.archivedData(withRootObject: settings, requiringSecureCoding: true)
                try clean.write(to: file, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { incomplete = true }
        }

        let keys = applicationSupport.appendingPathComponent("Keys", isDirectory: true)
        if files.fileExists(atPath: keys.path) {
            do {
                let values = try keys.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw CleanupError.incomplete
                }
                for file in try files.contentsOfDirectory(at: keys, includingPropertiesForKeys: [.isDirectoryKey]) {
                    let name = file.pathExtension == "pub" ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
                    guard isProjectKey(name) else { continue }
                    let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    // Never recurse into a directory or follow a key-file symlink.
                    guard values.isDirectory != true || values.isSymbolicLink == true else {
                        incomplete = true
                        continue
                    }
                    try files.removeItem(at: file)
                }
            } catch { incomplete = true }
        }
        // Retry incomplete cleanup on the next launch. Never mark failed deletion as done.
        if incomplete { throw CleanupError.incomplete }
    }

    private static func isProjectKey(_ value: String) -> Bool {
        return value.count == 32 && value.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
    }
}
