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
expect(PrivateNoteArchive.extract(root.appendingPathComponent("traversal.zip"), to: traversal), "Pinned library must sanitize traversal paths")
expect(try! String(contentsOf: outside, encoding: .utf8) == "outside", "Archive escaped its working directory")
expect(try! String(contentsOf: traversal.appendingPathComponent("outside.txt"), encoding: .utf8) == "sanitized", "Traversal path was not sanitized within destination")
var info = unz_file_info()
info.size_filename = 7
info.uncompressed_size = UInt32(PrivateNoteArchive.maximumExpandedBytes + 1)
expect(!PrivateNoteArchive().zipArchiveShouldUnzipFile(at: 0, totalFiles: 1, archivePath: "fixture", fileInfo: info), "Oversized expansion accepted")
info.uncompressed_size = 1
expect(!PrivateNoteArchive().zipArchiveShouldUnzipFile(at: 0, totalFiles: PrivateNoteArchive.maximumEntries + 1, archivePath: "fixture", fileInfo: info), "Excessive member count accepted")
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
note.locked = true
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
        source = work / "main.swift"
        source.write_text(FIXTURE)
        executable = work / "check-private-storage"
        subprocess.run([
            "swiftc", "-module-cache-path", str(work / "modules"),
            "-Xcc", "-fmodule-map-file=" + str(MODULES / "ZipArchive.modulemap"),
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
