import Foundation

// Compile the production settings and migration files with this small preference stub.
class UserDefaultsManagement { static var firstLineAsTitle = true }

final class OldProjectSettings: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    override init() {}
    required init?(coder: NSCoder) { fatalError("fixture encoder only") }
    func encode(with coder: NSCoder) {
        coder.encode("title", forKey: "sortBy")
        coder.encode("asc", forKey: "sortDirection")
        coder.encode(true, forKey: "showInCommon")
        coder.encode(true, forKey: "showInSidebar")
        coder.encode(false, forKey: "showNestedFoldersContent")
        coder.encode(false, forKey: "firstLineAsTitle")
        coder.encode(17, forKey: "priority")
        coder.encode(["keep-preview.md"], forKey: "notesPreview")
        coder.encode("fixture-private-secret", forKey: "gitPrivateKeyPassphrase")
        coder.encode(Data("fixture-key-bytes".utf8), forKey: "gitPrivateKey")
        coder.encode("ssh://fixture.invalid/notes", forKey: "gitOrigin")
        coder.encode(["note": "legacy-web-id"], forKey: "notesAPI")
    }
}

@main
struct OfflineMigrationTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("Application Support")
        let keys = support.appendingPathComponent("Keys")
        try files.createDirectory(at: keys, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let suite = "consolinotes-migration-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fixture-password", forKey: "sftpPassword")
        defaults.set(Data("fixture-bookmark".utf8), forKey: "sftpKeysAccessData")
        defaults.set(16, forKey: "fontsize")
        let key = String(repeating: "a", count: 32)
        NSKeyedArchiver.setClassName("ProjectSettings", for: OldProjectSettings.self)
        let legacy = try NSKeyedArchiver.archivedData(withRootObject: OldProjectSettings(), requiringSecureCoding: true)
        let settings = support.appendingPathComponent("es.fsnot.project-settings" + key)
        try legacy.write(to: settings)
        try Data("private-key-copy".utf8).write(to: keys.appendingPathComponent(key))
        try Data("public-key-copy".utf8).write(to: keys.appendingPathComponent(key + ".pub"))
        let original = root.appendingPathComponent("original-user-key")
        try Data("original-user-key".utf8).write(to: original)
        try files.createSymbolicLink(at: keys.appendingPathComponent(String(repeating: "b", count: 32)), withDestinationURL: original)
        let note = support.appendingPathComponent("untouched-note.md")
        try Data("preserve note".utf8).write(to: note)
        let repo = support.appendingPathComponent("Repositories/history.git/objects")
        try files.createDirectory(at: repo, withIntermediateDirectories: true)
        let object = repo.appendingPathComponent("fixture")
        try Data("preserve revision".utf8).write(to: object)
        let unrelated = keys.appendingPathComponent("user-key-backup")
        try Data("keep unrelated".utf8).write(to: unrelated)

        try LegacyNetworkCleanup.purge(defaults: defaults, applicationSupport: support)
        precondition(defaults.object(forKey: "sftpPassword") == nil)
        precondition(defaults.object(forKey: "sftpKeysAccessData") == nil)
        precondition(defaults.integer(forKey: "fontsize") == 16)
        let sanitized = try Data(contentsOf: settings)
        let plist = try PropertyListSerialization.propertyList(from: sanitized, options: [], format: nil)
        let dump = String(describing: plist)
        for secret in ["fixture-private-secret", "fixture-key-bytes", "gitPrivateKey", "ssh://fixture.invalid", "legacy-web-id"] {
            precondition(!dump.contains(secret), "secret survived archive rewrite")
        }
        let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: ProjectSettings.self, from: sanitized)!
        precondition(restored.sortBy == .title && restored.sortDirection == .asc)
        precondition(restored.priority == 17 && restored.firstLineAsTitle == false)
        precondition(restored.notesPreview == ["keep-preview.md"] && !restored.showNestedFoldersContent)
        precondition(!files.fileExists(atPath: keys.appendingPathComponent(key).path))
        for preserved in [original, note, object, unrelated] { precondition(files.fileExists(atPath: preserved.path)) }
        try LegacyNetworkCleanup.purge(defaults: defaults, applicationSupport: support)
        let afterRetry = try Data(contentsOf: settings)
        precondition(afterRetry == sanitized, "migration must be idempotent")

        // A settings symlink must never cause an external file to be rewritten.
        let linkedSettings = support.appendingPathComponent("es.fsnot.project-settings" + String(repeating: "c", count: 32))
        try files.createSymbolicLink(at: linkedSettings, withDestinationURL: original)
        do {
            try LegacyNetworkCleanup.purge(defaults: defaults, applicationSupport: support)
            fatalError("symlinked archive should report incomplete cleanup")
        } catch LegacyNetworkCleanup.CleanupError.incomplete { }
        let originalText = try String(contentsOf: original, encoding: .utf8)
        precondition(originalText == "original-user-key")
        print("Offline migration: credentials removed; settings, notes, history and original keys preserved; retries and symlinks checked.")
    }
}
