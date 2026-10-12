//  Adapted from Git2Swift for FSNotes and distributed in consolinotes.
//  See Licenses/native/Git2Swift.txt and THIRD_PARTY_NOTICES.md.
//
//  Diff.swift
//  Git2Swift
//
//  Created by Damien Giron on 20/09/2016.
//  Copyright © 2016 Creabox. All rights reserved.
//

import Foundation

import Cgit2

/// Define internal object to cast and use with C hander
class InternalDiffWrapper {
    
    /// Diff object
    var diff : Diff
    
    /// Entries parsed
    var entries = Dictionary<String, Bool>()
    
    init(_ diff: Diff) {
        self.diff = diff
    }
}

/// Diff
public class Diff {
    
    public static var commitsDict = ["sha": [String]()]

    /// Internal Diff pointer
    internal let pointer : UnsafeMutablePointer<OpaquePointer?>
    
    // Init with libgit2 diff pointer
    init(pointer: UnsafeMutablePointer<OpaquePointer?>) {
        self.pointer = pointer
    }
    
    deinit {
        if let ptr = pointer.pointee {
            git_diff_free(ptr)
        }
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    
    /// Find diff entry by path
    public func find(byPath path: String, oid: OID, project: Project? = nil) -> Bool {
        project?.loadCommitsCache()
        
        guard let sha = oid.sha() else { return false }
        
        if let project = project, let paths = project.commitsCache[sha] {
            return paths.contains(path)
        }
        
        // Create internal object to convert in C pointer
        let payload = InternalDiffWrapper(self)
        
        // COnvert in C pointer
        let ptr = Unmanaged.passUnretained(payload).toOpaque()
        
        // Foreach on all diff entries
        let error = git_diff_foreach(self.pointer.pointee, DiffFile.callback, nil, nil, nil, ptr)
        guard error == 0 else { return false }

        if let project = project {
            project.commitsCache[sha] = Array(payload.entries.keys)
        }

        return payload.entries[path] != nil
    }
}

final class DiffFile{
    static let callback: git_diff_file_cb = { delta, progress, payload in 
        if let delta = delta, let payload = payload {
            let result = Unmanaged<InternalDiffWrapper>.fromOpaque(payload).takeUnretainedValue()
            // Create diff entry
            let diffEntry = DiffEntry(delta: delta)
            
            // Test old name
            if let oldName = diffEntry.oldName {
                result.entries[oldName] = true
            }
            
            // Test new name
            if let newName = diffEntry.newName {
                result.entries[newName] = true
            }
        }
        
        return 0
    }
}
