#!/usr/bin/env python3
"""Exercise production preview capabilities, revocation, safe asset lookup and no staging."""
from pathlib import Path
import subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
SWIFT = r'''
import Cocoa
import WebKit
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
final class Task: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var data = Data(); var failed = false; var finished = false
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ bytes: Data) { data.append(bytes) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { failed = true }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let configuration = LocalPreviewSecurity.configuration()
let handler = configuration.urlSchemeHandler(forURLScheme: MemoryPreview.scheme) as! MemoryPreview
let view = WKWebView(frame: .zero, configuration: configuration)
let bytes = Data("SYNTHETIC-PRIVATE-ASSET".utf8)
let snapshot = ["i/legacy image.png": bytes, "files/manual.pdf":bytes, "assets/current.png":bytes]
let html = "<img src=\"i/legacy%20image.png\"><img src=\"assets/current.png\"><img src=\"../escape.png\"><img src=\"https://example.invalid/leak\"><a href=\"files/manual.pdf\">Open</a>"
let index = MemoryPreview.create(rendered:html, assets:snapshot, attachmentURL: { URL(string:"consolinotes-memory://workspace/" + $0.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)!) }, printing:false, template:{$0})!
handler.allowedHost = index.host
func request(_ url: URL) -> Task { let task = Task(url); handler.webView(view,start:task); return task }
let page = request(index)
expect(page.finished && !page.failed,"Document unavailable")
let output = String(data:page.data,encoding:.utf8)!
expect(!output.contains("../") && !output.contains("https://") && !output.contains("legacy%20"),"Unsafe or source paths retained")
let images = try! NSRegularExpression(pattern:"<img src=\"([^\"]+)\"")
let imageMatches = images.matches(in:output,range:NSRange(output.startIndex...,in:output))
expect(imageMatches.count == 2,"Legacy/current images not supported")
for match in imageMatches {
 let path = String(output[Range(match.range(at:1),in:output)!])
 let asset = request(URL(string:path,relativeTo:index)!.absoluteURL)
 expect(asset.data == bytes && asset.finished,"Memory asset unavailable")
}
let links = try! NSRegularExpression(pattern:"consolinotes-attachment://[a-z0-9-]+")
let link = URL(string:String(output[Range(links.firstMatch(in:output,range:NSRange(output.startIndex...,in:output))!.range,in:output)!]))!
expect(MemoryPreview.attachment(link,document:index)?.path == "/files/manual.pdf","Attachment capability missing")
expect(request(index.deletingLastPathComponent().appendingPathComponent("files/manual.pdf")).failed,"Raw asset path exposed")
let other = MemoryPreview.create(rendered:"other secret",assets:[:],attachmentURL:{_ in nil},printing:false,template:{$0})!
expect(request(other).failed,"Cross-document capability accepted")
expect(request(URL(string:"consolinotes-preview://" + index.host! + "/%2e%2e/private.css")!).failed,"Traversal accepted")
expect(request(URL(string:index.absoluteString + "?other")!).failed,"Query accepted")
MemoryPreview.remove(index.deletingLastPathComponent())
expect(request(index).failed,"Revoked document still served")
expect(MemoryPreview.attachment(link,document:index) == nil,"Revoked link retained")
handler.allowedHost = other.host
expect(request(other).finished,"Unrelated document removed")
MemoryPreview.purge()
expect(request(other).failed,"Lock purge left plaintext document")
print("PASS: memory-only preview, legacy assets, opaque paths, host isolation, traversal/query rejection and revocation")
'''
with tempfile.TemporaryDirectory(prefix='consolinotes-memory-preview-') as temp:
 work=Path(temp); (work/'main.swift').write_text(SWIFT)
 subprocess.run(['swiftc','-module-cache-path',str(work/'modules'),str(ROOT/'FSNotesCore/PrivateWorkingDirectory.swift'),str(ROOT/'FSNotesCore/LocalPreviewSecurity.swift'),str(ROOT/'FSNotesCore/MemoryPreview.swift'),str(work/'main.swift'),'-o',str(work/'test')],check=True)
 subprocess.run([str(work/'test')],check=True,timeout=30)
source=(ROOT/'FSNotesCore/MemoryPreview.swift').read_text()
assert 'write(to:' not in source and 'createDirectory' not in source
