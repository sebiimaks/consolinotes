// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import CryptoKit
import Darwin

/// Private-library setup is explicit and transactional. Migration never deletes
/// the source; a verified copy is published before the caller changes settings.
final class PrivateLibraryManager {
    enum LibraryError: LocalizedError {
        case unsafeEntry, destinationExists, sourceChanged, verificationFailed
        var errorDescription: String? {
            switch self {
            case .unsafeEntry: return "The library contains a link, special file, or an item owned by another user. No library settings were changed."
            case .destinationExists: return "The destination already exists. Choose another destination."
            case .sourceChanged: return "The source changed during copying. Your original files were kept; please try again."
            case .verificationFailed: return "The copied files could not be verified. Your original library was kept."
            }
        }
    }
    let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL }
    static var system: PrivateLibraryManager? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            PrivateLibraryManager(directory: $0.appendingPathComponent("ConsolinotesLibraries.noindex", isDirectory: true))
        }
    }

    func create(backupIncluded: Bool) throws -> URL {
        try prepareParent()
        let library = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try setBackupIncluded(backupIncluded, at: library)
            try syncDirectory(directory)
            return library
        } catch { try? FileManager.default.removeItem(at: library); throw error }
    }

    func copy(source: URL, backupIncluded: Bool) throws -> URL {
        try prepareParent()
        let source = source.standardizedFileURL
        let sourcePath = source.resolvingSymlinksInPath().path
        let destinationPath = directory.resolvingSymlinksInPath().path
        guard !destinationPath.hasPrefix(sourcePath + "/"), sourcePath != destinationPath else { throw LibraryError.unsafeEntry }
        let before = try manifest(source)
        let staging = directory.appendingPathComponent("." + UUID().uuidString + ".copying", isDirectory: true)
        let destination = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        try FileManager.default.copyItem(at: source, to: staging)
        try protectTree(staging)
        guard try manifest(source) == before else { throw LibraryError.sourceChanged }
        guard try manifest(staging) == before else { throw LibraryError.verificationFailed }
        try setBackupIncluded(backupIncluded, at: staging)
        try syncTree(staging)
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw LibraryError.destinationExists }
        published = true
        try syncDirectory(directory)
        return destination
    }

    func setBackupIncluded(_ included: Bool, at library: URL) throws {
        guard contains(library) else { throw LibraryError.unsafeEntry }
        var url = library
        var values = URLResourceValues()
        values.isExcludedFromBackup = !included
        try url.setResourceValues(values)
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(directory.path + "/")
    }

    private func prepareParent() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try validate(directory, directory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func validate(_ url: URL, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              directory || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw LibraryError.unsafeEntry }
    }

    private func manifest(_ root: URL) throws -> [String: String] {
        try validate(root, directory: true)
        var result = [String: String]()
        func visit(_ parent: URL, prefix: String) throws {
            for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let path = prefix + url.lastPathComponent
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    try validate(url, directory: true)
                    result[path] = "directory"
                    try visit(url, prefix: path + "/")
                } else {
                    try validate(url, directory: false)
                    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw LibraryError.unsafeEntry }
                    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? file.close() }
                    var state = stat()
                    guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
                          state.st_uid == geteuid(), state.st_nlink == 1 else { throw LibraryError.unsafeEntry }
                    var hash = SHA256()
                    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
                    result[path] = hash.finalize().map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        try visit(root, prefix: "")
        return result
    }

    private func protectTree(_ root: URL) throws {
        try validate(root, directory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { try protectTree(url) }
            else {
                try validate(url, directory: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func syncTree(_ root: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { try syncTree(url) }
            else {
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.synchronize()
            }
        }
        try syncDirectory(root)
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
