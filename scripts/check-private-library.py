#!/usr/bin/env python3
"""Synthetic private-library copy/permissions and scoped-bookmark lifecycle tests."""
from pathlib import Path
import subprocess
import tempfile
import plistlib

ROOT = Path(__file__).resolve().parents[1]
fixture = r'''
import Foundation
import AppKit
import Darwin
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
enum PrivacyLog { static func record(_ event: StaticString) {} }
enum UserDefaultsManagement {
    enum StorageType { case local, custom }
    static var configuredStorageURL: URL? { nil }
    static var trashURL: URL? { nil }
    static var shared: UserDefaults? { nil }
    static var privateLibraryURL: URL?
    static var librarySetupVersion = 0
    static var privateLibraryBackupIncluded = false
    static var hasPreviousLibraryConfiguration = false
    static var legacyDocumentsURL: URL?
    static var customStoragePath: String?
    static var storageType = StorageType.local
}
final class Note {
    var hasPendingPlaintextCleanup = false
    var lastWriteError: Error?
    func isUnlocked() -> Bool { false }
    func isEncryptedAndLocked() -> Bool { true }
}
final class Storage {
    static var instance: Storage?
    var noteList = [Note]()
    func removeCachedTree() {}
}
final class ViewController {
    static func shared() -> ViewController? { nil }
    func lockAll(_ sender: Any) {}
}
enum AppDelegate { static func relaunch() {} }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
let source = root.appendingPathComponent("original", isDirectory: true)
try fileManager.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
try Data("original note".utf8).write(to: source.appendingPathComponent("note.md"))
try Data([1, 2, 3, 4]).write(to: source.appendingPathComponent("nested/私的 % asset.bin"))
let manager = PrivateLibraryManager(directory: root.appendingPathComponent("private.noindex"))
let empty = try manager.create(backupIncluded: false)
expect(try fileManager.contentsOfDirectory(atPath: empty.path).isEmpty, "New library was not empty")
let copy = try manager.copy(source: source, backupIncluded: false)
expect(try Data(contentsOf: source.appendingPathComponent("note.md")) == Data("original note".utf8), "Migration changed source")
expect(try Data(contentsOf: copy.appendingPathComponent("nested/私的 % asset.bin")) == Data([1, 2, 3, 4]), "Migration did not preserve bytes/filenames")
let paths = [copy, copy.appendingPathComponent("nested"), copy.appendingPathComponent("note.md"), copy.appendingPathComponent("nested/私的 % asset.bin")]
for path in paths {
    let attributes = try fileManager.attributesOfItem(atPath: path.path)
    let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
    expect((attributes[.posixPermissions] as? NSNumber)?.intValue == (isDirectory ? 0o700 : 0o600), "Private copy has broad permissions")
}
try manager.setBackupIncluded(true, at: copy)
try manager.setBackupIncluded(false, at: copy)
let entriesBefore = try fileManager.contentsOfDirectory(atPath: manager.directory.path)
try fileManager.createSymbolicLink(at: source.appendingPathComponent("linked.md"), withDestinationURL: source.appendingPathComponent("note.md"))
do { _ = try manager.copy(source: source, backupIncluded: false); fatalError("Linked source accepted") } catch {}
expect(try fileManager.contentsOfDirectory(atPath: manager.directory.path) == entriesBefore, "Rejected copy left a staging directory")
expect(fileManager.fileExists(atPath: source.appendingPathComponent("note.md").path), "Rejected copy removed source")
try fileManager.removeItem(at: source.appendingPathComponent("linked.md"))
try fileManager.linkItem(at: source.appendingPathComponent("note.md"), to: source.appendingPathComponent("hardlink.md"))
do { _ = try manager.copy(source: source, backupIncluded: false); fatalError("Hardlinked source accepted") } catch {}
try fileManager.removeItem(at: source.appendingPathComponent("hardlink.md"))
do { _ = try manager.copy(source: root, backupIncluded: false); fatalError("Recursive copy into source accepted") } catch {}
expect(fileManager.fileExists(atPath: source.appendingPathComponent("note.md").path), "Original library did not survive failed copy")
print("PASS: verified private copy preserves originals, names and bytes; owner-only permissions; rejects unsafe/recursive source")

let folder = root.appendingPathComponent("folder")
let library = root.appendingPathComponent("library")
let trash = root.appendingPathComponent("trash")
let auxiliary = root.appendingPathComponent("old-style.css")
let database = root.appendingPathComponent("Bookmarks-v2.json")
let initial = [
    SandboxBookmark.Record(url: folder, data: Data("folder".utf8), roles: [.folder]),
    SandboxBookmark.Record(url: library, data: Data("library".utf8), roles: [.library]),
    SandboxBookmark.Record(url: trash, data: Data("trash".utf8), roles: [.trash]),
    SandboxBookmark.Record(url: auxiliary, data: Data("auxiliary".utf8), roles: [.auxiliary])
]
try JSONEncoder().encode(initial).write(to: database)
var configuration = [SandboxBookmark.Role: URL]()
var started = [URL](), stopped = [URL](), refreshed = [URL]()
var staleFolder = false
let scope = SandboxBookmark.Scope(resolve: { data in
    let value = String(data: data, encoding: .utf8)!
    if value.hasPrefix("/") { return (URL(fileURLWithPath: value), false) }
    return (root.appendingPathComponent(value == "auxiliary" ? "old-style.css" : value), value == "folder" && staleFolder)
}, create: { url in refreshed.append(url); return Data(url.path.utf8) },
start: { url in started.append(url); return true }, stop: { url in stopped.append(url) })
let bookmarks = SandboxBookmark(database: database, scope: scope, configured: { configuration })
bookmarks.load(); bookmarks.load(); _ = bookmarks.attachedFolderURLs(); _ = bookmarks.getRestoredUrls()
expect(started == [folder], "Unused library/trash/style bookmarks activated or repeated load duplicated scope")
configuration[.library] = library
bookmarks.load(); bookmarks.load()
expect(started.count == 2 && started.last == library, "Configured library lease missing or duplicated")
expect(bookmarks.authorize(url: library, role: .folder), "Could not add overlapping folder role")
bookmarks.removeBy(library)
expect(!stopped.contains(library), "Detaching folder revoked an active default-library role")
configuration.removeValue(forKey: .library)
bookmarks.load()
expect(stopped == [library], "Changing configured library did not release old scope")
bookmarks.removeBy(folder)
expect(stopped == [library, folder], "Detaching folder failed to release scope")
expect(bookmarks.attachedFolderURLs().isEmpty, "Detached folder remained active")
bookmarks.releaseAll(); bookmarks.releaseAll()
expect(stopped.count == started.count, "Repeated release caused unbalanced stop")

// Stale active bookmarks refresh under a live scope and persist the new bytes.
staleFolder = true
try JSONEncoder().encode([initial[0]]).write(to: database)
let stale = SandboxBookmark(database: database, scope: scope, configured: { [:] })
stale.load(); stale.load()
expect(refreshed.contains(folder), "Stale bookmark was not refreshed")
let saved = try JSONDecoder().decode([SandboxBookmark.Record].self, from: Data(contentsOf: database))
expect(saved[0].data == Data(folder.path.utf8), "Refreshed bookmark was not saved")
stale.releaseAll()
expect(started.count == stopped.count, "Stale refresh unbalanced its lease")

// A failed durable grant rolls back both the record and any acquired lease.
let unavailable = SandboxBookmark(database: root.appendingPathComponent("missing/Bookmarks.json"), scope: scope, configured: { [:] })
expect(!unavailable.authorize(url: folder, role: .folder), "Unwritable bookmark store accepted grant")
expect(started.count == stopped.count, "Failed grant leaked its scope")
expect(unavailable.attachedFolderURLs().isEmpty, "Failed grant retained configured folder")
// A failed detach must leave both the visible selection and its lease intact.
let detachDatabase = root.appendingPathComponent("detach.json")
let detaching = SandboxBookmark(database: detachDatabase, scope: scope, configured: { [:] })
expect(detaching.authorize(url: folder, role: .folder), "Could not create detach fixture")
try fileManager.removeItem(at: detachDatabase)
try fileManager.createDirectory(at: detachDatabase, withIntermediateDirectories: false)
let stoppedBeforeDetach = stopped.count
expect(!detaching.removeFolders([folder]), "Failed detach claimed success")
expect(stopped.count == stoppedBeforeDetach && detaching.attachedFolderURLs() == [folder], "Failed detach revoked live access")
detaching.releaseAll()
expect(started.count == stopped.count, "Failed detach leaked a scope")
try Data("malformed".utf8).write(to: database)
let malformed = SandboxBookmark(database: database, scope: scope, configured: { configuration })
let before = started.count
malformed.load()
expect(started.count == before, "Malformed database opened scopes")
print("PASS: configured scopes only; idempotent load; detach and role overlap; stale refresh; failed grant rollback; balanced release")
'''
# Swift autoclosures cannot throw: evaluate throwing expressions at the call site.
fixture = fixture.replace('func expect(_ condition: @autoclosure () -> Bool,', 'func expect(_ condition: @autoclosure () throws -> Bool,').replace('    if !condition() {', '    if !(try! condition()) {')
with tempfile.TemporaryDirectory(prefix='consolinotes-private-library-') as temporary:
    work = Path(temporary)
    (work / 'main.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'),
                    str(ROOT / 'FSNotesCore/PrivateWorkingDirectory.swift'),
                    str(ROOT / 'FSNotesCore/PrivateLibraryManager.swift'),
                    str(ROOT / 'FSNotes/Helpers/SandboxBookmark.swift'),
                    str(ROOT / 'FSNotes/PrivateLibraryController.swift'),
                    str(work / 'main.swift'), '-o', str(work / 'test')], check=True)
    fixture_dir = work / 'fixtures'; fixture_dir.mkdir()
    subprocess.run([str(work / 'test'), str(fixture_dir)], check=True, timeout=30)
entitlements = plistlib.loads((ROOT / 'FSNotes/FSNotes.entitlements').read_bytes())
assert 'com.apple.security.temporary-exception.files.home-relative-path.read-write' not in entitlements
assert entitlements['com.apple.security.files.bookmarks.app-scope'] is True
preferences = (ROOT / 'FSNotesCore/UserDefaultsManagement.swift').read_text()
assert 'prepareConsolinotesDocuments' not in preferences
assert 'isWritableFile(atPath: storagePath)' not in preferences
assert 'static var storagePath: String? { configuredStorageURL?.path }' in preferences
print('PASS: no Documents exception, automatic move, or inaccessible-library fallback')
