// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import Darwin

/// Restrictive filesystem helpers for ordinary files, explicit plaintext exports,
/// and recovery of working copies left by older builds. Normal encrypted editing is in memory.
enum PrivateWorkingDirectory {
    enum ProtectionError: Error {
        case unsafeEntry, oversizedFile, cancelled
    }

    /// Check the opened descriptor before allocating, and cap every read in case
    /// another writer grows the file after fstat. Links and special files are refused.
    static func readBoundedFile(_ url: URL, maximumBytes: UInt64,
                                isCancelled: () -> Bool = { false }) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProtectionError.unsafeEntry }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else { throw ProtectionError.unsafeEntry }
        guard UInt64(status.st_size) <= maximumBytes else { throw ProtectionError.oversizedFile }
        var data = Data()
        while true {
            if isCancelled() { throw ProtectionError.cancelled }
            let remaining = maximumBytes - UInt64(data.count)
            // Read one byte past the budget only to detect a file that grew.
            let next = try file.read(upToCount: Int(min(64 * 1024, remaining + 1))) ?? Data()
            guard UInt64(next.count) <= remaining else { throw ProtectionError.oversizedFile }
            if next.isEmpty { return data }
            data.append(next)
        }
    }

    static func makeEncryptionDirectory(in temporary: URL? = nil) throws -> URL {
        let root: URL
        if let temporary = temporary {
            root = temporary.appendingPathComponent("ConsolinotesEncryption.noindex", isDirectory: true)
        } else {
            // Recovery must survive temporary-directory housekeeping after a crash.
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            root = support.appendingPathComponent("ConsolinotesEncryption.noindex", isDirectory: true)
        }
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try protectEntry(root, directory: true)
        try excludeFromBackup(root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try protectEntry(directory, directory: true)
            try excludeFromBackup(directory)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func excludeFromBackup(_ directory: URL) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Reject links and special files before loading an extracted bundle or
    /// packaging a working copy. Never chmod a target outside the working tree.
    static func protectTree(_ directory: URL) throws {
        try protectEntry(directory, directory: true)
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                try protectTree(child)
            } else {
                try protectFile(child)
            }
        }
    }

    static func protectFile(_ url: URL) throws {
        try protectEntry(url, directory: false)
    }

    private static func protectEntry(_ url: URL, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let expected: FileAttributeType = directory ? .typeDirectory : .typeRegular
        guard attributes[.type] as? FileAttributeType == expected,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              directory || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw ProtectionError.unsafeEntry
        }
        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
}
