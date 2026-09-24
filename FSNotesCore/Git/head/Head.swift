//  Adapted from Git2Swift for FSNotes and distributed in consolinotes.
//  See Licenses/native/Git2Swift.txt and THIRD_PARTY_NOTICES.md.
//
//  Head.swift
//  Git2Swift
//
//  Created by Dami on 31/07/2016.
//
//

import Foundation

/// Head repository
public class Head : Reference {

    /// Head index
    ///
    /// - throws: GitError
    ///
    /// - returns: Git index
    public func index() throws -> Index {
        return try Index(repository: repository)
    }
}
