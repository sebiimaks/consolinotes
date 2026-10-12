#!/usr/bin/env python3
"""Regression for library selection before storyboard storage and FSEvents startup.

Uses only synthetic libraries and in-memory configuration. Production storage
properties are embedded in lightweight AppKit object doubles; the copy manager
and file watcher are compiled unmodified and exercise actual filesystem events.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
storyboard = ET.parse(ROOT / "FSNotes/Base.lproj/Main.storyboard")
application_scene = next(scene for scene in storyboard.findall(".//scene")
                         if scene.find("./objects/application") is not None)
early_classes = {item.attrib.get("customClass") for item in
                 application_scene.findall("./objects/customObject")}
holders = {}
for path in (ROOT / "FSNotes").rglob("*.swift"):
    source = path.read_text()
    match = re.search(r"^ {4}(?:public )?(?:let|var) storage\b[^\n]*", source, re.M)
    if match and "Storage.shared()" in match.group():
        holders[path.stem] = match.group().strip()
assert {"EditTextView", "ViewController", "SidebarCellView", "SidebarOutlineView"} <= early_classes
assert early_classes.intersection(holders), "No launch-time storage property was exercised"

declarations = "\n".join(
    f"final class {name}: NSObject {{ {declaration} }}"
    for name, declaration in sorted(holders.items())
)
instantiation = "\n".join(f"let holder{index} = {name}()" for index, name in enumerate(sorted(holders)))
inspection = "\n".join(
    f'expect(holder{index}.storage.root == selected, "{name} kept a pre-migration root")'
    for index, name in enumerate(sorted(holders))
)
storage_source = (ROOT / "FSNotesCore/Business/Storage.swift").read_text()
cache_start = storage_source.index("    public func getCachedTree()")
cache_end = storage_source.index("\n    public func removeCachedTree()", cache_start)
cache_method = storage_source[cache_start:cache_end]

fixture = r'''
import AppKit
import CoreServices
import Darwin

func expect(_ value: @autoclosure () throws -> Bool, _ message: String) {
    if !(try! value()) { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
enum PrivacyLog { static func record(_ event: StaticString) {} }
enum UserDefaultsManagement { static var storageUrl: URL? }
final class Project { let url: URL; init(_ url: URL) { self.url = url } }
final class SandboxBookmark {
    static let instance = SandboxBookmark()
    static var active = [URL]()
    static func sharedInstance() -> SandboxBookmark { instance }
    func attachedFolderURLs() -> [URL] { Self.active }
}
final class Storage {
    static var instance: Storage?
    static var constructionCount = 0
    static var cacheDirectory: URL?
    let root: URL?
    init() { Self.constructionCount += 1; root = UserDefaultsManagement.storageUrl }
    static func shared() -> Storage {
        if let instance = instance { return instance }
        let value = Storage(); instance = value; return value
    }
    func getProjectPaths() -> [String] { root.map { [$0.path] } ?? [] }
    func getDefault() -> Project? { root.map { Project($0) } }
    func getDefaultTrash() -> Project? { root.map { Project($0.appendingPathComponent("Trash")) } }
    func getCacheDir() -> URL? { Self.cacheDirectory }
''' + cache_method + '\n}\n' + declarations + r'''

let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
let manager = PrivateLibraryManager(directory: fixtureRoot.appendingPathComponent("Application Support/Libraries.noindex"))
let source = fixtureRoot.appendingPathComponent("Existing library 私的 %", isDirectory: true)
try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
let original = Data("Synthetic original library; no user content".utf8)
try original.write(to: source.appendingPathComponent("note.md"))
Storage.cacheDirectory = fixtureRoot.appendingPathComponent("Caches", isDirectory: true)
try fileManager.createDirectory(at: Storage.cacheDirectory!, withIntermediateDirectories: true)
let attached = fixtureRoot.appendingPathComponent("Attached", isDirectory: true)
let detached = fixtureRoot.appendingPathComponent("Detached", isDirectory: true)
try fileManager.createDirectory(at: attached.appendingPathComponent("nested"), withIntermediateDirectories: true)
try fileManager.createDirectory(at: detached.appendingPathComponent("nested"), withIntermediateDirectories: true)

for hadPreviousRoot in [false, true] {
    for includeBackups in [false, true] {
        Storage.instance = nil
        Storage.constructionCount = 0
        UserDefaultsManagement.storageUrl = hadPreviousRoot ? source : nil
        // These objects are constructed by the application menu scene before
        // applicationDidFinishLaunching can present library selection.
''' + instantiation + r'''
        expect(Storage.instance == nil && Storage.constructionCount == 0,
               "Storyboard-facing UI opened storage before library selection")
        let selected = try manager.copy(source: source, backupIncluded: includeBackups)
        UserDefaultsManagement.storageUrl = selected
        expect(try Data(contentsOf: source.appendingPathComponent("note.md")) == original,
               "Copy changed the original library")
        expect(try Data(contentsOf: selected.appendingPathComponent("note.md")) == original,
               "Copied note differs")
        let excluded = try selected.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        expect(excluded == !includeBackups,
               "Chosen backup behavior was not applied (include=\(includeBackups), excluded=\(String(describing: excluded)))")
''' + inspection + r'''
        expect(Storage.constructionCount == 1, "UI holders did not share the selected storage")
        let nested = selected.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        let escaped = selected.appendingPathComponent("escaped", isDirectory: true)
        try fileManager.createSymbolicLink(at: escaped, withDestinationURL: source)
        let adjacent = URL(fileURLWithPath: selected.path + "-other", isDirectory: true)
        let entries = [source, source.appendingPathComponent("old subfolder"), nested,
                       adjacent, escaped, attached, attached.appendingPathComponent("nested"),
                       detached.appendingPathComponent("nested"), URL(string: "https://example.invalid/cache")!]
        let cache = try NSKeyedArchiver.archivedData(withRootObject: entries, requiringSecureCoding: true)
        try cache.write(to: Storage.cacheDirectory!.appendingPathComponent("sidebarTree"))
        SandboxBookmark.active = [attached]
        let allowed = Set([nested, attached, attached.appendingPathComponent("nested")])
        expect(Set(Storage.shared().getCachedTree() ?? []) == allowed,
               "Cache revived old/detached/outside roots or discarded current attached folders")
        SandboxBookmark.active = []
        expect(Storage.shared().getCachedTree() == [nested], "Detached folder survived the cache scope filter")
        let paths = Storage.shared().getProjectPaths()
        expect(paths == [selected.path], "Watcher roots are empty or still point at original library")
        let watcher = FileWatcher(paths)
        let incoming = selected.appendingPathComponent("external change.md")
        var observedChange = false
        watcher.callback = { event in
            if URL(fileURLWithPath: event.path).resolvingSymlinksInPath() == incoming.resolvingSymlinksInPath() {
                observedChange = true
            }
        }
        _ = watcher.start()
        try Data("Synthetic external note".utf8).write(to: incoming)
        let deadline = Date().addingTimeInterval(8)
        while !observedChange && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        watcher.stop()
        expect(observedChange, "Selected library watcher did not receive actual filesystem change")
        expect(!fileManager.fileExists(atPath: source.appendingPathComponent("external change.md").path),
               "External change was written to the old library")
    }
}
print("PASS: eager UI initialization defers storage until selection; first-run/existing libraries copy with both backup choices; stale cache roots and escaping symlinks rejected; actual FSEvents observe the selected library")
'''

with tempfile.TemporaryDirectory(prefix="consolinotes-launch-storage-") as temporary:
    work = Path(temporary)
    (work / "main.swift").write_text(fixture)
    # FileWatcherEvent depends on the app's bridging-header CoreServices import.
    (work / "FileWatcherEvent.swift").write_text(
        "import CoreServices\n" + (ROOT / "FSNotes/Helpers/FileWatcherEvent.swift").read_text())
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(work / "modules"),
                    str(ROOT / "FSNotesCore/PrivateLibraryManager.swift"),
                    str(ROOT / "FSNotes/Helpers/FileWatcher.swift"),
                    str(work / "FileWatcherEvent.swift"), str(work / "main.swift"),
                    "-o", str(work / "test")], check=True)
    fixture_dir = work / "fixtures"
    fixture_dir.mkdir()
    subprocess.run([str(work / "test"), str(fixture_dir)], check=True, timeout=45)
