#!/usr/bin/env python3
"""Run production watchdog methods against a deliberately stuck WebKit page."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def method(source, signature):
    start = source.index(signature)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end]

source = (ROOT / 'FSNotesCore/MPreviewView.swift').read_text()
methods = '\n'.join(method(source, signature) for signature in [
    '    private func startRenderDeadline()', '    private func waitForRendering(generation: Int)'])
swift = r'''
import Cocoa
import WebKit
enum LocalPreviewSecurity { static let maximumRenderSeconds: TimeInterval = 0.5 }
final class EditorViewController: NSViewController {
    var disabled = false
    override func loadView() { view = NSView() }
    func disablePreview(captureScroll: Bool = true) {
        guard !captureScroll else { fatalError("Must not enqueue JavaScript on a stalled page") }
        disabled = true
    }
}
final class Preview: WKWebView {
    var renderDeadline: DispatchWorkItem?
    var renderGeneration = 0
    var documentURL: URL?
    weak var editorVC: EditorViewController?
    var closure: (() -> ())?
    func begin() { startRenderDeadline() }
    func clean() {
        renderGeneration += 1
        renderDeadline?.cancel()
        renderDeadline = nil
        documentURL = nil
        stopLoading()
    }
    METHODS
}
final class FixtureBridge: NSObject, WKScriptMessageHandler {
    weak var preview: Preview?
    var entered = false
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "started" else { return }
        entered = true
        preview?.begin()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let editor = EditorViewController()
let cancelledEditor = EditorViewController()
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let bridge = FixtureBridge()
configuration.userContentController.add(bridge, name: "fixture")
let preview = Preview(frame: .zero, configuration: configuration)
bridge.preview = preview
preview.editorVC = editor
preview.documentURL = fixture
preview.loadFileURL(fixture, allowingReadAccessTo: fixture.deletingLastPathComponent())
let cancelledConfiguration = WKWebViewConfiguration()
cancelledConfiguration.websiteDataStore = .nonPersistent()
let cancelled = Preview(frame: .zero, configuration: cancelledConfiguration)
cancelled.editorVC = cancelledEditor
cancelled.documentURL = fixture
cancelled.begin()
cancelled.clean()
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    guard bridge.entered, editor.disabled, preview.isHidden, preview.documentURL == nil,
          !cancelledEditor.disabled else { fatalError("Watchdog or generation cancellation failed") }
    print("PASS: production watchdog hides stalled WebKit content, returns to editor, and ignores a cancelled generation")
    exit(0)
}
app.run()
'''.replace('    METHODS', methods)
with tempfile.TemporaryDirectory(prefix='consolinotes-preview-deadline-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(swift)
    (path / 'stuck.html').write_text('<script>window.webkit.messageHandlers.fixture.postMessage("started"); while (true) {}</script>')
    subprocess.run(['swiftc', '-module-cache-path', str(path / 'modules'), str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(path / 'stuck.html')], check=True, timeout=10)
