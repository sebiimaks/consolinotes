#!/usr/bin/env python3
"""Use the production packaging method and attributed Markdown serializer.

Synthetic notes with escaped filenames are encrypted, moved into a clean
library, decrypted and checked without any access to the original assets.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / "build/DerivedData/Build/Products/Release"
MODULES = ROOT / "build/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps"
def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]
note = (ROOT / "FSNotesCore/Business/Note.swift").read_text()
serialization = (ROOT / "FSNotesCore/Extensions/NSMutableAttributedString+.swift").read_text()
SOURCE = r'''
import AppKit
import ZipArchive
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
struct Project { let storage: Int; let url: URL }
enum Container { case textBundleV2 }
struct NoteType {
 var uti: String { "net.daringfireball.markdown" }
 func getExtension(for container: Container) -> String { "md" }
}
extension NSMutableAttributedString {
''' + "\n".join(method(serialization, signature) for signature in [
    "    convenience init(url:", "    public func getMeta(", "    public func unloadImagesAndFiles(",
    "    public func unloadTasks(", "    public func unloadAttachments(",
]) + r'''
}
final class Note {
    enum PersistenceError: Error { case invalidBundle }
    let project: Project
    let url: URL
    var content = NSMutableAttributedString(string: "")
    var type = NoteType()
    var originalExtension: String?
    init(name: String, project: Project, type: Int, cont: Container) {
        self.project = project; self.url = project.url.appendingPathComponent(name + ".textbundle")
    }
    func write(attributedString: NSAttributedString) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{\"version\":2,\"type\":\"net.daringfireball.markdown\"}".utf8).write(to: url.appendingPathComponent("info.json"))
            try Data(attributedString.string.utf8).write(to: url.appendingPathComponent("text.md"))
            return true
        } catch { return false }
    }
    func loadTextBundle() -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("info.json").path) }
    func getContent() -> String? { try? String(contentsOf: url.appendingPathComponent("text.md"), encoding: .utf8) }
    func isTextBundle() -> Bool { false }
    func package() throws -> MemoryNoteWorkspace { try makeMemoryEncryptionWorkspace() }
''' + method(note, "    private func makeMemoryEncryptionWorkspace(") + r'''
}
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let original = root.appendingPathComponent("original")
let imageRoot = original.appendingPathComponent("i")
let clean = root.appendingPathComponent("clean")
try fm.createDirectory(at: imageRoot, withIntermediateDirectories: true)
try fm.createDirectory(at: clean, withIntermediateDirectories: true)
let note = Note(name: "original", project: Project(storage: 0, url: original), type: 0, cont: .textBundleV2)
// Exercise a task before images: serialization changes its length before image replacement.
let task = NSMutableAttributedString(attachment: NSTextAttachment())
task.addAttribute(.todo, value: 1, range: NSRange(location: 0, length: 1))
note.content.append(task)
note.content.append(NSAttributedString(string: " completed\n"))
var expected = Set<String>()
for name in ["ordinary.png", "private image.png", "100%private.png", "私的.png"] {
    let url = imageRoot.appendingPathComponent(name)
    try Data(name.utf8).write(to: url)
    expected.insert(name)
    note.content.append(NSMutableAttributedString(url: url, title: "fixture", path: "i/" + name))
    note.content.append(NSAttributedString(string: "\n"))
}
let repeated = imageRoot.appendingPathComponent("private image.png")
note.content.append(NSMutableAttributedString(url: repeated, title: "repeated", path: "i/private image.png"))
let bundle = try note.package()
let body = String(data: bundle.body, encoding: .utf8)!
expect(body.hasPrefix("- [x] completed"), "Task serialization broke packaging")
expect(!body.contains("](i/"), "Packaged note retained a shared plaintext attachment")
expect(bundle.attachments.count == 4, "Repeated attachment was not deduplicated")
expect(!fm.fileExists(atPath: note.url.path), "Memory packaging wrote a plaintext bundle")
let bytes = try MemoryNoteArchive.encode(bundle.entries)
let encrypted = try EncryptedNoteCodec.seal(bytes, session: EncryptedNoteCodec.makeSession(password: "synthetic password"))
let moved = clean.appendingPathComponent("moved.etp")
try encrypted.write(to: moved)
try fm.removeItem(at: original)
let opened = try EncryptedNoteCodec.open(Data(contentsOf: moved), password: "synthetic password")
let restored = try MemoryNoteWorkspace(entries: MemoryNoteArchive.decode(opened.data))
let restoredBody = String(data: restored.body, encoding: .utf8)!
let regex = try NSRegularExpression(pattern: #"\]\((assets/[^)]+)\)"#)
let matches = regex.matches(in: restoredBody, range: NSRange(location: 0, length: (restoredBody as NSString).length))
expect(matches.count == 5, "A packaged attachment reference disappeared")
var found = Set<String>()
for match in matches {
    let reference = (restoredBody as NSString).substring(with: match.range(at: 1)).removingPercentEncoding!
    let payload = String(data: restored.entries[reference]!, encoding: .utf8)!
    found.insert(payload)
}
expect(found == expected, "Moved encrypted note depends on plaintext originals")
print("PASS: production attributed serializer and packaging, spaces/percent/Unicode, preceding task, repeated attachments, real encryption and clean-library reopen after originals removed")
'''
with tempfile.TemporaryDirectory(prefix="consolinotes-encrypted-attachments-") as temporary:
    work = Path(temporary)
    source = work / "main.swift"
    source.write_text(SOURCE)
    executable = work / "test"
    subprocess.run(["swiftc", "-module-cache-path", str(work / "modules"), "-I", str(PRODUCTS),
        "-Xcc", "-fmodule-map-file=" + str(MODULES / "ZipArchive.modulemap"),
        "-import-objc-header", str(ROOT / "FSNotesCore/PrivateNoteArchiveBridge.h"),
        *[str(ROOT / "FSNotesCore" / file) for file in ["PrivateWorkingDirectory.swift", "PrivateNoteArchive.swift", "EncryptedNoteCodec.swift", "MemoryNoteArchive.swift", "MemoryNoteWorkspace.swift", "Extensions/NSAttributedStringKey+.swift"]],
        str(source), str(PRODUCTS / "ZipArchive.o"), str(PRODUCTS / "RNCryptor.o"),
        "-lz", "-liconv", "-framework", "Security", "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(work)], check=True)
