// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import ZipArchive

/// SSZipArchive sanitizes member paths. Additionally refuse links before any
/// link is created and limit supported note sizes. The delegate's size fields
/// are 32-bit, so its early size check is only a guard, not a complete ZIP64
/// decompression budget. Validate actual extracted files before loading them.
final class PrivateNoteArchive: NSObject, SSZipArchiveDelegate {
    enum ArchiveError: LocalizedError {
        case unsupportedContents
        var errorDescription: String? {
            "The encrypted note must contain only regular files and folders, with at most 16,384 entries and 512 MiB of expanded content."
        }
    }
    static let maximumExpandedBytes: UInt64 = 512 * 1024 * 1024
    static let maximumEntries = 16_384
    private var expandedBytes: UInt64 = 0

    static func extract(_ archive: URL, to destination: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        let policy = PrivateNoteArchive()
        guard SSZipArchive.unzipFile(atPath: archive.path, toDestination: destination.path, delegate: policy) else { return false }
        return (try? validateSourceDirectory(destination)) != nil
    }

    /// Apply the same limits before writing an archive so a successful save
    /// cannot produce a note that this app would refuse to reopen.
    static func validateSourceDirectory(_ directory: URL) throws {
        var pending = [directory]
        var count = 0
        var bytes: UInt64 = 0
        while let parent = pending.popLast() {
            guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ArchiveError.unsupportedContents
            }
            for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                count += 1
                guard count < maximumEntries else { throw ArchiveError.unsupportedContents }
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: pending.append(child)
                case .typeRegular:
                    guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                          size <= maximumExpandedBytes - bytes else { throw ArchiveError.unsupportedContents }
                    bytes += size
                default: throw ArchiveError.unsupportedContents
                }
            }
        }
    }

    func zipArchiveShouldUnzipFile(at fileIndex: Int, totalFiles: Int, archivePath: String, fileInfo: unz_file_info) -> Bool {
        let fileType = (fileInfo.external_fa >> 16) & 0o170000
        guard totalFiles > 0, totalFiles <= Self.maximumEntries,
              fileIndex >= 0, fileIndex < Self.maximumEntries,
              fileInfo.size_filename > 0, fileInfo.size_filename <= 4_096,
              fileType == 0 || fileType == 0o100000 || fileType == 0o040000 else { return false }
        let size = UInt64(fileInfo.uncompressed_size)
        guard size <= Self.maximumExpandedBytes - expandedBytes else { return false }
        expandedBytes += size
        return true
    }
}
