// Copyright (c) 2019 Oleksandr Glushchenko; 2026 sebiimaks. MIT license.

import WebKit
import Carbon.HIToolbox

public typealias MPreviewViewClosure = () -> ()

class MPreviewView: WKWebView, WKUIDelegate, WKNavigationDelegate {
    private weak var editorVC: EditorViewController?
    private weak var note: Note?
    private var closure: MPreviewViewClosure?
    private var rulesReady = false
    private var documentURL: URL?
    private var selectedText: String?
    private var renderDeadline: DispatchWorkItem?
    private var renderGeneration = 0
    private static let activeViews = NSHashTable<MPreviewView>.weakObjects()
    public static var template: String?

    init(frame: CGRect, note: Note, closure: MPreviewViewClosure?, force: Bool = false) {
        self.closure = closure
        self.note = note
        let configuration = LocalPreviewSecurity.configuration()
        configuration.suppressesIncrementalRendering = true
        super.init(frame: frame, configuration: configuration)
        navigationDelegate = self
        uiDelegate = self
        setValue(false, forKey: "drawsBackground")
        Self.activeViews.add(self)

        // Page scripts cannot access this bridge. On older macOS the preview is read-only.
        if #available(macOS 11.0, *) {
            let bridge = PreviewBridge(view: self)
            configuration.userContentController.add(bridge, contentWorld: .defaultClient, name: "preview")
            configuration.userContentController.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        LocalPreviewSecurity.prepare(self) { [weak self] ready in
            guard let self = self else { return }
            self.rulesReady = ready
            if ready, let note = self.note { self.load(note: note, force: true) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        renderDeadline?.cancel()
        LocalPreviewSecurity.remove(documentURL?.deletingLastPathComponent())
    }

    public func setEditorVC(evc: EditorViewController? = nil) { editorVC = evc }

    /// Disk cleanup is synchronous even when a background encryption operation calls this.
    public static func purgeSensitivePreviews() {
        LocalPreviewSecurity.purge()
        let clearViews = {
            for view in activeViews.allObjects { view.clean() }
            if #available(macOS 11.0, *) { Printer.purgeSensitivePreviews() }
        }
        if Thread.isMainThread { clearViews() } else { DispatchQueue.main.async(execute: clearViews) }
    }

    override func mouseDown(with event: NSEvent) {
        if let evc = editorVC, let note = evc.vcEditor?.note {
            if note.isEncryptedAndLocked() {
                evc.unLock(notes: [note])
            } else if note.content.length == 0 {
                evc.disablePreview()
                evc.focusEditArea()
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Return {
            editorVC?.disablePreview()
            editorVC?.focusEditArea()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.characters?.unicodeScalars.first == "c", event.modifierFlags.contains(.command), let text = selectedText {
            SensitiveClipboard.writeString(text)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierReload" { item.isHidden = true }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard documentURL != nil, note?.isEncryptedAndLocked() == false else { return }
        waitForRendering(generation: renderGeneration)
        closure?()
    }

    /// The watchdog runs in the app, independently of the WebKit content process.
    /// A stuck diagram must never keep the user from returning to the editor.
    private func startRenderDeadline() {
        renderDeadline?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, self.renderGeneration == generation,
                  self.documentURL != nil, let editor = self.editorVC else { return }
            self.isHidden = true
            self.clean()
            if #available(macOS 11.0, *) {
                self.configuration.userContentController.removeScriptMessageHandler(forName: "preview", contentWorld: .defaultClient)
            }
            self.configuration.userContentController.removeAllUserScripts()
            self.navigationDelegate = nil
            self.uiDelegate = nil
            self.closure = nil
            self.editorVC = nil
            editor.disablePreview(captureScroll: false)
            let alert = NSAlert()
            alert.messageText = "Preview stopped"
            alert.informativeText = "This preview took too long to render. Your note is unchanged. You can edit the note and try Preview again."
            alert.addButton(withTitle: "Close")
            if let window = editor.view.window { alert.beginSheetModal(for: window) }
        }
        renderDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + LocalPreviewSecurity.maximumRenderSeconds, execute: deadline)
    }

    private func waitForRendering(generation: Int) {
        guard generation == renderGeneration, documentURL != nil else { return }
        evaluateJavaScript("window.consolinotesPreviewReady === true") { [weak self] result, _ in
            guard let self = self, generation == self.renderGeneration else { return }
            if result as? Bool == true {
                self.renderDeadline?.cancel()
                self.renderDeadline = nil
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForRendering(generation: generation)
                }
            }
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard documentURL != nil else { return }
        clean()
        editorVC?.disablePreview(captureScroll: false)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            guard action.sourceFrame.isMainFrame, let documentURL = documentURL else { return }
            if url.deletingFragment == documentURL, let fragment = url.fragment {
                openAnchor(anchor: fragment.removingPercentEncoding ?? fragment)
            } else if let attachment = MemoryPreview.attachment(url, document: documentURL), let note = note {
                PlaintextDisclosure.exportAttachment(attachment, from: note, window: window)
            } else if let attachment = LocalPreviewSecurity.attachment(for: url, directory: documentURL.deletingLastPathComponent()) {
                NSWorkspace.shared.activateFileViewerSelecting([attachment])
            } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            } else if ["consolinotes", "fsnotes"].contains(url.scheme?.lowercased() ?? ""),
                      ["open", "find"].contains(url.host ?? ""), url["txt"] == nil, url["html"] == nil {
                _ = AppDelegate.openAppLink(url)
            }
            return
        }
        // Includes redirects, form submissions, subframes and script-driven navigation.
        let initialDocument = action.targetFrame?.isMainFrame == true && url == documentURL
        decisionHandler(initialDocument || (documentURL == nil && url.absoluteString == "about:blank") ? .allow : .cancel)
    }

    public func load(note: Note, force: Bool = false) {
        if !rulesReady { self.note = note; return }
        guard self.note != note || force else { return }
        stopLoading()
        LocalPreviewSecurity.remove(documentURL?.deletingLastPathComponent())
        documentURL = nil
        selectedText = nil
        self.note = note
        guard !note.isEncryptedAndLocked(), let index = Self.buildPage(for: note) else {
            loadHTMLString("", baseURL: nil)
            return
        }
        documentURL = index
        isHidden = false
        startRenderDeadline()
        LocalPreviewSecurity.load(index, in: self)
    }

    public func clean() {
        renderGeneration += 1
        renderDeadline?.cancel()
        renderDeadline = nil
        stopLoading()
        LocalPreviewSecurity.remove(documentURL?.deletingLastPathComponent())
        documentURL = nil
        selectedText = nil
        note = nil
        loadHTMLString("", baseURL: nil)
    }

    private func openAnchor(anchor: String) {
        let argument = LocalPreviewSecurity.javaScriptString(anchor)
        evaluateJavaScript("""
        (() => {
            const anchor = \(argument);
            const element = document.getElementById(anchor) || Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6')).find(e => e.textContent.trim() === anchor.replace(/[-_]/g, ' '));
            if (element) element.scrollIntoView();
        })()
        """)
    }

    public static func buildPage(for note: Note, print: Bool = false) -> URL? {
        guard !note.isEncryptedAndLocked() else { return nil }
        let content = note.getPrettifiedContent()
        guard content.utf8.count <= LocalPreviewSecurity.maximumMarkdownBytes else { return nil }
        let rendered: String
        if note.isMarkdown() {
            guard let html = renderMarkdownHTML(markdown: content) else { return nil }
            rendered = html
        } else { rendered = "<pre>" + LocalPreviewSecurity.escapeHTML(content) + "</pre>" }
        if note.hasMemoryWorkspace, let assets = note.memoryAttachmentSnapshot() {
            return MemoryPreview.create(rendered: rendered, assets: assets, attachmentURL: { note.getAttachmentFileUrl(name: $0) }, printing: print) {
                try htmlFromTemplate($0, print: print, note: note)
            }
        }
        guard !note.isEncrypted(), let directory = try? LocalPreviewSecurity.makeDirectory() else { return nil }
        var success = false
        defer { if !success { LocalPreviewSecurity.remove(directory) } }
        let root = note.isTextBundle() ? note.getURL() : note.project.url
        let html = LocalPreviewSecurity.localResources(in: rendered, root: root, directory: directory, interactive: !print)
        guard let page = try? htmlFromTemplate(html, print: print, note: note),
              let index = createTemporaryBundle(pageHTMLString: page, at: directory) else { return nil }
        success = true
        return index
    }

    public static func createTemporaryBundle(pageHTMLString: String, at directory: URL) -> URL? {
        guard let bundle = Bundle.main.url(forResource: "MPreview", withExtension: "bundle") else { return nil }
        let index = directory.appendingPathComponent("index.html")
        do {
            for resource in try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil) where resource.lastPathComponent != "index.html" {
                try FileManager.default.copyItem(at: resource, to: directory.appendingPathComponent(resource.lastPathComponent))
            }
            try pageHTMLString.write(to: index, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
            return index
        } catch { return nil }
    }

    public static func getMathJaxJS() -> String {
        guard UserDefaultsManagement.mathJaxPreview else { return "" }
        return """
        <script nonce="{NONCE}" src="js/mathjax-config.js"></script>
        <script nonce="{NONCE}" id="MathJax-script" defer src="js/mathjax/tex-mml-chtml.js"></script>
        """
    }

    public static func htmlFromTemplate(_ html: String, print: Bool = false, note: Note? = nil) throws -> String {
        guard let bundle = Bundle.main.url(forResource: "MPreview", withExtension: "bundle") else { throw CocoaError(.fileNoSuchFile) }
        var page = try String(contentsOf: bundle.appendingPathComponent("index.html"), encoding: .utf8)
        let dark = UserDataService.instance.isDark && !print
        let theme = print ? "" : "consolinotes"
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let replacements = [
            "{TITLE}": LocalPreviewSecurity.escapeHTML(note?.getTitle() ?? ""),
            "{INLINE_CSS}": getPreviewStyle(print: print),
            "{THEME_CSS}": print ? "" : "<link href=\"consolinotes.css\" rel=\"stylesheet\">",
            "{FSNOTES_THEME}": theme,
            "{MATH_JAX_JS}": getMathJaxJS(),
            "{FSNOTES_APPEARANCE}": dark ? "darkmode" : "",
            "{FSNOTES_PLATFORM}": "macos"
        ]
        for (token, replacement) in replacements { page = page.replacingOccurrences(of: token, with: replacement) }
        page = page.replacingOccurrences(of: "{NONCE}", with: nonce)
        // Note content is inserted last; it cannot substitute template control tokens.
        return page.replacingOccurrences(of: "{NOTE_BODY}", with: html)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.deletingFragment == documentURL,
              message.webView === self, let note = note, !note.isEncryptedAndLocked(),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "selection":
            if let value = body["value"] as? String, value.utf8.count <= LocalPreviewSecurity.maximumMarkdownBytes { selectedText = value }
        case "clipboard":
            guard let value = body["value"] as? String, value.utf8.count <= LocalPreviewSecurity.maximumMarkdownBytes else { return }
            SensitiveClipboard.writeString(value)
        case "checkbox":
            guard let index = body["value"] as? Int, index >= 0, index < 100_000 else { return }
            let content = note.content.unloadAttachments()
            let string = content.string
            var position = 0
            var changed = false
            NotesTextProcessor.allTodoInlineRegex.matches(string, range: NSRange(location: 0, length: content.length)) { result in
                defer { position += 1 }
                guard position == index, let range = result?.range else { return }
                let checked = content.mutableString.substring(with: range).contains("- [x] ")
                content.replaceCharacters(in: range, with: checked ? "- [ ] " : "- [x] ")
                changed = true
            }
            if changed { note.save(content: content.loadAttachments(note)) }
        case "scroll":
            if let x = body["x"] as? Double, let y = body["y"] as? Double, x.isFinite, y.isFinite { note.contentOffsetWeb = CGPoint(x: x, y: y) }
        default: break
        }
    }

    private static let bridgeScript = """
    (() => {
        const send = body => window.webkit.messageHandlers.preview.postMessage(body);
        for (const name of ['mouseup', 'keyup', 'contextmenu']) document.addEventListener(name, event => {
            if (event.isTrusted) send({kind: 'selection', value: String(document.getSelection())});
        });
        document.addEventListener('click', event => {
            if (!event.isTrusted) return;
            const box = event.target.closest('input[type=checkbox]');
            if (box) {
                const boxes = Array.from(document.querySelectorAll('input[type=checkbox]'));
                send({kind: 'checkbox', value: boxes.indexOf(box)});
                return;
            }
            const code = event.target.closest('pre code');
            if (code && !code.classList.contains('language-mermaid')) send({kind: 'clipboard', value: code.innerText});
        });
        document.querySelectorAll('li input[type=checkbox]').forEach(box => { box.disabled = false; });
        let pending = false;
        window.addEventListener('scroll', () => {
            if (pending) return;
            pending = true;
            requestAnimationFrame(() => { send({kind:'scroll', x:window.scrollX, y:window.scrollY}); pending = false; });
        }, {passive:true});
    })();
    """
    public static func getPreviewStyle(print: Bool = false, forceLightTheme: Bool = false) -> String {
        var theme: String? = nil
        var fullScreen = false
        var useFixedImageHeight = true
        var css = "<style>"
        
        if print {
            theme = "github-light"
            fullScreen = true
            useFixedImageHeight = false
        }

        css +=
            useFixedImageHeight
                ? String("img { max-height: 90vh; }")
                : String()

        if forceLightTheme {
            theme = UserDefaultsManagement.codeTheme.getCssName(isDark: false)
            fullScreen = true
        } else {
            let isDark = UserDataService.instance.isDark
            theme = theme ?? UserDefaultsManagement.codeTheme.getCssName(isDark: isDark)
        }

        var codeStyle = String()
        
        if let bundleURL = Bundle.main.url(forResource: "MPreview", withExtension: "bundle"),
            let mPreviewBundle = Bundle(url: bundleURL),
            let theme = theme,
            let cssURL = mPreviewBundle.url(forResource: theme, withExtension: "min.css", subdirectory: "styles"),
            let content = try? String(contentsOf: cssURL, encoding: .utf8) {

            codeStyle = content
        }
        
            let codeFamilyName = UserDefaultsManagement.codeFont.familyName ?? ""
            var familyName = UserDefaultsManagement.noteFont.familyName ?? ""
            let tagColor = NSColor.tagColor.hexString

        if familyName.starts(with: ".") {
            familyName = "Helvetica Neue";
        }

            var width = Int(ViewController.shared()!.editor.getInsetWidth())

        if fullScreen {
            width = 0
        }

        let codeBackground = NotesTextProcessor.getHighlighter().options.style.backgroundColor.hexString
        var maxImageWidth = String(Int(UserDefaultsManagement.imagesWidth)) + "px"
        
        let fontSize = UserDefaultsManagement.fontSize
        let codeFontSize = UserDefaultsManagement.codeFontSize
        
        let codeLineHeight = computeDefaultLineHeight(for: UserDefaultsManagement.codeFont, lineHeightMultiple: UserDefaultsManagement.lineHeightMultiple)
        let lineHeight = computeDefaultLineHeight(for: UserDefaultsManagement.noteFont, lineHeightMultiple: UserDefaultsManagement.lineHeightMultiple)

        var result = """
            @font-face {
                font-family: 'Source Code Pro';
                src: url('fonts/SourceCodePro-Regular.ttf')
                format('truetype');
            }

            @font-face {
                font-family: 'Source Code Pro';
                src: url('fonts/SourceCodePro-Bold.ttf');
                font-weight: bold;
            }
        
            body {font: \(fontSize)px '\(familyName)', '-apple-system'; margin: 0 \(width + 5)px; -webkit-text-size-adjust: none;}
            code, pre {font: \(codeFontSize)px '\(codeFamilyName)', Courier, monospace, 'Liberation Mono', Menlo; line-height: \(codeLineHeight + 3)px; -webkit-text-size-adjust: none; }
            img:not(footer img, .attachment) {display: block; margin: 0 auto; max-width: \(maxImageWidth); }
        
            img.attachment { height: \(fontSize + 5)px; max-width: auto }
            a[href^=\"consolinotes://open/?tag=\"], a[href^=\"fsnotes://open/?tag=\"] { background: \(tagColor); }
            p, li, blockquote, dl, ol, ul { line-height: \(lineHeight)px; -webkit-text-size-adjust: none; } \(codeStyle) \(css)
        
            code, .hljs { background: \(codeBackground); }

            #MathJax_Message+* {
                margin-top: 0 !important;
            }
        """
                
        if print {
            result += """
                body { -webkit-text-size-adjust: none; font-size: 1.0em;}
                pre, code { border: 1px solid #c0c4ce; border-radius: 3px; }
                pre, pre code { word-wrap: break-word; }
            """
        }
        
        css += result
        css += "</style>"
        
        return css
    }
    
    private static func computeDefaultLineHeight(for font: Font, lineHeightMultiple: CGFloat = 1.0) -> CGFloat {
        let asc = font.ascender
        let desc = abs(font.descender)
        let lead = font.leading

        let base = asc + desc + lead
        return base * lineHeightMultiple
    }
}

private final class PreviewBridge: NSObject, WKScriptMessageHandler {
    weak var view: MPreviewView?
    init(view: MPreviewView) { self.view = view }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        view?.receive(message)
    }
}

private extension URL {
    var deletingFragment: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? self
    }
}
