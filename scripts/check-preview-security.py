#!/usr/bin/env python3
"""Compile and exercise production renderer/path checks using synthetic files only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DERIVED = ROOT / "build/DerivedData"
CMARK = DERIVED / "Build/Products/Release/libcmark_gfm.o"
MODULES = DERIVED / "Build/Intermediates.noindex/GeneratedModuleMaps"

FIXTURE = r'''
import Foundation
import WebKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func excludedFromBackup(_ directory: URL) throws -> Bool {
    let command = Process()
    let output = Pipe()
    command.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    command.arguments = ["isexcluded", directory.path]
    command.standardOutput = output
    try command.run()
    command.waitUntilExit()
    return command.terminationStatus == 0 && String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("[Excluded]") == true
}
let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("consolinotes-security-fixture-" + UUID().uuidString)
let notes = fixture.appendingPathComponent("notes")
try fm.createDirectory(at: notes, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixture); LocalPreviewSecurity.purge() }
let abandoned = fixture.appendingPathComponent("ConsolinotesPreview-2147483647-" + UUID().uuidString)
let active = fixture.appendingPathComponent("ConsolinotesPreview-\(getpid())-" + UUID().uuidString)
let unrelated = fixture.appendingPathComponent("Encryption")
for url in [abandoned, active, unrelated] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
let symbolic = fixture.appendingPathComponent("ConsolinotesPreview-2147483647-" + UUID().uuidString)
try fm.createSymbolicLink(at: symbolic, withDestinationURL: unrelated)
LocalPreviewSecurity.removeAbandonedStaging(in: fixture)
expect(!fm.fileExists(atPath: abandoned.path), "Dead process staging survived cleanup")
expect(fm.fileExists(atPath: active.path), "Active process staging removed")
expect(fm.fileExists(atPath: symbolic.path), "Symlink removed by cache cleanup")
expect(fm.fileExists(atPath: unrelated.path), "Encryption recovery directory removed")
let stage = try LocalPreviewSecurity.makeDirectory()
let secondStage = try LocalPreviewSecurity.makeDirectory()
expect(stage != secondStage, "Every document needs isolated staging")
let permission = try fm.attributesOfItem(atPath: stage.path)[.posixPermissions] as? NSNumber
expect(permission?.intValue == 0o700, "Preview staging must be private")
expect(stage.pathExtension == "noindex", "Preview staging must exclude Spotlight indexing")
expect(try! excludedFromBackup(stage), "Preview staging must be excluded from backup")

let html = renderMarkdownHTML(markdown: "# Fixture\n\n<script>window.auditMarker=1</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert%281%29)\n\n{{TOC}}\n\n```js\n<script>inert code</script>\n{{TOC}}\n```\n\n- [ ] task\n\n| A | B |\n|---|---|\n| a | b |\n")!
expect(!html.contains("<script>"), "Raw scripts survived renderer")
expect(!html.contains("onerror="), "Raw event handler survived renderer")
expect(!html.contains("href=\"javascript:"), "Dangerous link survived renderer")
expect(html.contains("&lt;script&gt;inert code&lt;/script&gt;"), "Code must stay escaped and visible")
expect(html.contains("<div id=\"toc\"></div>"), "TOC placeholder lost")
expect(html.contains("{{TOC}}"), "Literal TOC in fenced code changed")
expect(html.contains("type=\"checkbox\""), "Task list rendering regressed")
expect(html.contains("<table>"), "Table rendering regressed")
expect(renderMarkdownHTML(markdown: String(repeating: "x", count: LocalPreviewSecurity.maximumMarkdownBytes + 1))!.contains("preview limit"), "Large input must be bounded")
expect(replaceHorizontalRulesOutsideCodeBlocks(in: "before\n---\nafter").contains("***"), "Safe horizontal rule conversion failed")

let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR9kAAAAASUVORK5CYII=")!
let local = notes.appendingPathComponent("image.png")
try png.write(to: local)
let outside = fixture.appendingPathComponent("private.png")
try png.write(to: outside)
try fm.createSymbolicLink(at: notes.appendingPathComponent("escape.png"), withDestinationURL: outside)
expect(LocalPreviewSecurity.attachmentURL("image.png", root: notes) == local.resolvingSymlinksInPath(), "Valid image rejected")
for path in ["../private.png", "%2e%2e/private.png", "/private.png", "escape.png", "https://example.invalid/image.png", "//example.invalid/image.png", "file:///private.png", "a\\b.png"] {
    expect(LocalPreviewSecurity.attachmentURL(path, root: notes) == nil, "Unsafe path accepted: " + path)
}
let remote = "<img src=\"https://example.invalid/tracker.png\" alt=\"tracker\" />"
let resources = LocalPreviewSecurity.localResources(in: "<img src=\"image.png\" alt=\"ok\" />" + remote + "<img src=\"../private.png\" />" + "<img src=\"escape.png\" />", root: notes, directory: stage, interactive: true)
expect(!resources.contains("https://"), "Remote resource retained")
expect(!resources.contains("../"), "Traversal path retained")
expect(!resources.contains("src=\"image.png\""), "Staged filenames must be opaque")
expect(resources.contains("fsnotes-preview"), "Valid image disappeared")
expect((try? Data(contentsOf: outside)) == png, "Outside fixture was modified")
let assets = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
expect(assets.count == 1, "Only one validated image should be copied")
expect((try? Data(contentsOf: assets[0])) == png, "Image copy changed content")

let document = notes.appendingPathComponent("manual.pdf")
try Data("synthetic attachment".utf8).write(to: document)
let links = LocalPreviewSecurity.localResources(in: "<a href=\"manual.pdf\">manual</a><a href=\"../private.png\">private</a><a href=\"https://example.invalid\">site</a>", root: notes, directory: stage, interactive: true)
expect(links.contains("consolinotes-attachment://"), "Validated attachment link missing")
expect(!links.contains("../private.png"), "Unsafe file link retained")
expect(links.contains("https://example.invalid"), "Explicit external link lost")
let jsonString = LocalPreviewSecurity.javaScriptString("'\\\n\u{2028}</script>")
let roundtrip = try JSONSerialization.jsonObject(with: Data(("[" + jsonString + "]").utf8)) as! [String]
expect(roundtrip.first == "'\\\n\u{2028}</script>", "JavaScript argument encoding failed")
expect(LocalPreviewSecurity.escapeHTML("</title><script>\"&") == "&lt;/title&gt;&lt;script&gt;&quot;&amp;", "Title escaping failed")
expect(!LocalPreviewSecurity.configuration().websiteDataStore.isPersistent, "WebKit storage must be nonpersistent")
LocalPreviewSecurity.purge()
expect(!fm.fileExists(atPath: stage.path) && !fm.fileExists(atPath: secondStage.path), "Staged plaintext survived purge")
expect(fm.fileExists(atPath: outside.path), "Purge removed unrelated data")
print("PASS: safe renderer, TOC/code/tasks/tables, size bound, local assets, traversal/symlink rejection, opaque copies, title/JS escaping, ephemeral WebKit storage, scoped purge")
'''

def main():
    if not CMARK.exists():
        raise SystemExit("Build the local Release app once to provide the pinned cmark object.")
    with tempfile.TemporaryDirectory(prefix="consolinotes-preview-test-") as temporary:
        directory = Path(temporary)
        source = directory / "main.swift"
        source.write_text(FIXTURE)
        executable = directory / "preview-tests"
        subprocess.run([
            "swiftc", "-module-cache-path", str(directory / "modules"),
            "-Xcc", "-fmodule-map-file=" + str(MODULES / "libcmark_gfm.modulemap"),
            str(ROOT / "FSNotesCore/PrivateWorkingDirectory.swift"),
            str(ROOT / "FSNotesCore/LocalPreviewSecurity.swift"), str(ROOT / "FSNotesCore/Business/Markdown.swift"),
            str(source), str(CMARK), "-o", str(executable)
        ], check=True, cwd=ROOT)
        subprocess.run([str(executable)], check=True)

if __name__ == "__main__":
    main()
