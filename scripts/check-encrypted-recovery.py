#!/usr/bin/env python3
"""Exercise production crash inventory and encrypted recovery using synthetic files."""
from pathlib import Path
import os
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / "build/DerivedData/Build/Products/Release"
MODULES = ROOT / "build/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps"
SOURCE = r'''
import Foundation
import Darwin
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let workingRoot = root.appendingPathComponent("ConsolinotesEncryption.noindex", isDirectory: true)
let journalRoot = root.appendingPathComponent("encrypted-journals")
if CommandLine.arguments.last == "encrypted-crash" {
    let journal = try EncryptedNoteJournal(root: journalRoot)
    let entries = ["info.json": Data(#"{"version":2,"type":"net.daringfireball.markdown"}"#.utf8), "text.md": Data("crash-only secret marker".utf8)]
    let archive = try MemoryNoteArchive.encode(entries)
    try journal.write(EncryptedNoteCodec.seal(archive, session: EncryptedNoteCodec.makeSession(password: "journal secret")))
    _exit(0)
}
if CommandLine.arguments.last == "crash" {
    let directory = try PrivateWorkingDirectory.makeEncryptionDirectory(in: root)
    try EncryptedNoteRecovery.register(directory)
    let bundle = directory.appendingPathComponent("note.textbundle", isDirectory: true)
    try fm.createDirectory(at: bundle, withIntermediateDirectories: false)
    try Data("{\"version\":2,\"type\":\"net.daringfireball.markdown\"}".utf8).write(to: bundle.appendingPathComponent("info.json"))
    try Data("unsaved edits after interrupted encryption".utf8).write(to: bundle.appendingPathComponent("text.md"))
    try PrivateWorkingDirectory.protectTree(bundle)
    // Abrupt exit releases OS file locks; no application cleanup runs.
    _exit(0)
}
let active = try PrivateWorkingDirectory.makeEncryptionDirectory(in: root)
try EncryptedNoteRecovery.register(active)
expect(EncryptedNoteRecovery.interrupted(roots: [workingRoot]).isEmpty, "Live session reported as interrupted")
let worker = Process()
worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
worker.arguments = [root.path, "crash"]
try worker.run()
worker.waitUntilExit()
expect(worker.terminationStatus == 0, "Crash fixture failed")
var entries = EncryptedNoteRecovery.interrupted(roots: [workingRoot])
expect(entries.count == 1, "Interrupted session missing from inventory")
let entry = entries[0]
let original = entry.bundle!.appendingPathComponent("text.md")
let originalBytes = try Data(contentsOf: original)
expect(EncryptedNoteRecovery.interrupted(roots: [workingRoot]).isEmpty, "Recovery claim can be acquired concurrently")
let blocked = root.appendingPathComponent("blocked.etp")
try Data("existing ciphertext".utf8).write(to: blocked)
do { try EncryptedNoteRecovery.restore(entry, password: "synthetic password", to: blocked); fatalError("Recovery overwrote existing note") } catch { }
expect(try! Data(contentsOf: blocked) == Data("existing ciphertext".utf8), "Existing note changed")
expect(try! Data(contentsOf: original) == originalBytes, "Failed recovery lost edits")
let restored = root.appendingPathComponent("restored.etp")
try EncryptedNoteRecovery.restore(entry, password: "synthetic password", to: restored)
expect(try! Data(contentsOf: original) == originalBytes, "Restore deleted before explicit resolution")
let ciphertext = try PrivateWorkingDirectory.readBoundedFile(restored, maximumBytes: PrivateNoteArchive.maximumCiphertextBytes)
let opened = try EncryptedNoteCodec.open(ciphertext, password: "synthetic password")
let archive = root.appendingPathComponent("verify.zip")
try opened.data.write(to: archive)
let bundle = root.appendingPathComponent("verify.textbundle")
expect(PrivateNoteArchive.extract(archive, to: bundle), "Recovered encrypted archive cannot reopen")
expect(try! Data(contentsOf: bundle.appendingPathComponent("text.md")) == originalBytes, "Recovered contents changed")
expect((try! fm.attributesOfItem(atPath: restored.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "Recovery ciphertext permissions too broad")
try EncryptedNoteRecovery.remove(entry.directory)
expect(!fm.fileExists(atPath: entry.directory.path), "Resolved plaintext remains")
try EncryptedNoteRecovery.remove(active)
expect(EncryptedNoteRecovery.interrupted(roots: [workingRoot]).isEmpty, "Resolved entries remain in inventory")
let unknown = try PrivateWorkingDirectory.makeEncryptionDirectory(in: root)
try Data("incomplete but important".utf8).write(to: unknown.appendingPathComponent("partial"))
let incomplete = EncryptedNoteRecovery.interrupted(roots: [workingRoot])
expect(incomplete.count == 1 && incomplete[0].bundle == nil, "Incomplete legacy recovery disappeared")
let encryptedWorker = Process()
encryptedWorker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
encryptedWorker.arguments = [root.path, "encrypted-crash"]
try encryptedWorker.run(); encryptedWorker.waitUntilExit()
expect(encryptedWorker.terminationStatus == 0, "Encrypted crash fixture failed")
let journals = EncryptedNoteJournal.interrupted(root: journalRoot)
expect(journals.count == 1, "Encrypted crash journal not inventoried")
expect(EncryptedNoteJournal.interrupted(root: journalRoot).isEmpty, "Encrypted recovery claim acquired concurrently")
for case let file as URL in fm.enumerator(at: journalRoot, includingPropertiesForKeys: [.isRegularFileKey])! {
    if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
        expect(try! Data(contentsOf: file).range(of: Data("crash-only secret marker".utf8)) == nil, "Plaintext crash journal written")
        expect((try! fm.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "Journal file permissions too broad")
    }
}
let encryptedRestored = root.appendingPathComponent("encrypted-restored.etp")
do { try EncryptedNoteJournal.restore(journals[0], password: "wrong", to: encryptedRestored); fatalError("Wrong password restored encrypted journal") } catch {}
try EncryptedNoteJournal.restore(journals[0], password: "journal secret", to: encryptedRestored)
let recoveredBytes = try EncryptedNoteCodec.open(Data(contentsOf: encryptedRestored), password: "journal secret").data
expect(try! MemoryNoteArchive.decode(recoveredBytes)["text.md"] == Data("crash-only secret marker".utf8), "Encrypted crash recovery changed body")
do { try EncryptedNoteJournal.restore(journals[0], password: "journal secret", to: encryptedRestored); fatalError("Encrypted recovery overwrote destination") } catch {}
expect(fm.fileExists(atPath: journals[0].directory.path), "Recovery deleted journal before explicit discard")
try EncryptedNoteJournal.discard(journals[0])
print("PASS: legacy and encrypted-only abrupt-exit recovery, authenticated restore, live-session exclusion, exclusive claims, no-overwrite preservation, memory archive round trip and private modes")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-recovery-") as temporary:
    work = Path(temporary)
    source = work / "main.swift"
    source.write_text(SOURCE)
    executable = work / "check-recovery"
    subprocess.run(["swiftc", "-module-cache-path", str(work / "modules"), "-I", str(PRODUCTS),
        "-Xcc", "-fmodule-map-file=" + str(MODULES / "ZipArchive.modulemap"),
        "-import-objc-header", str(ROOT / "FSNotesCore/PrivateNoteArchiveBridge.h"),
        *[str(ROOT / "FSNotesCore" / file) for file in ["PrivateWorkingDirectory.swift", "PrivateNoteArchive.swift", "EncryptedNoteCodec.swift", "EncryptedNoteRecovery.swift", "MemoryNoteArchive.swift", "MemoryNoteWorkspace.swift", "EncryptedNoteJournal.swift"]],
        str(source), str(PRODUCTS / "ZipArchive.o"), str(PRODUCTS / "RNCryptor.o"),
        "-lz", "-liconv", "-framework", "Security", "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(work)], check=True)
