//  Adapted from Git2Swift for FSNotes and distributed in consolinotes.
//  See Licenses/native/Git2Swift.txt and THIRD_PARTY_NOTICES.md.
//
//  Repository.swift
//  Git2Swift
//
//  Created by Damien Giron on 31/07/2016.
//  Copyright © 2016 Creabox. All rights reserved.
//

import Foundation
import Cgit2

/// Repository wrapping a libgit2 repository
public class Repository {
    
    /// Repository URL
    public let url : URL
    
    /// Repository manager
    private let manager : RepositoryManager
    
    /// Libgit2 pointer to repository
    internal let pointer : UnsafeMutablePointer<OpaquePointer?>
    
    /// Branches manager
    lazy public private(set) var branches : Branches = {
        Branches(repository: self)
    } ()
    
    /// Statuses manager
    lazy public private(set) var statuses : Statuses = {
        Statuses(repository: self)
    } ()
    
    /// Access tags manager
    lazy public private(set) var tags : Tags = {
        Tags(repository: self)
    } ()
    
    
    /// Constructor with repository manager and libgit2 repository
    ///
    /// - parameter url:        URL repository
    /// - parameter manager:    Repository manager
    /// - parameter repository: Libgit2 repository
    ///
    /// - returns: Repository
    init(at url: URL, manager: RepositoryManager, repository: UnsafeMutablePointer<OpaquePointer?>) {
        self.url = url
        self.manager = manager
        self.pointer = repository
    }
    
    deinit {
        if let ptr = pointer.pointee {
            git_repository_free(ptr)
        }
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    
    /// Retrieve head
    ///
    /// - throws: GitError
    ///
    /// - returns: Head
    public func head() throws -> Head {
        // Create head
        return try Head(repository: self, name: "HEAD", pointer: try gitReferenceLookup(repository: pointer, name: "HEAD"))
    }

    /// Retrieve the local branch referenced by HEAD.
    public func currentBranch() throws -> Branch {
        let reference = try head().targetReference()
        return try branches.get(spec: reference.name)
    }
    
    /// Get the index for the repo. The caller is responsible for freeing the index.
    func unsafeIndex() -> Result<OpaquePointer, NSError> {
        guard let ptr = pointer.pointee else { return .failure(NSError()) }
        
        var index: OpaquePointer? = nil
        let result = git_repository_index(&index, ptr)
        guard result == GIT_OK.rawValue && index != nil else {
            let err = NSError(gitError: result, pointOfFailure: "git_repository_index")
            return .failure(err)
        }
        return .success(index!)
    }
    
    public func add(path: String) -> Result<(), NSError> {
        return unsafeIndex().flatMap { index in
            defer { git_index_free(index) }
            let addResult = path.withCString { cPath in
                var pathPointer: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: cPath)
                return withUnsafeMutablePointer(to: &pathPointer) { pointer in
                    var paths = git_strarray(strings: pointer, count: 1)
                    return git_index_add_all(index, &paths, 0, nil, nil)
                }
            }
            guard addResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: addResult, pointOfFailure: "git_index_add_all"))
            }
            let writeResult = git_index_write(index)
            guard writeResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: writeResult, pointOfFailure: "git_index_write"))
            }
            return .success(())
        }
    }

    public func setWorkTree(path: String) {
        var configPointer: OpaquePointer? = nil
        
        var result = git_repository_config(&configPointer, self.pointer.pointee)
        guard result == GIT_OK.rawValue else { return }
        defer { git_config_free(configPointer) }
        
        result = git_config_set_string(configPointer, "core.worktree", path);
        if result != GIT_OK.rawValue {
            print("Core config error")
        }
    }
    
    public func checkout(commit: Commit, path: String) throws {
        try path.withCString { cPath in
            var pathPointer: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: cPath)
            try withUnsafeMutablePointer(to: &pathPointer) { pointer in
                var options = git_checkout_options()
                git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                options.paths = git_strarray(strings: pointer, count: 1)
                options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                let result = git_checkout_tree(self.pointer.pointee, commit.pointer.pointee, &options)
                if result != GIT_OK.rawValue {
                    throw gitUnknownError("Unable to checkout commit path", code: result)
                }
            }
        }
    }
}
