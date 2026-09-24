import Foundation
import Shout

/// Keeps the licence notices beside the assets distributed by web publishing.
enum WebPublishingLicenses {
    static func files(in bundle: Bundle = .main) throws -> [URL] {
        guard let bundleURL = bundle.url(forResource: "MPreview", withExtension: "bundle") else {
            throw CocoaError(.fileNoSuchFile)
        }

        let files = ["LICENSE", "THIRD_PARTY_NOTICES.md"].map {
            bundleURL.appendingPathComponent($0)
        }
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  FileManager.default.isReadableFile(atPath: file.path) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        return files
    }

    static func upload(using sftp: SFTP, to remoteRoot: String, permissions: FilePermissions? = nil) throws {
        guard !remoteRoot.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: remoteRoot])
        }

        // Read every notice before the first remote write, so an incomplete app
        // bundle cannot publish only part of the required acknowledgement set.
        let notices = try files().map { (name: $0.lastPathComponent, data: try Data(contentsOf: $0)) }
        let root = remoteRoot.hasSuffix("/") ? remoteRoot : remoteRoot + "/"

        for notice in notices {
            let destination = root + notice.name
            let temporary = root + "." + notice.name + "." + UUID().uuidString + ".tmp"
            do {
                // Shout's upload does not truncate an existing file. A unique
                // temporary file avoids leaving an older notice's trailing bytes.
                try sftp.upload(data: notice.data, remotePath: temporary, permissions: permissions ?? .default)
                try sftp.rename(src: temporary, dest: destination, override: true)
            } catch {
                // Never remove the published notice as a fallback. A failed
                // upload or replacement leaves that existing notice available.
                try? sftp.removeFile(temporary)
                throw error
            }
        }
    }
}
