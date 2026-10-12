// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.
import Foundation
import WebKit
import UniformTypeIdentifiers

/// Each WebView receives exactly one document capability. Plaintext is never staged.
final class MemoryPreview: NSObject, WKURLSchemeHandler {
    static let scheme = "consolinotes-preview"
    private struct Document {
        var resources: [String: Data]
        var links: [String: URL]
    }
    private static let mutex = NSLock()
    private static var documents = [String: Document]()
    var allowedHost: String?

    static func create(rendered: String, assets: [String: Data], attachmentURL: (String) -> URL?, printing: Bool,
                       template: (String) throws -> String) -> URL? {
        let host = UUID().uuidString.lowercased()
        var resources = [String: Data]()
        var links = [String: URL]()
        var bytes = 0
        var html = rendered
        func asset(_ raw: String) -> (String, Data)? {
            guard let path = LocalPreviewSecurity.decodeAttribute(raw).removingPercentEncoding,
                  !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." }), !path.contains("\\"), !path.contains("\0"),
                  !path.split(separator: "/").contains(".."), let data = assets[path] else { return nil }
            return (path, data)
        }
        func link(_ path: String) -> String? {
            guard !printing, let url = attachmentURL(path) else { return nil }
            let token = UUID().uuidString.lowercased()
            links[token] = url
            return "consolinotes-attachment://" + token
        }
        if let regex = try? NSRegularExpression(pattern: "<img\\s+src=\"([^\"]*)\"[^>]*>") {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let range = Range(match.range, in: html), let src = Range(match.range(at: 1), in: html) else { continue }
                var replacement = "<span>[Image unavailable in local-only preview]</span>"
                if let (path, data) = asset(String(html[src])) {
                    let ext = (path as NSString).pathExtension.lowercased()
                    if LocalPreviewSecurity.rasterExtensions.contains(ext), data.count <= 25 * 1024 * 1024,
                       resources.count < 256, bytes + data.count <= 100 * 1024 * 1024 {
                        let name = "assets/" + UUID().uuidString + "." + ext
                        resources[name] = data; bytes += data.count
                        replacement = "<img src=\"\(name)\" alt=\"Attachment\">"
                    } else if let target = link(path) {
                        replacement = "<a href=\"\(target)\">\(LocalPreviewSecurity.escapeHTML((path as NSString).lastPathComponent))</a>"
                    }
                }
                html.replaceSubrange(range, with: replacement)
            }
        }
        if let regex = try? NSRegularExpression(pattern: "<a href=\"([^\"]*)\"") {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let range = Range(match.range, in: html), let src = Range(match.range(at: 1), in: html) else { continue }
                let path = LocalPreviewSecurity.decodeAttribute(String(html[src]))
                let scheme = URLComponents(string: path)?.scheme?.lowercased() ?? ""
                if path.hasPrefix("#") || ["http", "https", "mailto", "consolinotes", "fsnotes", "consolinotes-attachment"].contains(scheme) { continue }
                let target = asset(path).flatMap { link($0.0) }
                html.replaceSubrange(range, with: target.map { "<a href=\"\($0)\"" } ?? "<a")
            }
        }
        guard let page = try? template(html) else { return nil }
        resources["index.html"] = Data(page.utf8)
        mutex.lock(); documents[host] = Document(resources: resources, links: links); mutex.unlock()
        return URL(string: "\(scheme)://\(host)/index.html")
    }

    static func attachment(_ link: URL, document: URL) -> URL? {
        guard let host = document.host, link.scheme == "consolinotes-attachment", let token = link.host else { return nil }
        mutex.lock(); defer { mutex.unlock() }
        return documents[host]?.links[token]
    }
    static func remove(_ url: URL) {
        guard url.scheme == scheme, let host = url.host else { return }
        mutex.lock(); documents.removeValue(forKey: host); mutex.unlock()
    }
    static func purge() { mutex.lock(); documents.removeAll(); mutex.unlock() }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == Self.scheme,
              let host = url.host, host == allowedHost,
              url.query == nil, url.user == nil, url.password == nil, url.port == nil,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
              !path.contains("\\"), !path.contains("\0"), !path.split(separator: "/").contains("..") else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let name = String(path.dropFirst())
        Self.mutex.lock()
        let document = Self.documents[host]
        var data = document?.resources[name]
        Self.mutex.unlock()
        guard document != nil else { urlSchemeTask.didFailWithError(URLError(.cancelled)); return }
        if data == nil, ["js", "css", "woff", "woff2"].contains(url.pathExtension.lowercased()),
           let bundle = Bundle.main.url(forResource: "MPreview", withExtension: "bundle") {
            let file = bundle.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            let root = bundle.standardizedFileURL.resolvingSymlinksInPath()
            if file.path.hasPrefix(root.path + "/") { data = try? Data(contentsOf: file) }
        }
        guard let bytes = data else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "html": mime = "text/html"
        case "js": mime = "application/javascript"
        case "css": mime = "text/css"
        default: mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        urlSchemeTask.didReceive(bytes)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
