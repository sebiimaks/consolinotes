#!/usr/bin/env python3
"""Exercise the actual local template in WebKit against a synthetic loopback sink."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
SWIFT = r'''
import Cocoa
import WebKit

final class Audit: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var view: WKWebView!
    let index: URL
    var finished = false
    init(index: URL) { self.index = index; super.init() }
    func start() {
        let configuration = LocalPreviewSecurity.configuration()
        if #available(macOS 11.0, *) {
            configuration.userContentController.add(self, contentWorld: .defaultClient, name: "auditBridge")
        }
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        LocalPreviewSecurity.prepare(view) { ready in
            guard ready else { self.fail("Offline resource rules did not compile"); return }
            self.view.loadFileURL(self.index, allowingReadAccessTo: self.index.deletingLastPathComponent())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if !self.finished { self.fail("Timed out loading WebKit fixture") } }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { fail("Page reached an isolated native bridge") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            webView.evaluateJavaScript("""
            JSON.stringify({trusted: window.auditTrusted === true, untrusted: window.auditUntrusted === true,
                bridgeHidden: !(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.auditBridge),
                toc: !!document.querySelector('#toc a'), highlighted: !!document.querySelector('code.hljs'),
                diagram: !!document.querySelector('svg'), math: !!document.querySelector('mjx-container'),
                fetchBlocked: window.auditFetchBlocked === true})
            """) { result, error in
                guard error == nil, let string = result as? String, let data = string.data(using: .utf8),
                      let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool] else { self.fail("Unable to inspect fixture"); return }
                let expected = ["trusted": true, "untrusted": CommandLine.arguments.contains("--without-csp"), "bridgeHidden": true, "toc": true, "highlighted": true, "diagram": true, "math": true, "fetchBlocked": true]
                guard values == expected else { self.fail("Unexpected WebKit fixture result: " + string); return }
                self.finished = true
                print("PASS: local template/TOC/highlight/Mermaid/math; script policy; isolated bridge; offline fetch blocked")
                exit(0)
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("Fixture navigation failed: " + error.localizedDescription) }
    func fail(_ message: String) { fputs(message + "\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let audit = Audit(index: URL(fileURLWithPath: CommandLine.arguments[1]))
audit.start()
app.run()
'''

def main():
    hits = []
    class Sink(BaseHTTPRequestHandler):
        def do_GET(self):
            hits.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"synthetic fixture")
        def log_message(self, *_):
            pass
    server = HTTPServer(("127.0.0.1", 0), Sink)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = "http://127.0.0.1:" + str(server.server_port)
    try:
        with tempfile.TemporaryDirectory(prefix="consolinotes-webkit-test-") as temporary:
            directory = Path(temporary)
            page = directory / "page"
            shutil.copytree(ROOT / "Resources/MPreview.bundle", page)
            nonce = "ConsolinotesSyntheticNonce0123456789"
            body = '<div id="toc"></div><h1>Fixture</h1><pre><code class="language-swift">let answer = 42</code></pre><pre><code class="language-mermaid">graph TD; A--&gt;B;</code></pre><p>\\(x^2\\)</p>'
            body += '<script>window.auditUntrusted=true</script><img src="' + endpoint + '/image"><iframe src="' + endpoint + '/frame"></iframe>'
            body += '<style>body {background-image:url("' + endpoint + '/css")}</style>'
            body += '<script nonce="' + nonce + '">window.auditTrusted=true;fetch(' + json.dumps(endpoint + '/fetch') + ').catch(()=>window.auditFetchBlocked=true);</script>'
            template = (page / "index.html").read_text()
            values = {"{TITLE}": "Synthetic security fixture", "{INLINE_CSS}": "", "{THEME_CSS}": "", "{MATH_JAX_JS}": '<script nonce="{NONCE}" defer src="js/tex-mml-chtml.js"></script>', "{FSNOTES_THEME}": "", "{FSNOTES_APPEARANCE}": "", "{FSNOTES_PLATFORM}": "macos", "{NONCE}": nonce}
            for token, value in values.items():
                template = template.replace(token, value)
            (page / "index.html").write_text(template.replace("{NOTE_BODY}", body))
            source = directory / "main.swift"
            source.write_text(SWIFT)
            executable = directory / "webkit-tests"
            subprocess.run(["swiftc", "-module-cache-path", str(directory / "modules"), str(ROOT / "FSNotesCore/PrivateWorkingDirectory.swift"), str(ROOT / "FSNotesCore/LocalPreviewSecurity.swift"), str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable), str(page / "index.html")], check=True, timeout=40)
            # Independently verify the WebKit resource rules; do not rely solely on CSP.
            without_csp = re.sub(r'    <meta http-equiv="Content-Security-Policy"[^>]*>\n', '', (page / "index.html").read_text())
            (page / "without-csp.html").write_text(without_csp)
            subprocess.run([str(executable), str(page / "without-csp.html"), "--without-csp"], check=True, timeout=40)
            if hits:
                raise SystemExit("FAIL: preview contacted synthetic loopback endpoint: " + repr(hits))
            print("PASS: no loopback requests from image, CSS, frame, or fetch attempts, with and without CSP")
    finally:
        server.shutdown()

if __name__ == "__main__":
    main()
