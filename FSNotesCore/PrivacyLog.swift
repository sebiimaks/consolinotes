// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.
import Foundation

/// Only compile-time event labels may enter diagnostics. Nothing is written to disk
/// or stdout automatically, and the bounded session buffer contains no user values.
enum PrivacyLog {
    private static let lock = NSLock()
    private static var events = [String]()
    static func record(_ event: StaticString) {
        lock.lock(); defer { lock.unlock() }
        if events.count == 200 { events.removeFirst() }
        events.append(event.description)
    }
    static func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return "consolinotes diagnostics\nStatic events from this session only. No note text, names, paths or error details.\n\n" + events.joined(separator: "\n")
    }
}
