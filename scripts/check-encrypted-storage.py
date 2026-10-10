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
storage = (ROOT / "FSNotesCore/Business/Storage.swift").read_text()
methods = "\n".join(method(note, signature) for signature in [
    "    public func save(attributed:",
    "    public func save(content:",
    "    public func save()",
    "    public func getURL()",
    "    private func writeEncrypted()",
    "    private func commitEncrypted(",
    "    public func encrypt(password:",
    "    public func lock()",
    "    public func unLock(password:",
    "    public func unEncryptUnlocked()",
    "    public func upgradeEncryption(password:",
    "    public func cleanOut()",
    "    func removeFile(completely:",
    "    func preserveAfterExternalRemoval()",
    "    func getMeta()",
])
project_encrypt = method(project, "    public func encrypt(password:")
storage_remove = method(storage, "    func removeNotes(notes:")
source = (ROOT / "FSNotesCore/PrivateWorkingDirectory.swift").read_text() + r'''
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
enum Failure: Error { case archive }
// Inject an fsync failure after the production atomic replacement has happened.
final class FileHandle {
    static var syncCount = 0
    static var failOnSync: Int?
    let underlying: Foundation.FileHandle
    init(forWritingTo url: URL) throws { underlying = try Foundation.FileHandle(forWritingTo: url) }
    func close() throws { try underlying.close() }
    func synchronize() throws {
        Self.syncCount += 1
        if Self.failOnSync == Self.syncCount { throw Failure.archive }
        try underlying.synchronize()
    }
}
enum Container { case none, encryptedTextPack, textBundleV2 }
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
enum EncryptedNoteCodec {
    enum Format { case legacy, modern }
    struct Session { let format: Format; let identifier = UUID() }
    static var failModernSeal = false
    static var sessionsCreated = 0
    static func makeSession(password: String) throws -> Session {
        sessionsCreated += 1
        return Session(format: .modern)
    }
    static func open(_ data: Data, password: String) throws -> (data: Data, session: Session) {
        if data.starts(with: Data("test-modern:".utf8)) {
            return (data.dropFirst("test-modern:".utf8.count), Session(format: .modern))
        }
        return (try RNCryptor.decrypt(data: data, withPassword: password), Session(format: .legacy))
    }
    static func seal(_ data: Data, session: Session) throws -> Data {
        if session.format == .modern && failModernSeal {
            failModernSeal = false
            throw Failure.archive
        }
        if session.format == .modern { return Data("test-modern:".utf8) + data }
        return RNCryptor.encrypt(data: data, withPassword: "fixture")
    }
}
enum SSZipArchive {
    static var failNextArchive = false
    static var archiveCalls = 0
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
        archiveCalls += 1
        if failNextArchive { failNextArchive = false; return false }
        do {
            let body = try Data(contentsOf: URL(fileURLWithPath: withContentsOfDirectory).appendingPathComponent("body"))
            try body.write(to: URL(fileURLWithPath: atPath))
            return true
        } catch { return false }
    }
}
enum PrivateNoteArchive {
    static func validateSourceDirectory(_ directory: URL) throws { }
    static func extract(_ archive: URL, to destination: URL) -> Bool {
        SSZipArchive.unzipFile(atPath: archive.path, toDestination: destination.path)
    }
}
final class Storage {
    static let instance = Storage()
    static func shared() -> Storage { instance }
    var root: URL!
    var noteList = [Note]()
    var trashDestination: URL?
    func getDefaultTrash() -> Project? { nil }
    func trashItem(url: URL) -> URL? { trashDestination ?? root.appendingPathComponent("trash").appendingPathComponent(url.lastPathComponent) }
    func removeBy(note: Note) { noteList.removeAll { $0 === note } }
    func add(_ note: Note) {}
    func getNotesBy(project: Project) -> [Note] { project.notes }
    func makeTempEncryptionDirectory() -> URL? {
        let url = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
''' + storage_remove + r'''
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
    enum RemovalResult { case deleted; case trashed(destination: URL, original: URL) }
    let project: Project
    var url: URL
    var decryptedTemporarySrc: URL?
    var encryptionSession: EncryptedNoteCodec.Session? = .init(format: .legacy)
    var plaintextCleanupPending = false
    var retainedPlaintextDirectories = Set<URL>()
    var hasPendingPlaintextCleanup: Bool { plaintextCleanupPending || !retainedPlaintextDirectories.isEmpty }
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
    var removalAlerts = 0; var lockedEditorRefreshes = 0; var attachmentMoves = 0
    var simulatePartialRemovalFailure = false
    var simulatePartialWorkingCleanup = false
    init(_ name: String, project: Project, unlocked: Bool = true) throws {
        self.project = project
        url = project.url.appendingPathComponent(name + (unlocked ? ".etp" : ".md"))
        project.notes.append(self)
        Storage.shared().noteList.append(self)
        if unlocked {
            let directory = Storage.shared().makeTempEncryptionDirectory()!
            let bundle = directory.appendingPathComponent("note.textbundle")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            decryptedTemporarySrc = bundle
        }
    }
    func presentSaveFailure() { failureAlerts += 1 }
    func presentCleanupWarning() { failureAlerts += 1 }
    func presentRemovalFailure() { removalAlerts += 1 }
    func refreshEditorsAfterRemovalLock() { lockedEditorRefreshes += 1 }
    func removeCacheForPreviewImages() { }
    func isTrash() -> Bool { false }
    func overwrite(url: URL) { self.url = url }
    func moveImages(to project: Project) { attachmentMoves += 1 }
    func removePlaintextWorkingDirectory(_ directory: URL) throws {
        if simulatePartialWorkingCleanup {
            simulatePartialWorkingCleanup = false
            try FileManager.default.removeItem(at: directory.appendingPathComponent("note.textbundle/body"))
            throw Failure.archive
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func removePlaintextSource(at source: URL) throws {
        if simulatePartialRemovalFailure {
            try FileManager.default.removeItem(at: source.appendingPathComponent("body"))
            throw Failure.archive
        }
        try FileManager.default.removeItem(at: source)
    }
    func parseURL() {}
    func isUnlocked() -> Bool { decryptedTemporarySrc != nil && !plaintextCleanupPending }
    func isEncrypted() -> Bool { container == .encryptedTextPack || isUnlocked() }
    func isEncryptedAndLocked() -> Bool { container == .encryptedTextPack && !isUnlocked() }
    func isTextBundle() -> Bool { testTextBundle }
    func loadTextBundle() -> Bool { container = .none; return true }
    func invalidateCache() {}
    func loadFileName() {}
    func loadPreviewInfo() {}
    func loadTitle() {}
    func load() {}
    func getContent() -> NSAttributedString? {
        let source: URL
        if let temporary = decryptedTemporarySrc { source = temporary.appendingPathComponent("body") }
        else { source = testTextBundle ? url.appendingPathComponent("body") : url }
        guard let body = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        return NSAttributedString(string: body)
    }
    func getFileAttributes() -> [FileAttributeKey: Any] { [:] }
    func purgeSensitiveDerivedData() { purges += 1 }
    func write(attributedString: NSAttributedString) -> Bool {
        guard !isEncryptedAndLocked() else { return false }
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
try FileManager.default.createDirectory(at: Storage.shared().root.appendingPathComponent("trash"), withIntermediateDirectories: false)
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
expect(a.encryptionSession == nil, "successful lock must discard the cached derived key")
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
let oldSession = reloaded.encryptionSession!.identifier
try Data("test-cipher:__missing_body__".utf8).write(to: reloaded.url)
expect(!reloaded.unLock(password: "test", reload: true), "reload must reject a package with missing body")
expect(reloaded.decryptedTemporarySrc == oldWorking && FileManager.default.fileExists(atPath: oldWorking.path), "failed reload must keep the old working directory")
expect(reloaded.content.string == "existing body", "failed reload must preserve existing content")
expect(reloaded.encryptionSession?.identifier == oldSession, "failed reload must preserve the original encryption session")
reloaded.lastWriteError = nil
try Data("test-cipher:external body".utf8).write(to: reloaded.url)
expect(reloaded.unLock(password: "test", reload: true), "valid external update must load")
expect(reloaded.content.string == "external body", "reload must use the fully read body")
expect(!FileManager.default.fileExists(atPath: oldWorking.path), "successful reload must retire its old working directory")
let updatedWorking = reloaded.decryptedTemporarySrc!
reloaded.lastWriteError = "unsaved edits"
expect(!reloaded.unLock(password: "test", reload: true), "reload must not overwrite unsaved changes")
expect(reloaded.decryptedTemporarySrc == updatedWorking, "refused reload must keep working state")

let upgrade = try Note("upgrade", project: project)
upgrade.content = NSMutableAttributedString(string: "legacy body")
expect(upgrade.save(), "legacy fixture must save")
let legacySession = upgrade.encryptionSession!.identifier
let upgradeWorking = upgrade.decryptedTemporarySrc!
expect(!upgrade.upgradeEncryption(password: "different password"), "upgrade must not change the existing password")
EncryptedNoteCodec.failModernSeal = true
expect(!upgrade.upgradeEncryption(password: "test-password"), "failed modern save must fail upgrade")
expect(upgrade.encryptionSession?.format == .modern, "failed upgrade must retain the requested modern format for retries")
expect(FileManager.default.fileExists(atPath: upgradeWorking.path), "failed upgrade must preserve working files")
expect(try! String(contentsOf: upgrade.url, encoding: .utf8) == "test-cipher:legacy body", "failed upgrade must preserve committed ciphertext")
expect(upgrade.save(), "upgrade save retry must succeed")
expect(upgrade.encryptionSession?.format == .modern, "successful upgrade must retain modern format")
let modernSession = upgrade.encryptionSession!.identifier
let derivations = EncryptedNoteCodec.sessionsCreated
expect(upgrade.save() && upgrade.save(), "modern edits must save")
expect(upgrade.encryptionSession?.identifier == modernSession && EncryptedNoteCodec.sessionsCreated == derivations, "edits must reuse the cached session, without deriving another key")

let partialUpgrade = try Note("post-replace-upgrade", project: project)
partialUpgrade.content = NSMutableAttributedString(string: "durable content")
expect(partialUpgrade.save(), "post-replacement fixture must save")
FileHandle.failOnSync = FileHandle.syncCount + 2
expect(!partialUpgrade.upgradeEncryption(password: "test-password"), "fsync failure after modern replacement must report failure")
expect(try! String(contentsOf: partialUpgrade.url, encoding: .utf8) == "test-modern:durable content", "fixture must fail after modern ciphertext replacement")
expect(partialUpgrade.encryptionSession?.format == .modern, "post-replacement failure must keep modern session")
expect(partialUpgrade.save(), "post-replacement retry must save")
expect(try! String(contentsOf: partialUpgrade.url, encoding: .utf8) == "test-modern:durable content", "retry must never downgrade modern ciphertext")
let unicodeUpgrade = try Note("unicode-upgrade", project: project)
unicodeUpgrade.password = "\u{00e9}"
expect(!unicodeUpgrade.upgradeEncryption(password: "e\u{0301}"), "upgrade must compare exact password bytes, not Unicode canonical equality")

let deletion = try Note("delete-failed-lock", project: project)
deletion.content = NSMutableAttributedString(string: "retain edits")
expect(deletion.save(), "delete fixture must save")
let deletionWorking = deletion.decryptedTemporarySrc!
SSZipArchive.failNextArchive = true
Storage.shared().removeNotes(notes: [deletion]) { mapping in expect(mapping == nil, "failed lock must not register trash undo") }
expect(Storage.shared().noteList.contains { $0 === deletion }, "failed delete lock must keep the note in the model")
expect(deletion.isUnlocked() && FileManager.default.fileExists(atPath: deletionWorking.path), "failed delete lock must retain working content")
expect(deletion.lockedEditorRefreshes == 0, "failed lock must keep the editing view")
Storage.shared().trashDestination = root.appendingPathComponent("missing-trash/deleted.etp")
Storage.shared().removeNotes(notes: [deletion]) { mapping in expect(mapping == nil, "failed filesystem delete must not register trash undo") }
expect(Storage.shared().noteList.contains { $0 === deletion }, "failed filesystem delete must keep the note in the model")
expect(!deletion.isUnlocked() && deletion.encryptionSession == nil, "failed filesystem delete after successful flush must leave the note locked")
expect(!FileManager.default.fileExists(atPath: deletionWorking.path), "successful pre-delete lock must purge plaintext")
expect(deletion.lockedEditorRefreshes == 1 && deletion.removalAlerts == 1, "failed delete must refresh all locked editors and report failure")
expect(deletion.attachmentMoves == 0, "failed note move must not move attachments")
Storage.shared().trashDestination = nil
let deletedOriginal = deletion.url
Storage.shared().removeNotes(notes: [deletion]) { mapping in expect(mapping?[deletion.url] == deletedOriginal, "successful trash must preserve undo mapping") }
expect(!Storage.shared().noteList.contains { $0 === deletion }, "only successful deletion may remove note from model")
expect(FileManager.default.fileExists(atPath: deletion.url.path), "successful trash must retain ciphertext")

let directDelete = try Note("direct-delete", project: project)
directDelete.content = NSMutableAttributedString(string: "direct secret")
expect(directDelete.save(), "direct delete fixture must save")
let directWorking = directDelete.decryptedTemporarySrc!
SSZipArchive.failNextArchive = true
expect(directDelete.removeFile(completely: true) == nil, "direct deletion must refuse a failed encrypted flush")
expect(FileManager.default.fileExists(atPath: directWorking.path) && FileManager.default.fileExists(atPath: directDelete.url.path), "direct failure must retain working files and ciphertext")
if case .deleted? = directDelete.removeFile(completely: true) { } else { fatalError("permanent delete must report distinct success") }
expect(!FileManager.default.fileExists(atPath: directWorking.path) && !FileManager.default.fileExists(atPath: directDelete.url.path), "successful direct deletion must remove working files and ciphertext")

let permanent = try Note("permanent", project: project, unlocked: false)
permanent.content = NSMutableAttributedString(string: "plain note")
expect(permanent.save(), "permanent fixture must save")
Storage.shared().removeNotes(notes: [permanent], completely: true) { _ in }
expect(!Storage.shared().noteList.contains { $0 === permanent }, "permanent success must remove note from model")

let externallyRemoved = try Note("external-removal", project: project)
externallyRemoved.content = NSMutableAttributedString(string: "external recovery")
expect(externallyRemoved.save(), "external removal fixture must save")
let externalWorking = externallyRemoved.decryptedTemporarySrc!
try FileManager.default.removeItem(at: externallyRemoved.url)
Storage.shared().removeNotes(notes: [externallyRemoved], fsRemove: false) { _ in }
expect(Storage.shared().noteList.contains { $0 === externallyRemoved }, "watcher must retain unlocked notes for recovery")
expect(FileManager.default.fileExists(atPath: externalWorking.path) && externallyRemoved.lastWriteError != nil, "watcher must retain working data and report missing ciphertext")

let wrongPassword = try Note("wrong-password-removed", project: project)
wrongPassword.content = NSMutableAttributedString(string: "locked body")
expect(wrongPassword.save() && wrongPassword.lock(), "locked watcher fixture must save")
wrongPassword.lastWriteError = "incorrect password"
try FileManager.default.removeItem(at: wrongPassword.url)
Storage.shared().removeNotes(notes: [wrongPassword], fsRemove: false) { _ in }
expect(!Storage.shared().noteList.contains { $0 === wrongPassword }, "a locked wrong-password error must not preserve a ghost note")

let partialCleanup = try Note("partial-working-cleanup", project: project)
partialCleanup.content = NSMutableAttributedString(string: "complete ciphertext body")
expect(partialCleanup.save(), "partial cleanup fixture must save")
let cleanupWorking = partialCleanup.decryptedTemporarySrc!
partialCleanup.simulatePartialWorkingCleanup = true
expect(!partialCleanup.lock(), "partial recursive cleanup must report failure")
let intactCiphertext = try Data(contentsOf: partialCleanup.url)
let callsAfterCommit = SSZipArchive.archiveCalls
expect(partialCleanup.hasPendingPlaintextCleanup && partialCleanup.isEncryptedAndLocked(), "partial cleanup must enter locked cleanup-only state")
expect(partialCleanup.getURL() == partialCleanup.url && partialCleanup.encryptionSession == nil && partialCleanup.content.length == 0, "partial working files must not be exposed as an unlocked note")
expect(!partialCleanup.save(content: NSMutableAttributedString(string: "must not overwrite")), "partial working copy must reject new edits")
expect(!FileManager.default.fileExists(atPath: cleanupWorking.appendingPathComponent("body").path), "fixture must really delete part of the working bundle")
expect(partialCleanup.save(), "save retry must finish cleanup only")
expect(SSZipArchive.archiveCalls == callsAfterCommit, "cleanup retry must never archive a partial bundle")
expect(try! Data(contentsOf: partialCleanup.url) == intactCiphertext, "cleanup retry must preserve the complete committed ciphertext")
expect(!partialCleanup.hasPendingPlaintextCleanup, "successful cleanup must clear pending state")

let cleanupReload = try Note("cleanup-reload", project: project)
cleanupReload.content = NSMutableAttributedString(string: "older body")
expect(cleanupReload.save(), "reload cleanup fixture must save")
let cleanupOldWorking = cleanupReload.decryptedTemporarySrc!
try Data("test-cipher:new complete body".utf8).write(to: cleanupReload.url)
cleanupReload.simulatePartialWorkingCleanup = true
expect(cleanupReload.unLock(password: "test", reload: true), "old cleanup failure must not reject a fully loaded new working copy")
expect(cleanupReload.decryptedTemporarySrc != cleanupOldWorking && cleanupReload.content.string == "new complete body", "reload must keep the new intact working copy")
expect(cleanupReload.hasPendingPlaintextCleanup && cleanupReload.isUnlocked(), "reload must track leftover old directories while retaining a usable new copy")
expect(cleanupReload.unEncryptUnlocked(), "explicit decryption must handle residual cleanup directories")
expect(!cleanupReload.hasPendingPlaintextCleanup && !cleanupReload.isEncrypted(), "explicit conversion must not leave a permanently unfinishable cleanup state")
expect(try! String(contentsOf: cleanupReload.url.appendingPathComponent("body"), encoding: .utf8) == "new complete body", "decryption must preserve the new body after failed old cleanup")

let cleanupExternal = try Note("cleanup-external-removal", project: project)
cleanupExternal.content = NSMutableAttributedString(string: "checkpoint")
expect(cleanupExternal.save(), "external cleanup fixture must save")
cleanupExternal.simulatePartialWorkingCleanup = true
expect(!cleanupExternal.lock(), "external cleanup fixture must fail cleanup")
let checkpoint = try Data(contentsOf: cleanupExternal.url)
let remainingRoot = cleanupExternal.decryptedTemporarySrc!.deletingLastPathComponent()
try FileManager.default.removeItem(at: cleanupExternal.url)
Storage.shared().removeNotes(notes: [cleanupExternal], fsRemove: false) { _ in }
expect(Storage.shared().noteList.contains { $0 === cleanupExternal }, "watcher must retain cleanup-only recovery state")
expect(!cleanupExternal.lock() && FileManager.default.fileExists(atPath: remainingRoot.path), "missing ciphertext must prevent deletion of remaining recovery files")
try checkpoint.write(to: cleanupExternal.url)
expect(cleanupExternal.lock(), "cleanup may finish once ciphertext is restored")

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
expect(try! String(contentsOf: cached.url, encoding: .utf8) == "test-modern:existing uncached body", "encryption must load the on-disk body instead of overwriting it with empty content")

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
expect(try! String(contentsOf: preservedCiphertext, encoding: .utf8) == "test-modern:irreplaceable body", "partial source deletion must never delete the committed recovery ciphertext")
expect(partialRemoval.content.string == "irreplaceable body", "partial source deletion must also retain in-memory body")
expect(partialRemoval.lastWriteError?.contains("preserved") == true, "cleanup failure must explain the preserved encrypted copy")

let newNote = try Note("brand-new", project: project, unlocked: false)
newNote.content = NSMutableAttributedString(string: "new secret")
let plaintextURL = newNote.url
expect(newNote.encrypt(password: "test"), "brand-new encrypted notes must be writable without saving plaintext first")
expect(!FileManager.default.fileExists(atPath: plaintextURL.path), "new encrypted note must never create a normal plaintext file")
print("Verified metadata-only conversion, unreadable-body preservation, independent saves, failed-save recovery, safe lock, encrypted metadata, partial folder conversion, collision refusal, encrypted creation, explicit encryption upgrade/session lifecycle, and deletion failure/recovery lifecycle.")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-encryption-check-") as temp:
    work = Path(temp)
    main = work / "main.swift"
    main.write_text(source)
    subprocess.run(["xcrun", "swift", "-module-cache-path", str(work / "module-cache"), str(main), str(work)], check=True)
