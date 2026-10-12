// Copyright (c) 2024 Oleksandr Hlushchenko; 2026 sebiimaks. MIT license.

import WebKit

@available(macOS 11.0, *)
class Printer: NSObject, WKNavigationDelegate {
    private let indexURL: URL
    private var webView: WKWebView?
    private var printOperation: NSPrintOperation?
    private weak var printWindow: NSWindow?
    private weak var printSheet: NSWindow?
    private var finishing = false
    private var renderDeadline: DispatchWorkItem?
    private var renderGeneration = 0
    // Retain a pending print until its asynchronous WebKit load and modal panel finish.
    private static var active = [Printer]()

    init(indexURL: URL) { self.indexURL = indexURL; super.init() }

    static func purgeSensitivePreviews() {
        let printers = active
        active.removeAll()
        for printer in printers { printer.finish() }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        defer { finishing = false }
        if printOperation != nil, let sheet = printSheet, let window = printWindow, sheet.sheetParent === window {
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        printOperation = nil; printWindow = nil; printSheet = nil
        renderGeneration += 1
        renderDeadline?.cancel()
        renderDeadline = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        LocalPreviewSecurity.remove(indexURL.deletingLastPathComponent())
        Self.active.removeAll { $0 === self }
    }

    public func printWeb() {
        Self.active.append(self)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842), configuration: LocalPreviewSecurity.configuration())
        webView = view
        view.navigationDelegate = self
        startRenderDeadline()
        LocalPreviewSecurity.prepare(view) { [weak self] ready in
            guard let self = self, let view = self.webView else { return }
            guard ready else { self.finish(); return }
            LocalPreviewSecurity.load(self.indexURL, in: view)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == indexURL && action.navigationType != .linkActivated ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        waitForRendering(webView, generation: renderGeneration)
    }

    private func startRenderDeadline() {
        renderDeadline?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, generation == self.renderGeneration, self.webView != nil else { return }
            self.finish()
            let alert = NSAlert()
            alert.messageText = "Print preview stopped"
            alert.informativeText = "This note took too long to render for printing. Your note is unchanged. You can edit it and try printing again."
            alert.addButton(withTitle: "Close")
            if let window = NSApplication.shared.mainWindow { alert.beginSheetModal(for: window) }
        }
        renderDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + LocalPreviewSecurity.maximumRenderSeconds, execute: deadline)
    }

    private func waitForRendering(_ view: WKWebView, generation: Int) {
        guard generation == renderGeneration, view === webView else { return }
        // Capture neither the view nor self strongly: a hung WebKit callback must
        // not retain a canceled print operation or its plaintext staging.
        view.evaluateJavaScript("window.consolinotesPreviewReady === true") { [weak self, weak view] result, _ in
            guard let self = self, let view = view, generation == self.renderGeneration, view === self.webView else { return }
            if result as? Bool == true {
                self.renderDeadline?.cancel()
                self.renderDeadline = nil
                self.showPrintPanel(for: view)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak view] in
                    guard let view = view else { return }
                    self?.waitForRendering(view, generation: generation)
                }
            }
        }
    }

    private func showPrintPanel(for webView: WKWebView) {
        guard webView === self.webView, let window = NSApplication.shared.mainWindow else { finish(); return }
        let info = NSPrintInfo(dictionary: [.paperSize: CGSize(width: 595.28, height: 841.89)])
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.leftMargin = 20
        info.topMargin = 20
        info.rightMargin = 20
        info.bottomMargin = 20
        let operation = webView.printOperation(with: info)
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPreview])
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        printOperation = operation
        printWindow = window
        operation.runModal(for: window, delegate: self, didRun: #selector(printFinished(_:success:context:)), contextInfo: nil)
        if printOperation != nil { printSheet = window.attachedSheet }
    }

    @objc private func printFinished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        printOperation = nil; printWindow = nil; printSheet = nil
        finish()
    }
}
