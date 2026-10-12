// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import ZipArchive
import Darwin

/// ZIP64 metadata is an early guard. Actual streamed output is counted before
/// every write, so a misleading header cannot bypass the expansion budget.
final class PrivateNoteArchive {
    enum ArchiveError: LocalizedError {
        case unsupportedContents, cancelled
        var errorDescription: String? {
            switch self {
            case .unsupportedContents: return "The encrypted note archive is damaged or exceeds its file, depth or expanded-size limits."
            case .cancelled: return "Opening the encrypted note was cancelled."
            }
        }
    }
    static let maximumExpandedBytes: UInt64 = 512 * 1024 * 1024
    static let maximumArchiveBytes: UInt64 = maximumExpandedBytes + 16 * 1024 * 1024
    static let maximumCiphertextBytes: UInt64 = maximumArchiveBytes + 1024 * 1024
    static let maximumEntries = 16_384
    static let maximumDepth = 32

    private static let cancellationLock = NSLock()
    private static var cancellationGeneration: UInt64 = 0

    static func cancelOperations() {
        cancellationLock.lock()
        cancellationGeneration &+= 1
        cancellationLock.unlock()
    }

    static func cancellationCheck() -> () -> Bool {
        cancellationLock.lock()
        let generation = cancellationGeneration
        cancellationLock.unlock()
        return {
            cancellationLock.lock()
            defer { cancellationLock.unlock() }
            return generation != cancellationGeneration || Thread.current.isCancelled
        }
    }

    struct Limits {
        var bytes = PrivateNoteArchive.maximumExpandedBytes
        var entries = PrivateNoteArchive.maximumEntries
        var depth = PrivateNoteArchive.maximumDepth
    }

    static func extract(_ archive: URL, to destination: URL, limits: Limits = Limits(),
                        isCancelled: () -> Bool = { false }) -> Bool {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        var complete = false
        var createdDestination = false
        defer {
            if createdDestination && !complete { try? FileManager.default.removeItem(at: destination) }
        }
        do {
            guard !isCancelled(), let zip = unzOpen64(archive.path) else { throw ArchiveError.unsupportedContents }
            defer { unzClose(zip) }
            var global = unz_global_info64()
            guard unzGetGlobalInfo64(zip, &global) == UNZ_OK,
                  global.number_entry > 0, global.number_entry <= UInt64(limits.entries),
                  unzGoToFirstFile(zip) == UNZ_OK else { throw ArchiveError.unsupportedContents }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            createdDestination = true
            var bytes: UInt64 = 0
            var paths = Set<String>()
            var createdEntries = 0
            var count = 0
            repeat {
                if isCancelled() { throw ArchiveError.cancelled }
                count += 1
                guard count <= limits.entries else { throw ArchiveError.unsupportedContents }
                var info = unz_file_info64()
                guard unzGetCurrentFileInfo64(zip, &info, nil, 0, nil, 0, nil, 0) == UNZ_OK,
                      info.size_filename > 0, info.size_filename <= 4096,
                      info.uncompressed_size <= limits.bytes - bytes else { throw ArchiveError.unsupportedContents }
                var name = [CChar](repeating: 0, count: Int(info.size_filename) + 1)
                guard unzGetCurrentFileInfo64(zip, &info, &name, UInt(name.count), nil, 0, nil, 0) == UNZ_OK,
                      !name.dropLast().contains(0),
                      let path = String(bytes: name.dropLast().map { UInt8(bitPattern: $0) }, encoding: .utf8),
                      !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":") else { throw ArchiveError.unsupportedContents }
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                let isDirectory = path.hasSuffix("/")
                let parts = isDirectory ? Array(components.dropLast()) : components
                guard !parts.isEmpty, parts.count <= limits.depth,
                      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                      paths.insert(parts.joined(separator: "/")).inserted else { throw ArchiveError.unsupportedContents }
                let fileType = (info.external_fa >> 16) & 0o170000
                guard fileType == 0 || fileType == (isDirectory ? 0o040000 : 0o100000),
                      !isDirectory || info.uncompressed_size == 0 else { throw ArchiveError.unsupportedContents }
                let output = destination.appendingPathComponent(parts.joined(separator: "/"), isDirectory: isDirectory)
                try makeParents(output.deletingLastPathComponent(), inside: destination, count: &createdEntries, maximum: limits.entries)
                if isDirectory {
                    if !FileManager.default.fileExists(atPath: output.path) {
                        createdEntries += 1
                        guard createdEntries <= limits.entries else { throw ArchiveError.unsupportedContents }
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    } else {
                        guard try FileManager.default.attributesOfItem(atPath: output.path)[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.unsupportedContents }
                    }
                } else {
                    createdEntries += 1
                    guard createdEntries <= limits.entries else { throw ArchiveError.unsupportedContents }
                    try extractFile(zip, to: output, expectedBytes: info.uncompressed_size, bytes: &bytes,
                                    maximumBytes: limits.bytes, isCancelled: isCancelled)
                }
                let next = unzGoToNextFile(zip)
                if next == UNZ_END_OF_LIST_OF_FILE { break }
                guard next == UNZ_OK else { throw ArchiveError.unsupportedContents }
            } while true
            guard UInt64(count) == global.number_entry, !isCancelled() else { throw ArchiveError.unsupportedContents }
            complete = true
            return true
        } catch { return false }
    }

    private static func makeParents(_ parent: URL, inside root: URL, count: inout Int, maximum: Int) throws {
        if parent.standardizedFileURL.path == root.standardizedFileURL.path { return }
        guard parent.path.hasPrefix(root.path + "/") else { throw ArchiveError.unsupportedContents }
        try makeParents(parent.deletingLastPathComponent(), inside: root, count: &count, maximum: maximum)
        if FileManager.default.fileExists(atPath: parent.path) {
            guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.unsupportedContents }
        } else {
            count += 1
            guard count <= maximum else { throw ArchiveError.unsupportedContents }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }

    private static func extractFile(_ zip: unzFile, to output: URL, expectedBytes: UInt64,
                                    bytes: inout UInt64, maximumBytes: UInt64,
                                    isCancelled: () -> Bool) throws {
        guard unzOpenCurrentFile(zip) == UNZ_OK else { throw ArchiveError.unsupportedContents }
        var closed = false
        defer { if !closed { unzCloseCurrentFile(zip) } }
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveError.unsupportedContents }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var actual: UInt64 = 0
        while true {
            if isCancelled() { throw ArchiveError.cancelled }
            let read = unzReadCurrentFile(zip, &buffer, UInt32(buffer.count))
            guard read >= 0 else { throw ArchiveError.unsupportedContents }
            if read == 0 { break }
            let size = UInt64(read)
            guard size <= maximumBytes - bytes, size <= expectedBytes - actual else { throw ArchiveError.unsupportedContents }
            bytes += size
            actual += size
            try file.write(contentsOf: Data(buffer.prefix(Int(read))))
        }
        let status = unzCloseCurrentFile(zip)
        closed = true
        guard status == UNZ_OK, actual == expectedBytes else { throw ArchiveError.unsupportedContents }
    }

    /// Saving follows the same policy as reopening.
    static func validateSourceDirectory(_ directory: URL, limits: Limits = Limits()) throws {
        var pending = [(directory, 0)]
        var count = 0
        var bytes: UInt64 = 0
        while let (parent, depth) = pending.popLast() {
            guard depth <= limits.depth,
                  try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.unsupportedContents }
            for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                count += 1
                guard count <= limits.entries, depth + 1 <= limits.depth,
                      child.lastPathComponent.utf8.count <= 255,
                      !child.lastPathComponent.contains("\\"), !child.lastPathComponent.contains(":"),
                      child.path.utf8.count - directory.path.utf8.count <= 4096 else { throw ArchiveError.unsupportedContents }
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: pending.append((child, depth + 1))
                case .typeRegular:
                    guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                          size <= limits.bytes - bytes else { throw ArchiveError.unsupportedContents }
                    bytes += size
                default: throw ArchiveError.unsupportedContents
                }
            }
        }
    }
}
