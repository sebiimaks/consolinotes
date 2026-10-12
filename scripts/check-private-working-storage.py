#!/usr/bin/env python3
"""Exercise private working storage, archive filtering and memory-only thumbnails.

Only synthetic files are read. The archive policy uses the built ZipArchive
library; thumbnail tests compile the production rendering methods and NSImage
extensions, with a minimal note-state stub.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DERIVED = ROOT / "build/DerivedData"
ARCHIVE = DERIVED / "Build/Products/Release/ZipArchive.o"
MODULES = DERIVED / "Build/Intermediates.noindex/GeneratedModuleMaps"


def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


ATTACHMENT = (ROOT / "FSNotesCore/Business/NoteAttachment.swift").read_text()
CELL = (ROOT / "FSNotes/View/NoteCellView.swift").read_text()
FIXTURE = r'''
import Cocoa
import AVKit
import ZipArchive

typealias PlatformImage = NSImage
typealias Image = NSImage
extension URL { var isVideo: Bool { pathExtension == "mp4" } }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func expectFailure(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError(message) } catch { }
}
func excludedFromBackup(_ directory: URL) throws -> Bool {
    // On this macOS SDK NSURLIsExcludedFromBackupKey can read back false even
    // after a successful exclusion. Ask Time Machine for the effective policy.
    let command = Process()
    let output = Pipe()
    command.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    command.arguments = ["isexcluded", directory.path]
    command.standardOutput = output
    try command.run()
    command.waitUntilExit()
    return command.terminationStatus == 0 && String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("[Excluded]") == true
}
final class Note {
    var locked = false
    func isEncryptedAndLocked() -> Bool { locked }
    var memory = [URL: Data]()
    func memoryAttachmentData(for url: URL) -> Data? { locked ? nil : memory[url] }
}
final class NoteCellView {
''' + method(CELL, "    public func getPreviewImage(") + r'''
}
final class NoteAttachment {
''' + "\n".join(method(ATTACHMENT, signature) for signature in [
    "    public static func getImage(",
    "    private static func loadImage(",
    "    private static func generateVideoThumbnail(",
]) + r'''
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let temporary = root.appendingPathComponent("working", isDirectory: true)
try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
let legacy = temporary.appendingPathComponent("Encryption", isDirectory: true)
try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
let recovery = legacy.appendingPathComponent("unsaved-body")
try Data("recover me".utf8).write(to: recovery)
let working = try PrivateWorkingDirectory.makeEncryptionDirectory(in: temporary)
expect(working.deletingLastPathComponent().pathExtension == "noindex", "Working root must suppress indexing")
expect(try! excludedFromBackup(working), "Working copies must be excluded from backup")
expect(try! Data(contentsOf: recovery) == Data("recover me".utf8), "Legacy crash recovery must be preserved")
let bundle = working.appendingPathComponent("note.textbundle", isDirectory: true)
try fm.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
let body = bundle.appendingPathComponent("text.md")
try Data("private body".utf8).write(to: body)
try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: body.path)
try PrivateWorkingDirectory.protectTree(bundle)
for directory in [working, working.deletingLastPathComponent(), bundle] {
    expect((try! fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber).intValue == 0o700, "Private directory permissions must be 0700")
}
expect((try! fm.attributesOfItem(atPath: body.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "Working files must be 0600")

let outside = root.appendingPathComponent("outside.txt")
try Data("outside".utf8).write(to: outside)
try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
let link = bundle.appendingPathComponent("link")
try fm.createSymbolicLink(at: link, withDestinationURL: outside)
expectFailure("Symbolic links must not be followed") { try PrivateWorkingDirectory.protectTree(bundle) }
expect((try! fm.attributesOfItem(atPath: outside.path)[.posixPermissions] as! NSNumber).intValue == 0o644, "Protection followed a symlink outside the working directory")
try fm.removeItem(at: link)
try fm.linkItem(at: outside, to: link)
expectFailure("Hardlinks must not change external-file permissions") { try PrivateWorkingDirectory.protectTree(bundle) }
try fm.removeItem(at: link)
let unsafe = root.appendingPathComponent("unsafe")
try fm.createDirectory(at: unsafe, withIntermediateDirectories: false)
try fm.createSymbolicLink(at: unsafe.appendingPathComponent("ConsolinotesEncryption.noindex"), withDestinationURL: temporary)
expectFailure("Working roots must not follow preexisting symlinks") { _ = try PrivateWorkingDirectory.makeEncryptionDirectory(in: unsafe) }

let extracted = working.appendingPathComponent("extracted")
expect(PrivateNoteArchive.extract(root.appendingPathComponent("valid.zip"), to: extracted), "Valid note archive refused")
try PrivateWorkingDirectory.protectTree(extracted)
expect(try! String(contentsOf: extracted.appendingPathComponent("text.md"), encoding: .utf8) == "archive body", "Archive contents changed")
expect(!PrivateNoteArchive.extract(root.appendingPathComponent("valid.zip"), to: extracted), "Extraction must not overwrite an existing working copy")
for name in ["symlink", "special"] {
    let destination = working.appendingPathComponent(name)
    expect(!PrivateNoteArchive.extract(root.appendingPathComponent(name + ".zip"), to: destination), "Link/special-file archive accepted")
    expect(!fm.fileExists(atPath: destination.appendingPathComponent("forbidden").path), "Forbidden archive entry was written before rejection")
}
let traversal = working.appendingPathComponent("traversal")
expect(!PrivateNoteArchive.extract(root.appendingPathComponent("traversal.zip"), to: traversal), "Traversal must be refused")
expect(!fm.fileExists(atPath: traversal.path), "Rejected archive left partial plaintext")
expect(try! String(contentsOf: outside, encoding: .utf8) == "outside", "Archive escaped its working directory")
for name in ["oversize", "zip64", "deep", "duplicate", "implicit", "badcrc"] {
    let destination = working.appendingPathComponent(name)
    expect(!PrivateNoteArchive.extract(root.appendingPathComponent(name + ".zip"), to: destination,
        limits: .init(bytes: 32, entries: 4, depth: 3)), "Archive budget/corruption guard missed " + name)
    expect(!fm.fileExists(atPath: destination.path), "Rejected archive left files: " + name)
}
var checks = 0
let cancelled = working.appendingPathComponent("cancelled")
expect(!PrivateNoteArchive.extract(root.appendingPathComponent("cancel.zip"), to: cancelled, isCancelled: {
    checks += 1
    return checks >= 5
}), "Mid-stream cancellation ignored")
expect(!fm.fileExists(atPath: cancelled.path), "Cancellation left partial output")
let generation = PrivateNoteArchive.cancellationCheck()
expect(!generation(), "New operation already cancelled")
PrivateNoteArchive.cancelOperations()
expect(generation(), "Operation generation not cancelled")
let bounded = working.appendingPathComponent("bounded")
try Data(repeating: 1, count: 65).write(to: bounded)
expectFailure("Bounded read accepted oversize file") { _ = try PrivateWorkingDirectory.readBoundedFile(bounded, maximumBytes: 64) }
expect(try! PrivateWorkingDirectory.readBoundedFile(bounded, maximumBytes: 65).count == 65, "Exact bounded read failed")
expectFailure("Bounded read ignored cancellation") { _ = try PrivateWorkingDirectory.readBoundedFile(bounded, maximumBytes: 65, isCancelled: { true }) }
expectFailure("Bounded read followed symlink") { _ = try PrivateWorkingDirectory.readBoundedFile(unsafe.appendingPathComponent("ConsolinotesEncryption.noindex"), maximumBytes: 65) }
let oversized = working.appendingPathComponent("oversized")
try fm.createDirectory(at: oversized, withIntermediateDirectories: false)
let sparse = oversized.appendingPathComponent("large.dat")
fm.createFile(atPath: sparse.path, contents: nil)
let sparseHandle = try FileHandle(forWritingTo: sparse)
try sparseHandle.truncate(atOffset: PrivateNoteArchive.maximumExpandedBytes + 1)
try sparseHandle.close()
expectFailure("New saves must refuse source content exceeding reopen limits") { try PrivateNoteArchive.validateSourceDirectory(oversized) }

let image = root.appendingPathComponent("image.png")
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR9kAAAAASUVORK5CYII=")!
try png.write(to: image)
let note = Note()
expect(NoteAttachment.getImage(url: image, size: CGSize(width: 70, height: 70)) != nil, "Editor attachment render failed")
expect(NoteCellView().getPreviewImage(imageUrl: image, note: note) != nil, "Sidebar thumbnail render failed")
let opaque = URL(string: "consolinotes-memory://fixture/assets/image.png")!
note.memory[opaque] = png
expect(NoteCellView().getPreviewImage(imageUrl: opaque, note: note) != nil, "Memory-only sidebar thumbnail render failed")
note.locked = true
expect(NoteCellView().getPreviewImage(imageUrl: opaque, note: note) == nil, "Locked memory attachment rendered")
expect(NoteCellView().getPreviewImage(imageUrl: image, note: note) == nil, "Locked note rendered a thumbnail")
for name in ["MainNotesList", "Preview", "ThumbnailsBig"] {
    expect(!fm.fileExists(atPath: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name).path), "Thumbnail cache was written to disk")
}
print("PASS: no-index/backup exclusions, owner-only working files, recovery preservation, archive link/size guards, save/reopen limits, traversal containment and memory-only image previews")
'''


def main():
    if not ARCHIVE.exists():
        raise SystemExit("Build the local Release app once to provide pinned ZipArchive.")
    with tempfile.TemporaryDirectory(prefix="consolinotes-private-storage-") as temporary:
        work = Path(temporary)
        for name, mode, body in [("valid", 0o100600, b"archive body"), ("symlink", 0o120777, b"../outside.txt"), ("special", 0o010600, b"")]:
            with zipfile.ZipFile(work / (name + ".zip"), "w") as archive:
                info = zipfile.ZipInfo("text.md" if name == "valid" else "forbidden")
                info.create_system = 3
                info.external_attr = mode << 16
                archive.writestr(info, body)
        with zipfile.ZipFile(work / "traversal.zip", "w") as archive:
            archive.writestr("../../outside.txt", "sanitized")
        for name, entries in {
            "oversize": [("a", b"first"), ("b", b"X" * 64)],
            "deep": [("a/b/c/d/e", b"data")],
            "duplicate": [("a", b"first"), ("a", b"second")],
            "implicit": [("a/b/c", b"x"), ("d/e/f", b"x")],
            "badcrc": [("a", b"first")],
            "cancel": [("large", b"X" * 200_000)],
        }.items():
            with zipfile.ZipFile(work / (name + ".zip"), "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for path, payload in entries: archive.writestr(path, payload)
        broken = bytearray((work / "badcrc.zip").read_bytes())
        central = broken.index(b"PK\x01\x02")
        broken[central + 16] ^= 0xff
        (work / "badcrc.zip").write_bytes(broken)
        # A genuine ZIP64-size member with forged small compressed input.
        import struct
        with zipfile.ZipFile(work / "zip64.zip", "w") as archive:
            info = zipfile.ZipInfo("large")
            info.extra = struct.pack("<HHQQ", 1, 16, 0x100000000, 1)
            archive.writestr(info, b"x")
        oversized = bytearray((work / "zip64.zip").read_bytes())
        central = oversized.index(b"PK\x01\x02")
        oversized[central + 24:central + 28] = struct.pack("<I", 0xffffffff)
        (work / "zip64.zip").write_bytes(oversized)
        source = work / "main.swift"
        source.write_text(FIXTURE)
        executable = work / "check-private-storage"
        subprocess.run([
            "swiftc", "-module-cache-path", str(work / "modules"),
            "-Xcc", "-fmodule-map-file=" + str(MODULES / "ZipArchive.modulemap"),
            "-import-objc-header", str(ROOT / "FSNotesCore/PrivateNoteArchiveBridge.h"),
            str(ROOT / "FSNotesCore/PrivateWorkingDirectory.swift"),
            str(ROOT / "FSNotesCore/PrivateNoteArchive.swift"),
            str(ROOT / "FSNotes/Extensions/NSImage+.swift"), str(source), str(ARCHIVE),
            "-lz", "-liconv", "-framework", "Security", "-o", str(executable)
        ], check=True)
        isolated_temp = work / "app-temporary"
        isolated_temp.mkdir()
        subprocess.run([str(executable), str(work)], env={**os.environ, "TMPDIR": str(isolated_temp)}, check=True)


if __name__ == "__main__":
    main()
