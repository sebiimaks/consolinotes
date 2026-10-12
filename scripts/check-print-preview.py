#!/usr/bin/env python3
"""Exercise production print deadline/readiness/cleanup methods in real WebKit."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'FSNotes/Helpers/Printer.swift').read_text()

def method(signature):
    start = source.index(signature)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end]

methods = '\n'.join(method(signature) for signature in [
    '    private func finish()', '    private func startRenderDeadline()',
    '    private func waitForRendering(_ view:', '    static func purgeSensitivePreviews()',
    '    @objc private func printFinished('])
# A background accessory test has no NSApp.mainWindow; inject only that lookup.
methods += '\n' + method('    private func showPrintPanel(').replace('showPrintPanel(', 'showActualPrintPanel(').replace('NSApplication.shared.mainWindow', 'FixtureWindow.main')
swift = r'''
import Cocoa
import WebKit
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
enum FixtureWindow { static weak var main: NSWindow? }
enum LocalPreviewSecurity {
    static let maximumRenderSeconds: TimeInterval = 0.5
    static func remove(_ directory: URL) { if FileManager.default.fileExists(atPath: directory.path) { try! FileManager.default.removeItem(at: directory) } }
}
final class Printer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let indexURL: URL
    var webView: WKWebView?
    var printOperation: NSPrintOperation?
    weak var printWindow: NSWindow?
    weak var printSheet: NSWindow?
    var finishing = false
    var renderDeadline: DispatchWorkItem?
    var renderGeneration = 0
    static var active = [Printer]()
    var shown = 0
    var entered = false
    let cancel: Bool
    let actualPanel: Bool
    init(index: URL, cancel: Bool = false, actualPanel: Bool = false) {
        indexURL = index
        self.cancel = cancel
        self.actualPanel = actualPanel
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "fixture")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842), configuration: configuration)
        webView = view
        view.navigationDelegate = self
        Self.active.append(self)
        view.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "started", let view = webView else { return }
        entered = true
        startRenderDeadline()
        waitForRendering(view, generation: renderGeneration)
        if cancel { finish() }
    }
    func showPrintPanel(for view: WKWebView) {
        guard view === webView else { fail("Stale print view") }
        shown += 1
        if actualPanel { showActualPrintPanel(for: view) } else { finish() }
    }
    METHODS
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let ready = Printer(index: base.appendingPathComponent("ready/index.html"))
let stuck = Printer(index: base.appendingPathComponent("stuck/index.html"))
let cancelled = Printer(index: base.appendingPathComponent("cancel/index.html"), cancel: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    guard ready.entered, stuck.entered, cancelled.entered,
          ready.shown == 1, stuck.shown == 0, cancelled.shown == 0,
          ready.webView == nil, stuck.webView == nil, cancelled.webView == nil,
          Printer.active.isEmpty,
          !FileManager.default.fileExists(atPath: base.appendingPathComponent("ready").path),
          !FileManager.default.fileExists(atPath: base.appendingPathComponent("stuck").path),
          !FileManager.default.fileExists(atPath: base.appendingPathComponent("cancel").path)
    else { fail("Print readiness, deadline, cancellation or staging cleanup failed") }
    print("PASS: production print waits for ready page; timeout and cancellation release WebKit and plaintext staging without opening print panel")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "consolinotes synthetic print cancellation test"
    window.makeKeyAndOrderFront(nil)
    window.makeMain()
    FixtureWindow.main = window
    let panel = Printer(index: base.appendingPathComponent("panel/index.html"), actualPanel: true)
    let start = Date()
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        guard let sheet = window.attachedSheet else {
            if Date().timeIntervalSince(start) > 8 { fail("Actual print panel did not open (entered: \(panel.entered), shown: \(panel.shown), view: \(panel.webView != nil), operation: \(panel.printOperation != nil), main: \(app.mainWindow === window), sheets: \(window.sheets.count))") }
            return
        }
        guard panel.printSheet === sheet else {
            if Date().timeIntervalSince(start) > 8 { fail("Production printer did not capture its sheet") }
            return
        }
        timer?.invalidate()
        Printer.purgeSensitivePreviews()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard window.attachedSheet == nil, !sheet.isVisible, panel.webView == nil,
                  panel.printOperation == nil, panel.printWindow == nil, panel.printSheet == nil,
                  Printer.active.isEmpty,
                  !FileManager.default.fileExists(atPath: base.appendingPathComponent("panel").path)
            else { fail("Lock left print panel or preview state visible") }
            print("PASS: production print purge closes the actual OS print sheet and releases operation, WebKit and staging")
            window.orderOut(nil)
            exit(0)
        }
    }
}
app.run()
'''.replace('    METHODS', methods)
with tempfile.TemporaryDirectory(prefix='consolinotes-print-deadline-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(swift)
    for name, script in [('ready', 'window.consolinotesPreviewReady=true;'), ('stuck', 'while(true){}'), ('cancel', 'window.consolinotesPreviewReady=true;'), ('panel', 'window.consolinotesPreviewReady=true;')]:
        page = path / name
        page.mkdir()
        (page / 'index.html').write_text('<script>window.webkit.messageHandlers.fixture.postMessage("started");' + script + '</script>')
    subprocess.run(['swiftc', '-module-cache-path', str(path / 'modules'), str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(path)], check=True, timeout=20)
