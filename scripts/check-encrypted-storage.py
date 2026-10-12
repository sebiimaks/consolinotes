#!/usr/bin/env python3
"""Run real memory-only encrypted Note lifecycle against synthetic files.

Extracts production Note methods; UI/metadata dependencies alone are doubles.
Archive, memory workspace, authenticated crypto, journal and atomic I/O are real.
The only injected backend dependency is the journal root inside the fixture.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / 'build/DerivedData/Build/Products/Release'
MODULES = ROOT / 'build/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps'
def method(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }', start) + len('\n    }')]
note = (ROOT / 'FSNotesCore/Business/Note.swift').read_text()
methods = '\n'.join(method(note, signature) for signature in [
 '    public var isPrivacyShielded: Bool', '    public var hasMemoryWorkspace: Bool',
 '    public func isEncrypted()', '    public func isEncryptedAndLocked()', '    public func isUnlocked()',
 '    public func save(attributed:', '    public func save(content:', '    public func save()',
 '    private func write(attributedString:', '    public func getURL()', '    func getContent()',
 '    private func writeEncrypted()', '    private func commitEncrypted(', '    public func lock()',
 '    public func unLock(password:', '    public func unEncryptUnlocked()', '    public func upgradeEncryption(password:',
 '    public func cleanOut()', '    public func verifyAndRevealRetainedContent(',
 '    public func verifyEncryptionPassword(', '    public func rotateEncryptionSecret(',
 '    public func memoryAttachmentData(', '    public func memoryAttachmentSnapshot()',
 '    public func removeMemoryAttachment(', '    public func exportMemoryBundle(',
 '    public func encrypt(password:', '    private func makeMemoryEncryptionWorkspace(',
 '    private func removePlaintextSource(',
]).replace('EncryptedNoteJournal()', 'EncryptedNoteJournal(root: testJournalRoot)')
SOURCE = r'''
import AppKit
import ZipArchive
import RNCryptor
var testJournalRoot: URL!
var failLibrarySyncAfter: Int?
var testLibraryRoot: URL!
func injectedFsync(_ descriptor: Int32) -> Int32 {
 var actual = stat()
 var target = stat()
 if let remaining = failLibrarySyncAfter, fstat(descriptor, &actual) == 0,
    stat(testLibraryRoot.path, &target) == 0,
    actual.st_dev == target.st_dev, actual.st_ino == target.st_ino {
  if remaining == 0 { failLibrarySyncAfter = nil; errno = EIO; return -1 }
  failLibrarySyncAfter = remaining - 1
 }
 return Darwin.fsync(descriptor)
}
func expect(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
enum Container { case none, encryptedTextPack, textBundleV2 }
struct NoteType {
 var uti: String { "net.daringfireball.markdown" }
 static func withUTI(rawValue: String) -> NoteType { NoteType() }
 func getExtension(for: Container) -> String { "md" }
}
enum UserDefaultsManagement { static let useTextBundleMetaToStoreDates = false }
enum PrivacyLog { static func record(_ value: StaticString) {} }
final class Storage { static let instance = Storage(); static func shared() -> Storage { instance }; func add(_ n: Note) {} }
final class Project { let url: URL; init(_ url: URL) { self.url = url }; func removeCache() {} }
extension URL { var isImage: Bool { false }; var isVideo: Bool { false } }
var onLoad: (() -> Void)?
extension NSAttributedString {
 func loadAttachments(_ note: Note) -> NSMutableAttributedString { onLoad?(); return NSMutableAttributedString(attributedString: self) }
}
extension NSMutableAttributedString {
 func unloadAttachments() -> NSMutableAttributedString { self }
 func getImagesAndFiles() -> [(url: URL, title: String, path: String)] { [] }
 func getMeta(at: Int) -> (url: URL, title: String, path: String)? { nil }
}
final class Note {
 enum PersistenceError: Error { case invalidBundle, missingPassword, destinationExists }
 let project: Project
 var url: URL
 var memoryWorkspace: MemoryNoteWorkspace?
 var encryptionSession: EncryptedNoteCodec.Session?
 var encryptedJournal: EncryptedNoteJournal?
 private var privacyShielded = false
 var password: String?
 var lastWriteError: String?
 var container = Container.encryptedTextPack
 var type = NoteType()
 var content = NSMutableAttributedString(string: "")
 var isLoaded = false; var isBlocked = false; var isParsed = false
 var modifiedLocalAt = Date(); var creationDate: Date?; var originalExtension: String?
 var tags = [String](); var title = ""; var preview = ""; var cacheHash: Int?
 var selectedRange: NSRange?; var imageUrl: [URL]?; var attachments: [URL]?
 let writeLock = NSRecursiveLock(); let undoManager = UndoManager()
 init(url: URL, with project: Project) { self.url = url; self.project = project }
 func isTextBundle() -> Bool { container == .textBundleV2 }
 func getFileAttributes() -> [FileAttributeKey: Any] { [:] }
 func getFileWrapper(attributedString: NSAttributedString) -> FileWrapper { FileWrapper(regularFileWithContents: Data(attributedString.string.utf8)) }
 func getContentFileURL() -> URL? { isEncrypted() ? nil : url }
 func getContentSaveURL() -> URL { url }
 func writeTextBundleInfo(url: URL) { fatalError("Unexpected plaintext metadata write") }
 func presentSaveFailure() {}
 func invalidateCache() { title = ""; preview = "" }
 func loadFileName() {}; func loadTitle() { title = isPrivacyShielded ? "" : content.string }
 func loadPreviewInfo() { preview = isPrivacyShielded ? "" : content.string }
 func loadTags() {}; func load() {}; func parseURL() {}; func purgeSensitiveDerivedData() {}
''' + methods + r'''
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let library = root.appendingPathComponent("library")
try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
testJournalRoot = root.appendingPathComponent("journal")
testLibraryRoot = library
let project = Project(library)
let secret = "synthetic-old-password"
let marker = "PRIVATE BODY marker 65473"
let metadata = Data(#"{"version":2,"type":"net.daringfireball.markdown"}"#.utf8)
let entries = ["info.json": metadata, "text.md": Data(marker.utf8), "assets/private image.png": Data("PRIVATE ATTACHMENT marker 98765".utf8)]
let archive = try MemoryNoteArchive.encode(entries)
func makeNote(_ name: String, legacy: Bool = false) throws -> Note {
 let note = Note(url: library.appendingPathComponent(name + ".etp"), with: project)
 let bytes = legacy ? RNCryptor.encrypt(data: archive, withPassword: secret) : try EncryptedNoteCodec.seal(archive, session: EncryptedNoteCodec.makeSession(password: secret))
 try EncryptedNoteJournal.atomicWrite(bytes, to: note.url, replacing: false)
 return note
}
let first = try makeNote("first")
expect(!first.unLock(password: "wrong"), "Wrong password unlocked")
expect(first.unLock(password: secret), "Memory unlock failed")
expect(first.getURL() == first.url && first.memoryWorkspace != nil, "Unlock exposed a working filesystem URL")
let attachment = first.memoryWorkspace!.url(for: "assets/private image.png")!
expect(attachment.scheme == "consolinotes-memory" && first.memoryAttachmentData(for: attachment) == entries["assets/private image.png"], "Memory attachment inaccessible")
// The editor's image loader runs off-main. Its memory getter must serialize
// against the same workspace lock used by publication/removal.
let getterDone = DispatchSemaphore(value: 0)
first.writeLock.lock()
DispatchQueue.global().async { _ = first.memoryAttachmentData(for: attachment); getterDone.signal() }
expect(getterDone.wait(timeout: .now() + 0.05) == .timedOut, "Memory getter bypassed the workspace lock")
first.writeLock.unlock()
expect(getterDone.wait(timeout: .now() + 2) == .success, "Memory getter did not resume after mutation lock")
let second = try makeNote("second")
expect(second.unLock(password: secret), "Second unlock failed")
expect(second.memoryAttachmentData(for: attachment) == nil, "Cross-note attachment leaked")
expect(first.verifyEncryptionPassword(secret) && !first.verifyEncryptionPassword("wrong"), "Pure password authentication failed")
expect(first.content.string == marker, "Verification altered current content")
first.content = NSMutableAttributedString(string: "edited " + marker)
expect(first.save(), "Encrypted edit failed")
expect(first.lock() && !first.isUnlocked() && first.content.length == 0 && first.password == nil, "Successful lock retained plaintext")
expect(first.unLock(password: secret) && first.content.string == "edited " + marker, "Saved edit failed reopen")
// Saving to a missing parent fails after the protected recovery snapshot is durable.
let original = first.url
first.url = library.appendingPathComponent("missing/first.etp")
first.content = NSMutableAttributedString(string: "unsaved " + marker)
first.isPrivacyShielded = true
expect(!first.lock() && first.isUnlocked() && first.isPrivacyShielded, "Failed lock discarded or revealed edits")
expect(first.memoryAttachmentData(for: attachment) == nil, "Shield exposed an attachment")
expect(!first.unLock(password: secret, reload: true), "Watcher revealed retained content")
expect(!first.save(content: NSMutableAttributedString(string: "replacement")), "Public edit overwrote shielded content")
expect(!first.unLock(password: "wrong") && first.isPrivacyShielded, "Wrong password revealed shield")
expect(first.unLock(password: secret) && first.content.string == "unsaved " + marker, "Authenticated reveal lost unsaved content")
expect(EncryptedNoteJournal.interrupted(root: testJournalRoot).isEmpty, "Live journal offered for recovery")
first.encryptedJournal = nil
let recovery = EncryptedNoteJournal.interrupted(root: testJournalRoot)
expect(recovery.count == 1, "Failed save did not retain encrypted recovery")
let recoveredURL = library.appendingPathComponent("recovered.etp")
do { try EncryptedNoteJournal.restore(recovery[0], password: "wrong", to: recoveredURL); fatalError("Wrong password recovered journal") } catch {}
expect(!FileManager.default.fileExists(atPath: recoveredURL.path), "Failed recovery wrote a file")
try EncryptedNoteJournal.restore(recovery[0], password: secret, to: recoveredURL)
let recovered = Note(url: recoveredURL, with: project)
expect(recovered.unLock(password: secret) && recovered.content.string == "unsaved " + marker, "Encrypted recovery lost edits")
try EncryptedNoteJournal.discard(recovery[0])
first.url = original
expect(first.lock(), "Retry lock failed")
// Cancellation inside the attachment loader must not publish decrypted state.
let cancelled = try makeNote("cancelled")
onLoad = { PrivateNoteArchive.cancelOperations() }
expect(!cancelled.unLock(password: secret) && !cancelled.isUnlocked() && cancelled.content.length == 0, "Late cancellation restored plaintext")
onLoad = nil
// Retain legacy files and explicitly upgrade without materialization.
let legacy = try makeNote("legacy", legacy: true)
expect(legacy.unLock(password: secret) && legacy.encryptionSession?.format == .legacy, "Legacy memory unlock failed")
expect(legacy.save() && legacy.upgradeEncryption(password: secret), "Legacy upgrade failed")
expect(legacy.encryptionSession?.format == .modern, "Upgrade did not adopt modern format")
// Verified rotation, cancellation, fresh disk authentication and rollback.
expect(second.rotateEncryptionSecret(to: "high-entropy-fixture-secret"), "Rotation failed")
expect(!second.verifyEncryptionPassword(secret) && second.verifyEncryptionPassword("high-entropy-fixture-secret"), "Rotation left stale password valid")
expect(!second.rotateEncryptionSecret(to: "cancelled-secret", isCancelled: { true }), "Cancelled rotation succeeded")
expect(second.verifyEncryptionPassword("high-entropy-fixture-secret"), "Cancelled rotation damaged original")
// Cancel after a durable candidate journal exists, immediately before any
// publication. The current note keeps its old authenticated secret.
expect(!second.rotateEncryptionSecret(to: "cancel-after-candidate", isCancelled: {
 guard let files = FileManager.default.enumerator(at: testJournalRoot, includingPropertiesForKeys: nil) else { return false }
 return files.allObjects.compactMap { $0 as? URL }.contains { $0.lastPathComponent == "note.etp" }
}), "Late candidate cancellation published new secret")
expect(second.verifyEncryptionPassword("high-entropy-fixture-secret") && second.password == "high-entropy-fixture-secret", "Pre-publication cancellation changed password state")
expect(EncryptedNoteJournal.interrupted(root: testJournalRoot).isEmpty, "Cancelled candidate left orphan recovery")
// Inject the directory fsync error AFTER the candidate rename. The verified
// new secret remains active, and a durable journal makes it recoverable even
// if a power loss reverts the original directory entry to old ciphertext.
failLibrarySyncAfter = 1 // old-secret checkpoint succeeds; new publication fails
expect(second.rotateEncryptionSecret(to: "durable-recovery-fixture"), "Published rotation falsely reported old password")
expect(failLibrarySyncAfter == nil && second.lastWriteError != nil, "Post-publication durability failure was not injected/reported")
expect(second.verifyEncryptionPassword("durable-recovery-fixture"), "Published rotation did not adopt new secret")
second.encryptedJournal = nil
let rotationRecovery = EncryptedNoteJournal.interrupted(root: testJournalRoot)
expect(rotationRecovery.count == 1, "Durability uncertainty discarded candidate recovery")
let rotationRecovered = library.appendingPathComponent("rotation-recovered.etp")
try EncryptedNoteJournal.restore(rotationRecovery[0], password: "durable-recovery-fixture", to: rotationRecovered)
let recoveredRotation = Note(url: rotationRecovered, with: project)
expect(recoveredRotation.unLock(password: "durable-recovery-fixture") && recoveredRotation.content.string == marker, "Candidate recovery lost content")
try EncryptedNoteJournal.discard(rotationRecovery[0])
expect(second.save() && second.lastWriteError == nil, "Durability retry did not finish saving")
// Fresh encrypted creation must never first save an unprotected note.
let fresh = Note(url: library.appendingPathComponent("fresh.md"), with: project)
fresh.container = .none; fresh.content = NSMutableAttributedString(string: marker)
expect(fresh.encrypt(password: secret), "Fresh encryption failed")
expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("fresh.md").path), "Fresh encryption wrote plaintext source")
expect(fresh.unLock(password: secret) && fresh.content.string == marker, "Fresh note lost in-memory body")
// All routine output files are ciphertext or empty lock files, never ZIP/body/attachment bytes.
for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
 if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
  let bytes = try Data(contentsOf: url)
  expect(bytes.range(of: Data(marker.utf8)) == nil && bytes.range(of: Data("PRIVATE ATTACHMENT marker 98765".utf8)) == nil, "Plaintext found on disk")
  expect(url.pathExtension == "etp" || url.lastPathComponent == ".lock", "Unexpected working file")
 }
}
// Plaintext can be materialized only by an explicit export/conversion action.
let exported = library.appendingPathComponent("explicit-export.textbundle")
expect(fresh.exportMemoryBundle(to: exported), "Explicit memory bundle export failed")
expect(try! String(contentsOf: exported.appendingPathComponent("text.md"), encoding: .utf8) == marker, "Explicit export changed body")
expect(!fresh.exportMemoryBundle(to: exported), "Explicit export overwrote existing data")
expect(fresh.unEncryptUnlocked(), "Explicit plaintext conversion failed")
expect(fresh.password == nil && fresh.memoryWorkspace == nil && !FileManager.default.fileExists(atPath: library.appendingPathComponent("fresh.etp").path), "Conversion retained encrypted session or duplicate source")
print("PASS: actual Note memory unlock/edit/lock, encrypted recovery, failure shield, cross-note attachments, legacy compatibility, late cancellation, verified rotation, fresh ciphertext-only creation, no plaintext filesystem output")
'''
with tempfile.TemporaryDirectory(prefix='consolinotes-memory-storage-') as temporary:
    work = Path(temporary); source = work / 'main.swift'; source.write_text(SOURCE)
    executable = work / 'test'; fixture = work / 'fixture'; fixture.mkdir()
    # Replace only the external fsync dependency in a production-source copy.
    # Darwin's imported syscall otherwise takes precedence over a Swift double.
    journal = work / 'EncryptedNoteJournal.swift'
    journal.write_text((ROOT / 'FSNotesCore/EncryptedNoteJournal.swift').read_text().replace('fsync(', 'injectedFsync('))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'modules'), '-I', str(PRODUCTS),
        '-Xcc', ' -fmodule-map-file='.strip() + str(MODULES / 'ZipArchive.modulemap'),
        '-import-objc-header', str(ROOT / 'FSNotesCore/PrivateNoteArchiveBridge.h'),
        *[str(journal if f == 'EncryptedNoteJournal.swift' else ROOT / 'FSNotesCore' / f) for f in ['PrivateWorkingDirectory.swift', 'PrivateNoteArchive.swift', 'MemoryNoteArchive.swift', 'MemoryNoteWorkspace.swift', 'EncryptedNoteCodec.swift', 'EncryptedNoteJournal.swift', 'Extensions/NSAttributedStringKey+.swift']],
        str(source), str(PRODUCTS / 'ZipArchive.o'), str(PRODUCTS / 'RNCryptor.o'), '-lz', '-liconv', '-framework', 'Security', '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(fixture)], check=True)
