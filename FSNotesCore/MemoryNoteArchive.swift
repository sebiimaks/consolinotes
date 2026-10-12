// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import ZipArchive

/// ZIP compatibility without an intermediate plaintext file. The reader uses
/// the pinned native decompressor with streamed actual-output budgets. The
/// writer emits standard uncompressed ZIP members; outer note encryption and
/// authentication are unchanged for both modern and legacy envelopes.
enum MemoryNoteArchive {
    typealias Entries = [String: Data]
    typealias ArchiveError = PrivateNoteArchive.ArchiveError

    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= PrivateNoteArchive.maximumDepth && path.utf8.count <= 4096 &&
            !path.contains("\\") && !path.contains(":") && !path.contains("\0") &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }

    static func validate(_ entries: Entries, limits: PrivateNoteArchive.Limits = .init()) throws {
        guard !entries.isEmpty, entries.count <= limits.entries else { throw ArchiveError.unsupportedContents }
        var expanded: UInt64 = 0
        var directories = Set<String>()
        for (path, data) in entries {
            let parts = path.split(separator: "/")
            guard safePath(path), parts.count <= limits.depth,
                  UInt64(data.count) <= limits.bytes - expanded else { throw ArchiveError.unsupportedContents }
            expanded += UInt64(data.count)
            for depth in 1..<parts.count {
                let parent = parts.prefix(depth).joined(separator: "/")
                guard entries[parent] == nil else { throw ArchiveError.unsupportedContents }
                directories.insert(parent)
            }
            guard entries.count + directories.count <= limits.entries else { throw ArchiveError.unsupportedContents }
        }
    }

    static func decode(_ data: Data, limits: PrivateNoteArchive.Limits = .init(),
                       isCancelled: () -> Bool = { false }) throws -> Entries {
        guard !data.isEmpty, UInt64(data.count) <= PrivateNoteArchive.maximumArchiveBytes, data.count <= Int(Int32.max),
              !isCancelled() else { throw ArchiveError.unsupportedContents }
        return try data.withUnsafeBytes { raw -> Entries in
            var stream: UnsafeMutableRawPointer?
            guard mz_stream_mem_create(&stream) != nil, let memory = stream, let base = raw.baseAddress else { throw ArchiveError.unsupportedContents }
            mz_stream_mem_set_buffer(memory, UnsafeMutableRawPointer(mutating: base), Int32(data.count))
            guard mz_stream_mem_open(memory, nil, 1) == 0, let archive = unzOpen_MZ(memory) else {
                mz_stream_mem_delete(&stream)
                throw ArchiveError.unsupportedContents
            }
            defer { unzClose(archive) }
            var global = unz_global_info64()
            guard unzGetGlobalInfo64(archive, &global) == UNZ_OK,
                  global.number_entry > 0, global.number_entry <= UInt64(limits.entries),
                  unzGoToFirstFile(archive) == UNZ_OK else { throw ArchiveError.unsupportedContents }
            var entries = Entries()
            var paths = Set<String>()
            var directories = Set<String>()
            var total: UInt64 = 0
            var count = 0
            repeat {
                guard !isCancelled() else { throw ArchiveError.cancelled }
                count += 1
                guard count <= limits.entries else { throw ArchiveError.unsupportedContents }
                var info = unz_file_info64()
                guard unzGetCurrentFileInfo64(archive, &info, nil, 0, nil, 0, nil, 0) == UNZ_OK,
                      info.size_filename > 0, info.size_filename <= 4096,
                      info.uncompressed_size <= limits.bytes - total else { throw ArchiveError.unsupportedContents }
                var filename = [CChar](repeating: 0, count: Int(info.size_filename) + 1)
                guard unzGetCurrentFileInfo64(archive, &info, &filename, UInt(filename.count), nil, 0, nil, 0) == UNZ_OK,
                      !filename.dropLast().contains(0),
                      let original = String(bytes: filename.dropLast().map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw ArchiveError.unsupportedContents }
                let directory = original.hasSuffix("/")
                let path = directory ? String(original.dropLast()) : original
                let parts = path.split(separator: "/")
                guard safePath(path), parts.count <= limits.depth, paths.insert(path).inserted else { throw ArchiveError.unsupportedContents }
                let fileType = (info.external_fa >> 16) & 0o170000
                guard fileType == 0 || fileType == (directory ? 0o040000 : 0o100000) else { throw ArchiveError.unsupportedContents }
                for depth in 1..<parts.count {
                    let parent = parts.prefix(depth).joined(separator: "/")
                    guard entries[parent] == nil else { throw ArchiveError.unsupportedContents }
                    directories.insert(parent)
                }
                if directory {
                    guard info.uncompressed_size == 0, entries[path] == nil else { throw ArchiveError.unsupportedContents }
                    directories.insert(path)
                } else {
                    guard !directories.contains(path) else { throw ArchiveError.unsupportedContents }
                    entries[path] = try readMember(archive, expected: info.uncompressed_size, total: &total,
                                                   maximum: limits.bytes, isCancelled: isCancelled)
                }
                guard entries.count + directories.count <= limits.entries else { throw ArchiveError.unsupportedContents }
                let next = unzGoToNextFile(archive)
                if next == UNZ_END_OF_LIST_OF_FILE { break }
                guard next == UNZ_OK else { throw ArchiveError.unsupportedContents }
            } while true
            guard UInt64(count) == global.number_entry else { throw ArchiveError.unsupportedContents }
            guard !isCancelled() else { throw ArchiveError.cancelled }
            try validate(entries, limits: limits)
            return entries
        }
    }

    private static func readMember(_ archive: unzFile, expected: UInt64, total: inout UInt64,
                                   maximum: UInt64, isCancelled: () -> Bool) throws -> Data {
        guard unzOpenCurrentFile(archive) == UNZ_OK else { throw ArchiveError.unsupportedContents }
        var closed = false
        defer { if !closed { unzCloseCurrentFile(archive) } }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard !isCancelled() else { throw ArchiveError.cancelled }
            let length = unzReadCurrentFile(archive, &buffer, UInt32(buffer.count))
            guard length >= 0 else { throw ArchiveError.unsupportedContents }
            if length == 0 { break }
            let count = UInt64(length)
            guard count <= maximum - total, count <= expected - UInt64(output.count) else { throw ArchiveError.unsupportedContents }
            total += count
            output.append(contentsOf: buffer.prefix(Int(length)))
        }
        let result = unzCloseCurrentFile(archive)
        closed = true
        guard result == UNZ_OK, UInt64(output.count) == expected else { throw ArchiveError.unsupportedContents }
        return output
    }

    static func encode(_ entries: Entries, isCancelled: () -> Bool = { false }) throws -> Data {
        try validate(entries)
        var output = Data()
        var central = Data()
        for path in entries.keys.sorted() {
            guard !isCancelled() else { throw ArchiveError.cancelled }
            let body = entries[path]!
            let name = Data(path.utf8)
            let checksum = body.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(body.count))) }
            guard output.count <= Int(UInt32.max), body.count <= Int(UInt32.max) else { throw ArchiveError.unsupportedContents }
            let offset = UInt32(output.count)
            output.le(UInt32(0x04034b50)); output.le(UInt16(20)); output.le(UInt16(0x0800))
            output.le(UInt16(0)); output.le(UInt16(0)); output.le(UInt16(0))
            output.le(checksum); output.le(UInt32(body.count)); output.le(UInt32(body.count))
            output.le(UInt16(name.count)); output.le(UInt16(0)); output.append(name); output.append(body)
            central.le(UInt32(0x02014b50)); central.le(UInt16(0x0314)); central.le(UInt16(20)); central.le(UInt16(0x0800))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(checksum)
            central.le(UInt32(body.count)); central.le(UInt32(body.count)); central.le(UInt16(name.count))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(UInt32(0o100600 << 16)); central.le(offset); central.append(name)
            guard UInt64(output.count + central.count + 22) <= PrivateNoteArchive.maximumArchiveBytes else { throw ArchiveError.unsupportedContents }
        }
        let offset = UInt32(output.count)
        output.append(central)
        output.le(UInt32(0x06054b50)); output.le(UInt16(0)); output.le(UInt16(0))
        output.le(UInt16(entries.count)); output.le(UInt16(entries.count))
        output.le(UInt32(central.count)); output.le(offset); output.le(UInt16(0))
        guard !isCancelled() else { throw ArchiveError.cancelled }
        return output
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
