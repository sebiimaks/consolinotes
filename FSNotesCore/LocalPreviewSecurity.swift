// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import WebKit
import Darwin

/// Only generated documents and explicitly resolved local attachments enter a preview.
enum LocalPreviewSecurity {
    static let maximumMarkdownBytes = 2 * 1024 * 1024
    static let maximumRenderSeconds: TimeInterval = 10
    private static let maximumAssetBytes = 25 * 1024 * 1024
    private static let mutex = NSLock()
    private static var directories = Set<URL>()
    private static var attachments = [URL: [String: URL]]()
    static let rasterExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]
    private static let cleanupAtFirstUse: Void = { removeAbandonedStaging() }()

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(MemoryPreview(), forURLScheme: MemoryPreview.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    /// Fail closed: callers must not load a document if rule compilation fails.
    static func prepare(_ webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let rules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^file://"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^consolinotes-preview://"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "consolinotes-local-preview-v2", encodedContentRuleList: rules) { [weak webView] list, _ in
            guard let webView = webView, let list = list else {
                completion(false)
                return
            }
            webView.configuration.userContentController.add(list)
            completion(true)
        }
    }

    static func load(_ url: URL, in view: WKWebView) {
        if url.scheme == MemoryPreview.scheme,
           let handler = view.configuration.urlSchemeHandler(forURLScheme: MemoryPreview.scheme) as? MemoryPreview {
            handler.allowedHost = url.host
            view.load(URLRequest(url: url))
        } else if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    static func makeDirectory() throws -> URL {
        _ = cleanupAtFirstUse
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ConsolinotesPreview-\(getpid())-" + UUID().uuidString + ".noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try PrivateWorkingDirectory.excludeFromBackup(directory) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        mutex.lock()
        directories.insert(directory)
        attachments[directory] = [:]
        mutex.unlock()
        return directory
    }

    /// Only remove generated cache directories whose owning process has exited.
    /// Active previews in another instance, unrelated files, symlinks and encryption
    /// recovery directories are deliberately outside this cleanup's scope.
    static func removeAbandonedStaging(in temporary: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) {
        guard let pattern = try? NSRegularExpression(pattern: "^ConsolinotesPreview-([1-9][0-9]*)-[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}(\\.noindex)?$"),
              let children = try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let range = Range(match.range(at: 1), in: name), let pid = Int32(name[range]),
                  pid != getpid(), kill(pid, 0) == -1, errno == ESRCH,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink == false else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    static func remove(_ directory: URL?) {
        guard let directory = directory else { return }
        if directory.scheme == MemoryPreview.scheme { MemoryPreview.remove(directory); return }
        mutex.lock()
        let owned = directories.remove(directory) != nil
        attachments.removeValue(forKey: directory)
        mutex.unlock()
        if owned { try? FileManager.default.removeItem(at: directory) }
    }

    static func purge() {
        MemoryPreview.purge()
        mutex.lock()
        let owned = directories
        directories.removeAll()
        attachments.removeAll()
        mutex.unlock()
        for directory in owned { try? FileManager.default.removeItem(at: directory) }
    }

    static func escapeHTML(_ value: String) -> String {
        return value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    static func decodeAttribute(_ value: String) -> String {
        var result = value
        let entities = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
        for (entity, replacement) in entities { result = result.replacingOccurrences(of: entity, with: replacement) }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Reject traversal before resolving symlinks, then check canonical containment.
    static func attachmentURL(_ path: String, root: URL) -> URL? {
        guard let decoded = decodeAttribute(path).removingPercentEncoding,
              !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.contains("\\"),
              !decoded.contains("\0"), !decoded.split(separator: "/").contains(".."),
              URLComponents(string: decoded)?.scheme == nil else { return nil }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/"),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return candidate
    }

    private static func attachmentLink(_ url: URL, directory: URL) -> String {
        let token = UUID().uuidString.lowercased()
        mutex.lock()
        if directories.contains(directory) { attachments[directory]?[token] = url }
        mutex.unlock()
        return "consolinotes-attachment://" + token
    }

    static func attachment(for link: URL, directory: URL) -> URL? {
        guard link.scheme == "consolinotes-attachment", let token = link.host else { return nil }
        mutex.lock()
        defer { mutex.unlock() }
        return attachments[directory]?[token]
    }

    /// Input comes only from cmark's safe renderer. Raw note HTML is never accepted.
    static func localResources(in html: String, root: URL, directory: URL, interactive: Bool) -> String {
        var html = html
        var copiedImages = [URL: String]()
        var copiedBytes = 0
        let imagePattern = "<img\\s+src=\"([^\"]*)\"[^>]*>"
        if let regex = try? NSRegularExpression(pattern: imagePattern) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let full = Range(match.range, in: html), let pathRange = Range(match.range(at: 1), in: html) else { continue }
                let path = String(html[pathRange])
                var replacement = "<span class=\"blocked-attachment\">[Image unavailable in local-only preview]</span>"
                if let source = attachmentURL(path, root: root) {
                    let ext = source.pathExtension.lowercased()
                    let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
                    if rasterExtensions.contains(ext), size <= maximumAssetBytes {
                        var name = copiedImages[source]
                        if name == nil, copiedImages.count < 256, copiedBytes + size <= 100 * 1024 * 1024,
                           let handle = try? FileHandle(forReadingFrom: source) {
                            let data = handle.readData(ofLength: maximumAssetBytes + 1)
                            handle.closeFile()
                            let candidate = UUID().uuidString + "." + ext
                            let destination = directory.appendingPathComponent(candidate)
                            if data.count <= maximumAssetBytes, (try? data.write(to: destination, options: .atomic)) != nil {
                                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                                copiedImages[source] = candidate
                                copiedBytes += data.count
                                name = candidate
                            }
                        }
                        if let name = name {
                            replacement = "<img class=\"fsnotes-preview\" src=\"" + name + "\" alt=\"" + escapeHTML(source.lastPathComponent) + "\">"
                        }
                    } else if interactive {
                        replacement = "<a href=\"" + attachmentLink(source, directory: directory) + "\">" + escapeHTML(source.lastPathComponent) + "</a>"
                    } else {
                        replacement = "<span>" + escapeHTML(source.lastPathComponent) + "</span>"
                    }
                }
                html.replaceSubrange(full, with: replacement)
            }
        }
        if let regex = try? NSRegularExpression(pattern: "<a href=\"([^\"]*)\"") {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let full = Range(match.range, in: html), let pathRange = Range(match.range(at: 1), in: html) else { continue }
                let path = decodeAttribute(String(html[pathRange]))
                let scheme = URLComponents(string: path)?.scheme?.lowercased()
                if path.hasPrefix("#") || ["https", "http", "mailto", "consolinotes", "fsnotes", "consolinotes-attachment"].contains(scheme ?? "") { continue }
                let replacement: String
                if interactive, let source = attachmentURL(path, root: root) {
                    replacement = "<a href=\"" + attachmentLink(source, directory: directory) + "\""
                } else {
                    replacement = "<a"
                }
                html.replaceSubrange(full, with: replacement)
            }
        }
        return html
    }
}
