#!/usr/bin/env python3
"""Exercise the editor's production attachment resolver with synthetic local files."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
note = (ROOT / "FSNotesCore/Business/Note.swift").read_text()
start = note.index("    public func getAttachmentFileUrl(name:")
end = note.index("\n    }", start) + len("\n    }")
method = note[start:end]
source = r'''
import Foundation
struct Project { let url: URL }
final class Note {
    let project: Project; let body: URL
    var encrypted = false; var locked = false; var bundle = false
    init(root: URL, body: URL) { project = Project(url: root); self.body = body }
    func isEncrypted() -> Bool { encrypted }
    func isEncryptedAndLocked() -> Bool { locked }
    func isTextBundle() -> Bool { bundle }
    func getURL() -> URL { body }
''' + method + r'''
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let project = root.appendingPathComponent("project")
let bundle = project.appendingPathComponent("note.textbundle")
let images = project.appendingPathComponent("i")
try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
try fm.createDirectory(at: images, withIntermediateDirectories: true)
let local = project.appendingPathComponent("local.png")
let bundled = bundle.appendingPathComponent("inside.png")
let legacy = images.appendingPathComponent("legacy.png")
let outside = root.appendingPathComponent("private.png")
for url in [local, bundled, legacy, outside] { try Data("synthetic".utf8).write(to: url) }
try fm.createSymbolicLink(at: project.appendingPathComponent("escape.png"), withDestinationURL: outside)
let note = Note(root: project, body: bundle)
expect(note.getAttachmentFileUrl(name: "local.png") == local.resolvingSymlinksInPath(), "relative local image must work")
for name in ["https://example.invalid/pixel.png", "http://example.invalid/pixel.png", "//example.invalid/pixel.png", "file:///private.png", "../private.png", "%2e%2e/private.png", "escape.png", "/private.png"] {
    expect(note.getAttachmentFileUrl(name: name) == nil, "unsafe editor attachment accepted: " + name)
}
note.bundle = true
expect(note.getAttachmentFileUrl(name: "inside.png") == bundled.resolvingSymlinksInPath(), "bundle image must stay in its own root")
expect(note.getAttachmentFileUrl(name: "../local.png") == nil, "bundle traversal must be rejected")
note.encrypted = true
expect(note.getAttachmentFileUrl(name: "/i/legacy.png") == legacy.resolvingSymlinksInPath(), "legacy image must resolve within project only")
note.locked = true
expect(note.getAttachmentFileUrl(name: "inside.png") == nil, "locked note must not expose attachment files")
print("Verified editor attachments: local files, bundle containment, legacy relative paths, locked notes, remote/traversal/symlink rejection.")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-editor-attachment-check-") as temp:
    work = Path(temp)
    main = work / "main.swift"
    main.write_text(source)
    executable = work / "attachment-tests"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(work / "module-cache"), str(ROOT / "FSNotesCore/PrivateWorkingDirectory.swift"), str(ROOT / "FSNotesCore/LocalPreviewSecurity.swift"), str(main), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(work)], check=True)
