// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation

/// A decrypted note is an in-memory bundle. Its opaque attachment URLs cannot
/// be opened by another application or accidentally interpreted as file paths.
final class MemoryNoteWorkspace {
    let identifier = UUID().uuidString.lowercased()
    private(set) var entries: MemoryNoteArchive.Entries
    let typeIdentifier: String
    let bodyPath: String

    init(entries: MemoryNoteArchive.Entries, preferredExtension: String? = nil) throws {
        try MemoryNoteArchive.validate(entries)
        guard let metadata = entries["info.json"], metadata.count <= 64 * 1024,
              let info = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let version = info["version"] as? Int, [1, 2].contains(version),
              let type = info["type"] as? String else { throw PrivateNoteArchive.ArchiveError.unsupportedContents }
        let bodies = entries.keys.filter { !$0.contains("/") && $0.hasPrefix("text.") }.sorted()
        let preferred = preferredExtension.map { "text." + $0 }
        guard let body = preferred.flatMap({ entries[$0] == nil ? nil : $0 }) ?? bodies.first else { throw PrivateNoteArchive.ArchiveError.unsupportedContents }
        self.entries = entries
        typeIdentifier = type
        bodyPath = body
    }

    var body: Data { entries[bodyPath]! }

    func setBody(_ data: Data) throws {
        var candidate = entries
        candidate[bodyPath] = data
        try MemoryNoteArchive.validate(candidate)
        entries = candidate
    }

    func setMetadata(_ data: Data) throws {
        guard data.count <= 64 * 1024 else { throw PrivateNoteArchive.ArchiveError.unsupportedContents }
        var candidate = entries
        candidate["info.json"] = data
        _ = try MemoryNoteWorkspace(entries: candidate)
        entries = candidate
    }

    func set(_ data: Data, at path: String) throws {
        guard MemoryNoteArchive.safePath(path), path != "info.json", path != bodyPath else { throw PrivateNoteArchive.ArchiveError.unsupportedContents }
        var candidate = entries
        candidate[path] = data
        try MemoryNoteArchive.validate(candidate)
        entries = candidate
    }

    func remove(at path: String) -> Bool {
        guard path != bodyPath, path != "info.json" else { return false }
        return entries.removeValue(forKey: path) != nil
    }

    func url(for path: String) -> URL? {
        guard MemoryNoteArchive.safePath(path), entries[path] != nil else { return nil }
        var components = URLComponents()
        components.scheme = "consolinotes-memory"
        components.host = identifier
        components.path = "/" + path
        return components.url
    }

    func path(for url: URL) -> String? {
        guard url.scheme == "consolinotes-memory", url.host == identifier,
              url.query == nil, url.fragment == nil else { return nil }
        let path = String(url.path.dropFirst())
        return MemoryNoteArchive.safePath(path) ? path : nil
    }

    func attachmentData(for url: URL) -> Data? {
        guard let path = path(for: url), path != bodyPath, path != "info.json" else { return nil }
        return entries[path]
    }

    var attachments: [String: Data] { entries.filter { $0.key != bodyPath && $0.key != "info.json" } }

    /// Only explicit plaintext conversion/export calls this method. Normal
    /// editing, preview, lock and persistence never materialize the bundle.
    func exportPlaintext(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try MemoryNoteArchive.validate(entries)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (path, data) in entries {
                let file = destination.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: file, options: .withoutOverwriting)
                try PrivateWorkingDirectory.protectFile(file)
            }
            try PrivateWorkingDirectory.excludeFromBackup(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
