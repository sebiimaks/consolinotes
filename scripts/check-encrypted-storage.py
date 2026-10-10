#!/usr/bin/env python3
"""Run production persistence/lock transitions against isolated files.

App UI, archive encoding, and cryptographic primitives are stubbed. This tests
persistence ordering, cross-note isolation, failure recovery and cache policy;
it does not certify cryptographic algorithms or the renderer.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


note = (ROOT / "FSNotesCore/Business/Note.swift").read_text()
project = (ROOT / "FSNotesCore/Business/Project.swift").read_text()
methods = "\n".join(method(note, signature) for signature in [
    "    public func save(attributed:",
    "    public func save(content:",
    "    private func writeEncrypted()",
    "    private func commitEncrypted(",
    "    public func encrypt(password:",
    "    public func lock()",
    "    public func unLock(password:",
    "    public func cleanOut()",
    "    func getMeta()",
])
project_encrypt = method(project, "    public func encrypt(password:")
source = r'''
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
enum Failure: Error { case archive }
enum Container { case none, encryptedTextPack }
struct NoteMeta {
    let url: URL; let attachments: [URL]?; let imageUrl: [URL]?
    let title: String; let preview: String; let modificationDate: Date
    let creationDate: Date; let pinned: Bool; let tags: [String]
    let selectedRange: NSRange?
}
final class FakeUndo { var cleared = false; func removeAllActions() { cleared = true } }
extension NSMutableAttributedString {
    func unloadAttachments() -> NSMutableAttributedString { self }
}
extension NSAttributedString {
    func loadAttachments(_ note: Note) -> NSMutableAttributedString { NSMutableAttributedString(attributedString: self) }
}
enum RNCryptor {
    static func decrypt(data: Data, withPassword: String) throws -> Data {
        guard data.starts(with: Data("test-cipher:".utf8)) else { throw Failure.archive }
        return data.dropFirst("test-cipher:".utf8.count)
    }
    static func encrypt(data: Data, withPassword: String) -> Data {
        Data("test-cipher:".utf8) + data
    }
}
enum SSZipArchive {
    static var failNextArchive = false
    static func unzipFile(atPath: String, toDestination: String) -> Bool {
        do {
            let directory = URL(fileURLWithPath: toDestination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: URL(fileURLWithPath: atPath))
            // A malformed package can have metadata but an unreadable/missing body.
            if data != Data("__missing_body__".utf8) {
                try data.write(to: directory.appendingPathComponent("body"))
            }
            return true
        } catch { return false }
    }
    static func createZipFile(atPath: String, withContentsOfDirectory: String) -> Bool {
        if failNextArchive { failNextArchive = false; return false }
        do {
            let body = try Data(contentsOf: URL(fileURLWithPath: withContentsOfDirectory).appendingPathComponent("body"))
            try body.write(to: URL(fileURLWithPath: atPath))
            return true
        } catch { return false }
    }
}
final class Storage {
    static let instance = Storage()
    static func shared() -> Storage { instance }
    var root: URL!
    func add(_ note: Note) {}
    func getNotesBy(project: Project) -> [Note] { project.notes }
    func makeTempEncryptionDirectory() -> URL? {
        let url = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}
final class Project {
    let url: URL; let storage = Storage.shared()
    var notes = [Note](); var isEncrypted = false; var password: String?
    init(_ url: URL) { self.url = url }
    func removeCache() {}
    func getEncryptionStatusFilePath() -> URL { url.appendingPathComponent(".encrypt") }
''' + project_encrypt + r'''
}
final class Note {
    enum PersistenceError: Error { case missingPassword, archiveFailed, invalidBundle, destinationExists }
    let project: Project
    var url: URL
    var decryptedTemporarySrc: URL?
    let writeLock = NSRecursiveLock()
    var lastWriteError: String?
    var password: String? = "test-password"
    var container = Container.none
    var type = 0
    var content = NSMutableAttributedString(string: "")
    var modifiedLocalAt = Date(); var creationDate: Date? = Date()
    var isBlocked = false; var isParsed = false; var cacheHash: Int?
    var isLoaded = false; var testTextBundle = false
    var attachments: [URL]?; var imageUrl: [URL]?
    var tags = [String](); var title = ""; var preview = ""
    var selectedRange: NSRange?; var isPinned = false
    let undoManager = FakeUndo()
    var failureAlerts = 0; var purges = 0
    var simulatePartialRemovalFailure = false
    init(_ name: String, project: Project, unlocked: Bool = true) throws {
        self.project = project
        url = project.url.appendingPathComponent(name + (unlocked ? ".etp" : ".md"))
        project.notes.append(self)
        if unlocked {
            let directory = Storage.shared().makeTempEncryptionDirectory()!
            let bundle = directory.appendingPathComponent("note.textbundle")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            decryptedTemporarySrc = bundle
        }
    }
    func presentSaveFailure() { failureAlerts += 1 }
    func presentCleanupWarning() { failureAlerts += 1 }
    func removePlaintextSource(at source: URL) throws {
        if simulatePartialRemovalFailure {
            try FileManager.default.removeItem(at: source.appendingPathComponent("body"))
            throw Failure.archive
        }
        try FileManager.default.removeItem(at: source)
    }
    func parseURL() {}
    func isUnlocked() -> Bool { decryptedTemporarySrc != nil }
    func isEncrypted() -> Bool { container == .encryptedTextPack || isUnlocked() }
    func isEncryptedAndLocked() -> Bool { container == .encryptedTextPack && !isUnlocked() }
    func isTextBundle() -> Bool { testTextBundle }
    func loadTextBundle() -> Bool { container = .none; return true }
    func invalidateCache() {}
    func loadFileName() {}
    func loadPreviewInfo() {}
    func loadTitle() {}
    func getContent() -> NSAttributedString? {
        let source: URL
        if let temporary = decryptedTemporarySrc { source = temporary.appendingPathComponent("body") }
        else { source = testTextBundle ? url.appendingPathComponent("body") : url }
        guard let body = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        return NSAttributedString(string: body)
    }
    func getFileAttributes() -> [FileAttributeKey: Any] { [:] }
    func purgeSensitiveDerivedData() { purges += 1 }
    func save() -> Bool { write(attributedString: content) }
    func write(attributedString: NSAttributedString) -> Bool {
        do {
            if let working = decryptedTemporarySrc {
                try Data(attributedString.string.utf8).write(to: working.appendingPathComponent("body"), options: .atomic)
                try writeEncrypted()
            } else {
                let target = testTextBundle ? url.appendingPathComponent("body") : url
                try Data(attributedString.string.utf8).write(to: target, options: .atomic)
            }
            isLoaded = true
            lastWriteError = nil
            return true
        } catch { lastWriteError = error.localizedDescription; return false }
    }
    func makeEncryptionBundle(in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("note.textbundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        try Data(content.string.utf8).write(to: bundle.appendingPathComponent("body"))
        return bundle
    }
''' + methods + r'''
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
Storage.shared().root = root.appendingPathComponent("temporary")
try FileManager.default.createDirectory(at: Storage.shared().root, withIntermediateDirectories: true)
let folder = root.appendingPathComponent("notes")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let project = Project(folder)
let a = try Note("a", project: project)
let b = try Note("b", project: project)
a.save(attributed: NSAttributedString(string: "first-a"))
b.save(attributed: NSAttributedString(string: "first-b"))
a.save(attributed: NSAttributedString(string: "latest-a"))
expect(try! String(contentsOf: a.url, encoding: .utf8) == "test-cipher:latest-a", "latest edit to A must be committed")
expect(try! String(contentsOf: b.url, encoding: .utf8) == "test-cipher:first-b", "saving A must not discard B")

let working = a.decryptedTemporarySrc!
a.content = NSMutableAttributedString(string: "unsaved-a")
SSZipArchive.failNextArchive = true
expect(!a.lock(), "failed encrypted flush must fail lock")
expect(a.isUnlocked() && a.password != nil, "failed lock must keep the working state and key")
expect(FileManager.default.fileExists(atPath: working.path), "failed lock must retain recoverable plaintext")
expect(a.content.string == "unsaved-a", "failed lock must not clear edits")
expect(try! String(contentsOf: a.url, encoding: .utf8) == "test-cipher:latest-a", "failed archive must preserve original ciphertext")
expect(a.lastWriteError != nil, "failed lock must expose an error")
let originalURL = a.url
a.url = root.appendingPathComponent("missing-parent/a.etp")
expect(!a.lock(), "atomic destination write failure must fail lock")
expect(a.isUnlocked() && FileManager.default.fileExists(atPath: working.path), "destination write failure must retain working content")
expect(try! String(contentsOf: originalURL, encoding: .utf8) == "test-cipher:latest-a", "destination failure must leave previous ciphertext intact")
a.url = originalURL
expect(a.lock(), "retry after the failure must lock")
expect(!FileManager.default.fileExists(atPath: working.path), "successful lock must remove plaintext")
expect(a.content.length == 0 && a.password == nil, "successful lock must clear content and key")
expect(try! String(contentsOf: a.url, encoding: .utf8) == "test-cipher:unsaved-a", "lock must commit the latest edit")
expect(a.undoManager.cleared && a.purges == 1, "successful lock must clear undo and derived content")

b.tags = ["private-tag"]; b.attachments = [root.appendingPathComponent("sensitive-name")]
b.imageUrl = b.attachments; b.title = "secret title"; b.preview = "secret preview"
b.selectedRange = NSRange(location: 2, length: 3)
let meta = b.getMeta()
expect(meta.tags.isEmpty && meta.attachments == nil && meta.imageUrl == nil, "encrypted cache must omit tags and attachment locations")
expect(meta.title.isEmpty && meta.preview.isEmpty && meta.selectedRange == nil, "unlocked encrypted cache must omit content metadata")

let reloaded = try Note("external", project: project)
reloaded.save(attributed: NSAttributedString(string: "existing body"))
let oldWorking = reloaded.decryptedTemporarySrc!
try Data("test-cipher:__missing_body__".utf8).write(to: reloaded.url)
expect(!reloaded.unLock(password: "test", reload: true), "reload must reject a package with missing body")
expect(reloaded.decryptedTemporarySrc == oldWorking && FileManager.default.fileExists(atPath: oldWorking.path), "failed reload must keep the old working directory")
expect(reloaded.content.string == "existing body", "failed reload must preserve existing content")
reloaded.lastWriteError = nil
try Data("test-cipher:external body".utf8).write(to: reloaded.url)
expect(reloaded.unLock(password: "test", reload: true), "valid external update must load")
expect(reloaded.content.string == "external body", "reload must use the fully read body")
expect(!FileManager.default.fileExists(atPath: oldWorking.path), "successful reload must retire its old working directory")
let updatedWorking = reloaded.decryptedTemporarySrc!
reloaded.lastWriteError = "unsaved edits"
expect(!reloaded.unLock(password: "test", reload: true), "reload must not overwrite unsaved changes")
expect(reloaded.decryptedTemporarySrc == updatedWorking, "refused reload must keep working state")

let migrationFolder = root.appendingPathComponent("migration")
try FileManager.default.createDirectory(at: migrationFolder, withIntermediateDirectories: true)
let migration = Project(migrationFolder)
let first = try Note("first", project: migration, unlocked: false)
let second = try Note("second", project: migration, unlocked: false)
first.content = NSMutableAttributedString(string: "first-plain")
second.content = NSMutableAttributedString(string: "second-plain")
expect(first.save() && second.save(), "plain fixtures must save")
let collision = migrationFolder.appendingPathComponent("second.etp")
try Data("existing-other-note".utf8).write(to: collision)
let partial = migration.encrypt(password: "test")
expect(partial.count == 1 && first.isEncrypted(), "successful notes remain encrypted after partial conversion")
expect(!migration.isEncrypted, "partial conversion must not mark the folder encrypted")
expect(!FileManager.default.fileExists(atPath: migration.getEncryptionStatusFilePath().path), "partial conversion must not create encrypted marker")
expect(try! String(contentsOf: second.url, encoding: .utf8) == "second-plain", "failed conversion must preserve original plaintext")
expect(try! String(contentsOf: collision, encoding: .utf8) == "existing-other-note", "conversion must never overwrite another note")
try FileManager.default.removeItem(at: collision)
_ = migration.encrypt(password: "test")
expect(migration.isEncrypted, "a complete retry must mark the folder encrypted")
expect(first.isEncrypted() && second.isEncrypted(), "all notes must be encrypted before marking the folder")

let cached = try Note("metadata-only", project: project, unlocked: false)
cached.url = folder.appendingPathComponent("metadata-only.textbundle")
cached.testTextBundle = true
try FileManager.default.createDirectory(at: cached.url, withIntermediateDirectories: false)
try Data("existing uncached body".utf8).write(to: cached.url.appendingPathComponent("body"))
expect(!cached.isLoaded && cached.content.length == 0, "fixture must only have metadata loaded")
expect(cached.encrypt(password: "test"), "metadata-only bundle must encrypt")
expect(try! String(contentsOf: cached.url, encoding: .utf8) == "test-cipher:existing uncached body", "encryption must load the on-disk body instead of overwriting it with empty content")

let unreadable = try Note("missing-body", project: project, unlocked: false)
unreadable.url = folder.appendingPathComponent("missing-body.textbundle")
unreadable.testTextBundle = true
try FileManager.default.createDirectory(at: unreadable.url, withIntermediateDirectories: false)
expect(!unreadable.encrypt(password: "test"), "unreadable existing body must stop encryption")
expect(FileManager.default.fileExists(atPath: unreadable.url.path), "failed body load must preserve original bundle")

let partialRemoval = try Note("partial-removal", project: project, unlocked: false)
partialRemoval.url = folder.appendingPathComponent("partial-removal.textbundle")
partialRemoval.testTextBundle = true
partialRemoval.simulatePartialRemovalFailure = true
try FileManager.default.createDirectory(at: partialRemoval.url, withIntermediateDirectories: false)
try Data("irreplaceable body".utf8).write(to: partialRemoval.url.appendingPathComponent("body"))
expect(!partialRemoval.encrypt(password: "test"), "partial source deletion must report conversion incomplete")
let preservedCiphertext = folder.appendingPathComponent("partial-removal.etp")
expect(try! String(contentsOf: preservedCiphertext, encoding: .utf8) == "test-cipher:irreplaceable body", "partial source deletion must never delete the committed recovery ciphertext")
expect(partialRemoval.content.string == "irreplaceable body", "partial source deletion must also retain in-memory body")
expect(partialRemoval.lastWriteError?.contains("preserved") == true, "cleanup failure must explain the preserved encrypted copy")

let newNote = try Note("brand-new", project: project, unlocked: false)
newNote.content = NSMutableAttributedString(string: "new secret")
let plaintextURL = newNote.url
expect(newNote.encrypt(password: "test"), "brand-new encrypted notes must be writable without saving plaintext first")
expect(!FileManager.default.fileExists(atPath: plaintextURL.path), "new encrypted note must never create a normal plaintext file")
print("Verified metadata-only conversion, unreadable-body preservation, independent saves, failed-save recovery, safe lock, encrypted metadata, partial folder conversion, collision refusal, and encrypted creation.")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-encryption-check-") as temp:
    work = Path(temp)
    main = work / "main.swift"
    main.write_text(source)
    subprocess.run(["xcrun", "swift", "-module-cache-path", str(work / "module-cache"), str(main), str(work)], check=True)
