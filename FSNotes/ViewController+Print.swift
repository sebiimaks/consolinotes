// Copyright (c) 2019 Oleksandr Glushchenko; 2026 sebiimaks. MIT license.

import WebKit

extension EditorViewController {
    public func printMarkdownPreview() {
        guard let note = vcEditor?.note else { return }
        // The legacy WebView printer cannot enforce the isolated offline preview policy.
        guard #available(macOS 11.0, *) else { NSSound.beep(); return }
        guard let index = MPreviewView.buildPage(for: note, print: true) else { return }
        Printer(indexURL: index).printWeb()
    }
}
