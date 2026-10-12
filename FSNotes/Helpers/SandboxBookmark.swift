// Copyright (c) 2017 Oleksandr Glushchenko; 2026 sebiimaks. MIT license.

import Foundation

/// One scope lease per configured bookmark. Repeated loading never starts a
/// second lease, and removing a role releases access when no active role remains.
final class SandboxBookmark {
    enum Role: String, Codable { case library, folder, trash, auxiliary }
    struct Record: Codable { var url: URL; var data: Data; var roles: Set<Role> }
    struct Scope {
        var resolve: (Data) throws -> (URL, Bool)
        var create: (URL) throws -> Data
        var start: (URL) -> Bool
        var stop: (URL) -> Void
        static let system = Scope(resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url.standardizedFileURL, stale)
        }, create: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
           start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() })
    }
    static var instance: SandboxBookmark?
    static func sharedInstance() -> SandboxBookmark {
        if let instance = instance { return instance }
        let result = SandboxBookmark(); instance = result; return result
    }
    private let database: URL?
    private let scope: Scope
    private let configured: () -> [Role: URL]
    private let lock = NSRecursiveLock()
    private var records = [URL: Record]()
    private var leases = [URL: URL]()
    private var loaded = false
    private(set) var unavailableFolders = 0

    init(database: URL? = nil, scope: Scope = .system, configured: @escaping () -> [Role: URL] = {
        var result = [Role: URL]()
        result[.library] = UserDefaultsManagement.configuredStorageURL
        result[.trash] = UserDefaultsManagement.trashURL
        result[.auxiliary] = UserDefaultsManagement.shared?.url(forKey: "gitStorage")
        return result
    }) {
        self.database = database ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Bookmarks-v2.json")
        self.scope = scope
        self.configured = configured
    }
    deinit { releaseAll() }

    func load() {
        lock.lock(); defer { lock.unlock() }
        readDatabase()
        reconcile()
    }

    private func readDatabase() {
        guard !loaded else { return }
        loaded = true
        guard let database = database else { return }
        if FileManager.default.fileExists(atPath: database.path) {
            guard let data = try? PrivateWorkingDirectory.readBoundedFile(database, maximumBytes: 8 * 1024 * 1024),
                  let values = try? JSONDecoder().decode([Record].self, from: data), values.count <= 256,
                  values.allSatisfy({ $0.url.isFileURL && $0.data.count <= 1024 * 1024 }) else {
                PrivacyLog.record("bookmark.database.invalid"); return
            }
            for record in values { records[record.url.standardizedFileURL] = record }
        } else {
            // Every old folder bookmark represented an attached root; classify
            // current library/trash/repository bookmarks before activating them.
            let old = database.deletingLastPathComponent().appendingPathComponent("Bookmarks.dict")
            guard let data = try? PrivateWorkingDirectory.readBoundedFile(old, maximumBytes: 8 * 1024 * 1024),
                  let legacy = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSURL.self, NSData.self], from: data) as? [URL: Data],
                  legacy.count <= 256 else { return }
            for (url, data) in legacy where url.isFileURL && data.count <= 1024 * 1024 {
                let key = url.standardizedFileURL
                let matching = Set(configured().filter { $0.value.standardizedFileURL == key }.map { $0.key })
                let roles: Set<Role> = matching.isEmpty ? (url.pathExtension == "css" ? [.auxiliary] : [.folder]) : matching
                records[key] = Record(url: key, data: data, roles: roles)
            }
            save()
        }
    }

    private func isConfigured(_ record: Record) -> Bool {
        record.roles.contains(.folder) || configured().contains { role, url in
            record.roles.contains(role) && url.standardizedFileURL == record.url.standardizedFileURL
        }
    }

    private func reconcile() {
        for key in Array(leases.keys) where records[key].map({ !isConfigured($0) }) ?? true {
            if let url = leases.removeValue(forKey: key) { scope.stop(url) }
        }
        unavailableFolders = 0
        var changed = false
        for (key, record) in records where isConfigured(record) {
            if leases[key] != nil { continue }
            do {
                let (url, stale) = try scope.resolve(record.data)
                guard scope.start(url) else { throw CocoaError(.fileReadNoPermission) }
                leases[key] = url
                if stale {
                    do {
                        records[key]?.data = try scope.create(url)
                        changed = true
                    } catch {
                        leases.removeValue(forKey: key)
                        scope.stop(url)
                        throw error
                    }
                }
            } catch {
                if record.roles.contains(.folder) { unavailableFolders += 1 }
                PrivacyLog.record("bookmark.access.unavailable")
            }
        }
        if changed { save() }
    }

    @discardableResult func authorize(url: URL, role: Role) -> Bool {
        lock.lock(); defer { lock.unlock() }
        readDatabase()
        let key = url.standardizedFileURL
        do {
            let data = try scope.create(key)
            guard data.count <= 1024 * 1024, records[key] != nil || records.count < 256 else { return false }
            let previous = records[key]
            var started = false
            if leases[key] == nil {
                guard scope.start(key) else { return false }
                leases[key] = key; started = true
            }
            var roles = previous?.roles ?? []
            roles.insert(role)
            records[key] = Record(url: key, data: data, roles: roles)
            do { try persist(); return true }
            catch {
                records[key] = previous
                if started { leases.removeValue(forKey: key); scope.stop(key) }
                throw error
            }
        } catch { PrivacyLog.record("bookmark.save.failed"); return false }
    }

    @discardableResult func store(url: URL, role: Role = .folder) -> Bool { authorize(url: url, role: role) }
    @discardableResult func save(url: URL, role: Role = .folder) -> Bool { authorize(url: url, role: role) }
    func save() {
        lock.lock(); defer { lock.unlock() }
        do { try persist() } catch { PrivacyLog.record("bookmark.save.failed") }
    }
    private func persist() throws {
        guard let database = database else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONEncoder().encode(Array(records.values))
        guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: database, options: .atomic)
        try PrivateWorkingDirectory.protectFile(database)
        let file = try FileHandle(forWritingTo: database)
        defer { try? file.close() }
        try file.synchronize()
    }

    @discardableResult func remove(url: URL, role: Role? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        readDatabase()
        let previous = records
        let key = url.standardizedFileURL
        let keys = records.keys.filter { $0 == key || leases[$0] == key }
        for key in keys {
            if let role = role {
                records[key]?.roles.remove(role)
                if records[key]?.roles.isEmpty == true { records.removeValue(forKey: key) }
            } else { records.removeValue(forKey: key) }
        }
        do { try persist() }
        catch { records = previous; PrivacyLog.record("bookmark.remove.failed"); return false }
        reconcile()
        return true
    }
    @discardableResult func removeBy(_ url: URL) -> Bool { removeFolders([url]) }
    @discardableResult func removeFolders(_ urls: [URL]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        readDatabase()
        let previous = records
        let selected = Set(urls.map { $0.standardizedFileURL })
        for key in Array(records.keys) where selected.contains(key) || leases[key].map({ selected.contains($0) }) == true {
            records[key]?.roles.remove(.folder)
            if records[key]?.roles.isEmpty == true { records.removeValue(forKey: key) }
        }
        do { try persist() }
        catch { records = previous; PrivacyLog.record("bookmark.remove.failed"); return false }
        reconcile()
        return true
    }
    func rename(url: URL, new: URL) {
        lock.lock(); defer { lock.unlock() }
        readDatabase()
        guard let record = records[url.standardizedFileURL] else { return }
        for role in record.roles { guard authorize(url: new, role: role) else { return } }
        remove(url: url)
    }
    func resetBookmarksDb() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll(); loaded = true; releaseAll(); save()
    }
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        for url in leases.values { scope.stop(url) }
        leases.removeAll()
    }
    func resolvedURL(for url: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        load(); return leases[url.standardizedFileURL]
    }
    func getRestoredUrls() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        load(); return Array(Set(leases.values))
    }
    func attachedFolderURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        load()
        return records.compactMap { $0.value.roles.contains(.folder) ? leases[$0.key] : nil }
    }
}
