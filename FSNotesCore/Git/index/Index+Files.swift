//  Adapted from Git2Swift for FSNotes and distributed in consolinotes.
//  See Licenses/native/Git2Swift.txt and THIRD_PARTY_NOTICES.md.
//
//  Index+Files.swift
//  Git2Swift
//
//  Created by Damien Giron on 01/08/2016.
//
//

import Foundation
import Cgit2

///
/// Find relative path to an other url.
///
func relativePath(from: URL, to: URL) -> String? {
    
    // Find current file path
    let currentFilePath = from.absoluteURL.path
    
    // Find from path
    let fromFilePath = to.path
    
    // Check if current URL is parent of from
    guard (currentFilePath.hasPrefix(fromFilePath)) else {
        return nil
    }
    
    // Find prefix size
    let size = fromFilePath.count + (currentFilePath[currentFilePath.startIndex] == "/" ? 1 : 0 )
    
    let startIndex = currentFilePath.index(currentFilePath.startIndex, offsetBy: size)

    // Return sub string
    return String(currentFilePath[startIndex...])
}

// MARK: - Index extension for files
extension Index {
    
    /// Add item
    ///
    /// - parameter url: URL of the item
    ///
    /// - throws: GitError
    public func addItem(at url: URL) throws {
        
        // Create relative path
        guard let path = relativePath(from: url, to: repository.url) else {
            throw GitError.notFound(ref: url.absoluteString)
        }
        
        let error = git_index_add_bypath(idx.pointee, path);
        if (error != 0) {
            throw gitUnknownError("Unable to add item to index", code: error)
        }
    }
    
    /// Add item
    ///
    /// - parameter url: URL of the item
    ///
    /// - throws: GitError
    public func addItem(data: Data, at path: String) throws {
        var index_entry = git_index_entry()
        try path.withCString { (ptr: UnsafePointer<Int8>) -> Void in
            index_entry.path = ptr
            index_entry.mode = 33188
            /* create a blob from our buffer */
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Void in
                let error = git_index_add_frombuffer(idx.pointee, &index_entry, bytes.baseAddress, data.count)
                if error != 0 {
                    throw gitUnknownError("Unable to add Data to index", code: error)
                }
            }
        }
    }
    
    /// Remove item
    ///
    /// - parameter url: URL of the item
    ///
    /// - throws: GitError
    public func removeItem(at url: URL) throws {
        
        // Create relative path
        guard let path = relativePath(from: url, to: repository.url) else {
            throw GitError.notFound(ref: url.absoluteString)
        }
        
        let error = git_index_remove_bypath(idx.pointee, path)
        if (error != 0) {
            throw gitUnknownError("Unable to remove item to index", code: error)
        }
    }
    
    /// Save index
    ///
    /// - throws: GitError
    public func save() throws {
        let error = git_index_write(idx.pointee)
        if (error != 0) {
            throw gitUnknownError("Unable to save index", code: error)
        }
    }
    
    /// Reload index
    ///
    /// - throws: GitError
    public func reload() throws {
        let error = git_index_read(idx.pointee, 1); // A for true
        if (error != 0) {
            throw gitUnknownError("Unable to read index", code: error)
        }
    }
    
    /// Clear index
    ///
    /// - throws: GitError
    public func clear() throws {
        let error = git_index_clear(idx.pointee);
        if (error != 0) {
            throw gitUnknownError("Unable to read index", code: error)
        }
    }

    private static let gitIndexCallback: git_index_matched_path_cb = { path, _, payload in
        guard let path = path, let payload = payload else { return -1 }
        let relativePath = String(cString: path)
        if relativePath == ".Trash" || relativePath.hasPrefix(".Trash/") {
            return 1
        }
        payload.assumingMemoryBound(to: Int.self).pointee += 1
        return 0
    }

    /// Stage local files while preserving this Index's ownership until deinit.
    /// A failed native write must propagate to the caller instead of looking like
    /// a successful empty change set.
    public func add(path: String) throws -> Bool {
        guard let index = idx.pointee else {
            throw GitError.notFound(ref: "index")
        }
        var matchedCount = 0
        try path.withCString { cPath in
            var pathPointer: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: cPath)
            try withUnsafeMutablePointer(to: &pathPointer) { pointer in
                var paths = git_strarray(strings: pointer, count: 1)
                try withUnsafeMutablePointer(to: &matchedCount) { count in
                    let result = git_index_add_all(index, &paths, 0, Index.gitIndexCallback, count)
                    if result != GIT_OK.rawValue {
                        throw gitUnknownError("Unable to stage local history", code: result)
                    }
                }
            }
        }
        let result = git_index_write(index)
        if result != GIT_OK.rawValue {
            throw gitUnknownError("Unable to save local history index", code: result)
        }
        return matchedCount > 0
    }
}
