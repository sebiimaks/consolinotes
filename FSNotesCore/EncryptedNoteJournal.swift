// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import Darwin

/// The journal holds a normal authenticated encrypted note, never plaintext.
/// It is written before replacing the original and retained if that save fails.
/// A process-held lock prevents recovery from reading another active session.
final class EncryptedNoteJournal {
    final class Entry {
        let directory: URL
        let created: Date
        fileprivate let descriptor: Int32
        fileprivate init(directory: URL, created: Date, descriptor: Int32) {
            self.directory = directory; self.created = created; self.descriptor = descriptor
        }
        deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    }
    let directory: URL
    private var descriptor: Int32 = -1
    private var snapshot: URL { directory.appendingPathComponent("note.etp") }

    init(root: URL? = nil) throws {
        let parent = try root ?? Self.root()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Self.protectDirectory(parent)
        try PrivateWorkingDirectory.excludeFromBackup(parent)
        directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            descriptor = try Self.acquire(directory)
            // Publish the directory hierarchy durably before snapshots depend
            // on it. atomicWrite separately syncs the snapshot's own directory.
            try Self.syncDirectory(parent)
            try Self.syncDirectory(parent.deletingLastPathComponent())
        } catch {
            if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }

    func write(_ encrypted: Data) throws {
        guard UInt64(encrypted.count) <= PrivateNoteArchive.maximumCiphertextBytes else { throw PrivateNoteArchive.ArchiveError.unsupportedContents }
        try Self.atomicWrite(encrypted, to: snapshot, replacing: true)
    }

    func clearCommittedSnapshot() throws {
        if FileManager.default.fileExists(atPath: snapshot.path) { try FileManager.default.removeItem(at: snapshot) }
    }

    func closeAndRemove() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }

    static func interrupted(root: URL? = nil) -> [Entry] {
        guard let parent = try? root ?? Self.root(),
              (try? protectDirectory(parent)) != nil,
              let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return [] }
        return children.compactMap { directory in
            guard let descriptor = try? acquire(directory) else { return nil }
            let snapshot = directory.appendingPathComponent("note.etp")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                flock(descriptor, LOCK_UN); close(descriptor)
                // An empty session can result after a fully committed save.
                // Leave it alone rather than guessing about interrupted files.
                return nil
            }
            return Entry(directory: directory, created: attributes[.modificationDate] as? Date ?? Date(), descriptor: descriptor)
        }.sorted { $0.created < $1.created }
    }

    static func restore(_ entry: Entry, password: String, to destination: URL) throws {
        let isCancelled = PrivateNoteArchive.cancellationCheck()
        let encrypted = try PrivateWorkingDirectory.readBoundedFile(entry.directory.appendingPathComponent("note.etp"), maximumBytes: PrivateNoteArchive.maximumCiphertextBytes, isCancelled: isCancelled)
        let opened = try EncryptedNoteCodec.open(encrypted, password: password)
        _ = try MemoryNoteWorkspace(entries: MemoryNoteArchive.decode(opened.data, isCancelled: isCancelled))
        try atomicWrite(encrypted, to: destination, replacing: false, isCancelled: isCancelled)
    }

    static func discard(_ entry: Entry) throws { try FileManager.default.removeItem(at: entry.directory) }

    /// Atomic publication with private creation mode and fsync before/after
    /// rename. Any thrown error leaves the caller's in-memory edits untouched.
    enum PublicationError: Error { case durabilityUnconfirmed }

    static func atomicWrite(_ data: Data, to destination: URL, replacing: Bool,
                            isCancelled: () -> Bool = { false },
                            verify: ((Data) throws -> Void)? = nil) throws {
        guard !isCancelled() else { throw PrivateNoteArchive.ArchiveError.cancelled }
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("." + UUID().uuidString + ".encrypted")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staging) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if let verify = verify {
            try verify(PrivateWorkingDirectory.readBoundedFile(staging, maximumBytes: PrivateNoteArchive.maximumCiphertextBytes, isCancelled: isCancelled))
        }
        guard !isCancelled() else { throw PrivateNoteArchive.ArchiveError.cancelled }
        let result = replacing ? rename(staging.path, destination.path) : renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown) }
        let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw PublicationError.durabilityUnconfirmed }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw PublicationError.durabilityUnconfirmed }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func root() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ConsolinotesEncryptedRecovery.noindex", isDirectory: true)
    }
    private static func protectDirectory(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw PrivateWorkingDirectory.ProtectionError.unsafeEntry }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private static func acquire(_ directory: URL) throws -> Int32 {
        try protectDirectory(directory)
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PrivateWorkingDirectory.ProtectionError.unsafeEntry }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, status.st_uid == geteuid(),
              status.st_nlink == 1, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw PrivateWorkingDirectory.ProtectionError.unsafeEntry
        }
        return descriptor
    }
}
