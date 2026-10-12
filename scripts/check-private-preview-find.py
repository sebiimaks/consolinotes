#!/usr/bin/env python3
"""Exercise production preview Find teardown against delayed WebKit/animation callbacks.

Uses synthetic AppKit windows and a WebKit-result double. No real notes,
general/Find pasteboards, app preferences or hardware are accessed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'FSNotes/View/EditTextView.swift').read_text()
start = source.index('    public func clearPrivateFind()')
end = source.index('\n    }', start) + len('\n    }')
clear_method = source[start:end]
fixture = r'''
import Cocoa
func expect(_ result: @autoclosure () -> Bool, _ message: String) {
    if !result() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
final class Note {}
typealias MPreviewViewClosure = () -> Void
enum LocalFindState { static var query = "synthetic private search" }
enum PrivacyLog { static func record(_ event: StaticString) {} }
enum LocalPreviewSecurity { static func javaScriptString(_ value: String) -> String { "\"fixture\"" } }
final class MPreviewView: NSView {
    var callbacks = [(Any?, Error?) -> Void]()
    init(frame: NSRect, note: Note, closure: MPreviewViewClosure?, force: Bool) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    func evaluateJavaScript(_ script: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        if let completionHandler = completionHandler { callbacks.append(completionHandler) }
    }
}
final class Finder { var cleared = false; func close(clear: Bool) { cleared = clear } }
final class EditTextView {
    var privateFinder: Finder? = Finder()
    var markdownView: MPreviewContainerView?
__CLEAR__
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func status(_ panel: MPreviewFindPanel) -> NSTextField {
    descendants(panel).compactMap { $0 as? NSTextField }.first { !($0 is NSSearchField) }!
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let preview = MPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), note: Note(), closure: nil)
let panel = preview.subviews.compactMap { $0 as? MPreviewFindPanel }.first!
let editor = EditTextView(); editor.markdownView = preview
let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = preview
window.makeKeyAndOrderFront(nil)
preview.showFindPanel()
expect(preview.isFindPanelVisible && !panel.isHidden, "Find did not open")
window.makeFirstResponder(panel.searchField)
let fieldEditor = panel.searchField.currentEditor()
expect(fieldEditor != nil, "Synthetic field editor did not activate")
fieldEditor?.string = "private field-editor query"
panel.updateStatus(current: 2, total: 8)
var selectionDelivered = false
preview.getSelectedText { text in
    selectionDelivered = true
    LocalFindState.query = text ?? ""
    preview.showFindPanel()
}
let stale = preview.webView.callbacks
preview.webView.callbacks.removeAll()
expect(stale.count == 2, "Expected pending search and selection results")
LocalFindState.query = ""
editor.clearPrivateFind()
expect(editor.privateFinder?.cleared == true, "Text editor Find was not cleared")
expect(!preview.isFindPanelVisible && panel.isHidden && panel.panelHeightConstraint.constant == 0, "Find did not hide synchronously")
expect(panel.searchField.stringValue.isEmpty && fieldEditor?.string == "" && status(panel).stringValue.isEmpty, "Find retained query, field editor or status")
stale[0](8, nil); stale[1]("late private selection", nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
expect(!selectionDelivered && LocalFindState.query.isEmpty, "Stale selection callback restored a query")
expect(panel.isHidden && panel.searchField.currentEditor() == nil, "Pending show animation refocused hidden Find")
expect(status(panel).stringValue.isEmpty, "Stale search result restored status")

// Reopening creates a new session; old results must still remain revoked.
preview.showFindPanel()
stale[0](99, nil); stale[1]("old session", nil)
expect(!selectionDelivered && status(panel).stringValue.isEmpty, "Reopening accepted a stale session result")
panel.onSearch?("current query")
let current = preview.webView.callbacks.removeFirst()
current(3, nil)
expect(status(panel).stringValue == "1 from 3", "Current search result was rejected")
preview.findNext()
let next = preview.webView.callbacks.removeFirst()
editor.clearPrivateFind()
next(2, nil)
expect(status(panel).stringValue.isEmpty && panel.searchField.stringValue.isEmpty, "Stale navigation result restored Find state")
window.orderOut(nil)
print("PASS: preview Find clears field editor/status synchronously, invalidates search/selection/navigation results and prevents delayed focus")
'''.replace('__CLEAR__', clear_method)

with tempfile.TemporaryDirectory(prefix='consolinotes-preview-find-') as temporary:
    work = Path(temporary)
    (work / 'main.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'),
                    str(ROOT / 'FSNotes/View/MPreviewFindPanel.swift'),
                    str(ROOT / 'FSNotes/View/MPreviewContainerView.swift'),
                    str(work / 'main.swift'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True, timeout=15)
