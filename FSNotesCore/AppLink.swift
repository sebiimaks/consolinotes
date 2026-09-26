//
//  AppLink.swift
//  FSNotes
//
//  The app's own link scheme. New links use consolinotes://. Notes written with FSNotes
//  contain fsnotes:// links, so that scheme stays registered and is handled the same way.
//

import Foundation

enum AppLink {
    static let scheme = "consolinotes"
    static let legacyScheme = "fsnotes"
    static let schemes: Set<String> = [scheme, legacyScheme]

    /// `consolinotes://find?id=` followed by an escaped note title.
    static let findPrefix = scheme + "://find?id="
    /// `consolinotes://open/?tag=` followed by a tag.
    static let tagPrefix = scheme + "://open/?tag="

    static func isAppLink(_ url: URL) -> Bool {
        return schemes.contains(url.scheme?.lowercased() ?? "")
    }

    /// True for a link to a note by title, in either scheme.
    static func isFindLink(_ target: String) -> Bool {
        return schemes.contains { target.hasPrefix($0 + "://find") }
    }

    /// True for a tag link, in either scheme.
    static func isTagLink(_ target: String) -> Bool {
        return schemes.contains { target.hasPrefix($0 + "://open/?tag=") }
    }
}
