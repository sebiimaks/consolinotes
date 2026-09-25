#!/usr/bin/env python3
"""Exercise production folder insertion in an isolated, Foundation-only Swift harness.

Project scanning and note loading are stubbed: this checks folder acceptance,
deduplication and parent relationships without reading or modifying user notes.
"""

from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def extract_method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


def harness(source):
    methods = "\n\n".join(extract_method(source, signature) for signature in (
        "    public func insert(url:",
        "    public func insertProject(project:",
        "    func projectExist(url:",
        "    public func getProjectBy(url:",
        "    public func loadProjectRelations()",
    ))
    return r'''
import Foundation

final class Settings {
    var priority = 0
}

final class Project {
    let url: URL
    var label: String { url.lastPathComponent }
    var parent: Project?
    var child = [Project]()
    var isTrash = false
    let settings = Settings()
    var noteLoads = [Bool]()

    init(storage: Storage, url: URL, isBookmark: Bool = false) {
        self.url = url.standardized
    }

    func getProjectsFSAndMemoryDiff() -> ([Project], [Project]) { ([], []) }

    func loadNotes(cacheOnly: Bool) -> [String] {
        noteLoads.append(cacheOnly)
        return []
    }
}

final class Storage {
    private let projectsLock = NSRecursiveLock()
    var projects = [Project]()
''' + methods + r'''
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let storage = Storage()
let rootURL = URL(fileURLWithPath:
    "/Users/folder-check/Library/Containers/io.github.sebiimaks.consolinotes/Data/Documents",
    isDirectory: true)
let root = Project(storage: storage, url: rootURL)
storage.insertProject(project: root)

func add(_ name: String, to parent: Project, cacheOnly: Bool = false) -> Project {
    let url = parent.url.appendingPathComponent(name, isDirectory: true)
    guard let inserted = storage.insert(url: url, cacheOnly: cacheOnly),
          inserted.count == 1, let project = inserted.first else {
        fputs("FAIL: folder was rejected: \(url.path)\n", stderr)
        exit(1)
    }
    expect(storage.getProjectBy(url: url) === project, "inserted project must be in storage")
    expect(project.parent === parent, "parent must be assigned before insertion returns")
    expect(parent.child.filter { $0 === project }.count == 1, "parent must contain one child")
    expect(project.noteLoads == [cacheOnly], "new project must load notes once")
    return project
}

let folder = add("New folder", to: root)
_ = add("Nested folder", to: folder)
_ = add("Research.github", to: root)
_ = add("docs.git-notes", to: root)
_ = add("Cached folder", to: root, cacheOnly: true)

let count = storage.projects.count
let rootChildCount = root.child.count
expect(storage.insert(url: folder.url) == nil, "duplicate insertion must return nil")
let equivalentURL = URL(fileURLWithPath: folder.url.path + "/./", isDirectory: true)
expect(storage.insert(url: equivalentURL) == nil, "equivalent paths must be deduplicated")
expect(storage.projects.count == count, "duplicate insertion must not add projects")
expect(root.child.count == rootChildCount, "duplicate insertion must not add child rows")
expect(folder.noteLoads.count == 1, "duplicate insertion must not reload notes")

for relativePath in [".git", ".git/objects", "New folder/.git/refs", ".github/workflows"] {
    let url = rootURL.appendingPathComponent(relativePath, isDirectory: true)
    expect(storage.insert(url: url) == nil, "metadata folder must stay excluded: \(relativePath)")
}
expect(storage.projects.count == count, "excluded folders must not add projects")

print("Verified folder insertion: sandbox paths, nested folders, dotted names, duplicates and Git metadata.")
'''


def run(source):
    with tempfile.TemporaryDirectory(prefix="consolinotes-folder-check-") as directory:
        work = Path(directory)
        swift = work / "main.swift"
        swift.write_text(harness(source))
        subprocess.run([
            "xcrun", "swift", "-module-cache-path", str(work / "module-cache"), str(swift)
        ], check=True)


if __name__ == "__main__":
    try:
        run((ROOT / "FSNotesCore/Business/Storage.swift").read_text())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Folder insertion check failed: {error}", file=sys.stderr)
        sys.exit(1)
