// Copyright (c) 2024 Oleksandr Hlushchenko; 2026 sebiimaks. MIT license.

import WebKit

@available(macOS 11.0, *)
class Printer: NSObject, WKNavigationDelegate {
    private let indexURL: URL
    private var webView: WKWebView?
    // Retain a pending print until its asynchronous WebKit load and modal panel finish.
    private static var active = [Printer]()

    init(indexURL: URL) { self.indexURL = indexURL; super.init() }

    static func purgeSensitivePreviews() {
        let printers = active
        active.removeAll()
        for printer in printers { printer.finish() }
    }

    private func finish() {
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
        LocalPreviewSecurity.prepare(view) { [weak self] ready in
            guard let self = self, let view = self.webView else { return }
            guard ready else { self.finish(); return }
            view.loadFileURL(self.indexURL, allowingReadAccessTo: self.indexURL.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == indexURL && action.navigationType != .linkActivated ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        operation.runModal(for: window, delegate: self, didRun: #selector(printFinished(_:success:context:)), contextInfo: nil)
    }

    @objc private func printFinished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) { finish() }
}
