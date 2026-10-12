// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import Darwin
import ZipArchive

/// Each working directory is its own durable inventory record. It intentionally
/// contains no note title, original path or password. A file lock distinguishes
/// another live app instance from an interrupted session, even after PID reuse.
enum EncryptedNoteRecovery {
    private struct Record: Codable {
        let version: Int
        let created: Date
    }
    private static let mutex = NSLock()
    private static var active = [URL: Int32]()

    final class Entry {
        let directory: URL
        let created: Date
        private let descriptor: Int32
        init(directory: URL, created: Date, descriptor: Int32) {
            self.directory = directory
            self.created = created
            self.descriptor = descriptor
        }
        deinit { flock(descriptor, LOCK_UN); close(descriptor) }
        var bundle: URL? {
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
            let bundles = children.filter { $0.pathExtension.lowercased() == "textbundle" }
            guard bundles.count == 1, let bundle = bundles.first,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let metadata = try? PrivateWorkingDirectory.readBoundedFile(bundle.appendingPathComponent("info.json"), maximumBytes: 64 * 1024),
                  let info = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                  let version = info["version"] as? Int, [1, 2].contains(version), info["type"] is String,
                  let files = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil),
                  files.contains(where: { $0.lastPathComponent.hasPrefix("text.") &&
                      (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeRegular }) else { return nil }
            return bundle
        }
    }

    static func register(_ directory: URL) throws {
        let descriptor = try acquire(directory)
        do {
            let record = directory.appendingPathComponent(".session.json")
            try JSONEncoder().encode(Record(version: 1, created: Date())).write(to: record, options: .atomic)
            try PrivateWorkingDirectory.protectFile(record)
            let handle = try FileHandle(forWritingTo: record)
            try handle.synchronize()
            try handle.close()
            mutex.lock()
            active[directory] = descriptor
            mutex.unlock()
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
    }

    static func remove(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        mutex.lock()
        let descriptor = active.removeValue(forKey: directory)
        mutex.unlock()
        if let descriptor = descriptor { flock(descriptor, LOCK_UN); close(descriptor) }
    }

    static func interrupted(roots: [URL]? = nil) -> [Entry] {
        let roots = roots ?? recoveryRoots()
        var entries = [Entry]()
        for root in roots {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for directory in children {
                guard let descriptor = try? acquire(directory) else { continue }
                let metadata = directory.appendingPathComponent(".session.json")
                let record = (try? PrivateWorkingDirectory.readBoundedFile(metadata, maximumBytes: 4096))
                    .flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
                let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
                let date = record?.created ?? attributes?[.creationDate] as? Date ?? Date()
                entries.append(Entry(directory: directory, created: date, descriptor: descriptor))
            }
        }
        return entries.sorted { $0.created < $1.created }
    }

    private static func acquire(_ directory: URL) throws -> Int32 {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw PrivateWorkingDirectory.ProtectionError.unsafeEntry }
        let descriptor = open(directory.appendingPathComponent(".session.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PrivateWorkingDirectory.ProtectionError.unsafeEntry }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PrivateWorkingDirectory.ProtectionError.unsafeEntry
        }
        return descriptor
    }

    private static func recoveryRoots() -> [URL] {
        var roots = [URL]()
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            roots.append(support.appendingPathComponent("ConsolinotesEncryption.noindex"))
        }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        roots.append(temporary.appendingPathComponent("ConsolinotesEncryption.noindex"))
        roots.append(temporary.appendingPathComponent("Encryption"))
        return roots
    }

    /// Restore as a separate encrypted note. Original notes and the recovery
    /// source remain untouched until the new ciphertext is fully committed.
    static func restore(_ entry: Entry, password: String, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path), let bundle = entry.bundle else {
            throw PrivateNoteArchive.ArchiveError.unsupportedContents
        }
        try PrivateNoteArchive.validateSourceDirectory(bundle)
        try PrivateWorkingDirectory.protectTree(bundle)
        let isCancelled = PrivateNoteArchive.cancellationCheck()
        guard let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw PrivateNoteArchive.ArchiveError.unsupportedContents
        }
        var entries = MemoryNoteArchive.Entries()
        var remaining = PrivateNoteArchive.maximumExpandedBytes
        for case let file as URL in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let data = try PrivateWorkingDirectory.readBoundedFile(file, maximumBytes: remaining, isCancelled: isCancelled)
            remaining -= UInt64(data.count)
            entries[String(file.path.dropFirst(bundle.path.count + 1))] = data
        }
        _ = try MemoryNoteWorkspace(entries: entries)
        let data = try MemoryNoteArchive.encode(entries, isCancelled: isCancelled)
        let encrypted = try EncryptedNoteCodec.seal(data, session: EncryptedNoteCodec.makeSession(password: password))
        try EncryptedNoteJournal.atomicWrite(encrypted, to: destination, replacing: false, isCancelled: isCancelled)
    }
}
