// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import Darwin

/// Plaintext working copies are still needed by the TextBundle/archive pipeline.
/// This limits incidental access and indexing; it does not encrypt working files.
enum PrivateWorkingDirectory {
    enum ProtectionError: Error {
        case unsafeEntry
    }

    static func makeEncryptionDirectory(in temporary: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) throws -> URL {
        let root = temporary.appendingPathComponent("ConsolinotesEncryption.noindex", isDirectory: true)
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
