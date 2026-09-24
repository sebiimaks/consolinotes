//  Adapted from Git2Swift for FSNotes and distributed in consolinotes.
//  See Licenses/native/Git2Swift.txt and THIRD_PARTY_NOTICES.md.
//
//  Object.swift
//  Git2Swift
//
//  Created by Damien Giron on 01/08/2016.
//
//

import Foundation

/// Object
public protocol Object {
    
    /// Oid
    var oid : OID { get }
}
