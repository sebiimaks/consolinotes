//
//  Project+Git.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 31.10.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation

extension Project {

    public func getRepositoryUrl() -> URL {
        if UserDefaultsManagement.separateRepo {
            return url.appendingPathComponent(".git", isDirectory: true)
        }

        let key = String(url.path.md5.prefix(4))
        let repoURL = UserDefaultsManagement.gitStorage!.appendingPathComponent(key + " - " + label + ".git")

        return repoURL
    }

    public func hasRepository() -> Bool {
        let url = getRepositoryUrl()

        return FileManager.default.fileExists(atPath: url.path)
    }

    public func getGitProject() -> Project? {
        if hasRepository() {
            return self
        }

        if let parent = parent, let root = parent.getGitProject() {
            return root
        }

        return nil
    }

    public func initBareRepository() throws {
        let repositoryManager = RepositoryManager()
        let repoURL = getRepositoryUrl()

        // Prepare temporary dir
        let tempURL = UserDefaultsManagement.gitStorage!.appendingPathComponent("local-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Init
        let signature = getSign()
        let repository = try repositoryManager.initRepository(at: tempURL, signature: signature)

        if isUseWorkTree() {
            repository.setWorkTree(path: url.path)
        }

        let dotGit = tempURL.appendingPathComponent(".git")

        if FileManager.default.directoryExists(atUrl: dotGit) {
            try FileManager.default.moveItem(at: dotGit, to: repoURL)
        }
    }

    public func getRepository() throws -> Repository {
        let repositoryManager = RepositoryManager()
        let repoURL = getRepositoryUrl()

        return try repositoryManager.openRepository(at: repoURL)
    }

    public func useSeparateRepo() -> Bool {
        return UserDefaultsManagement.separateRepo
    }

    public func getSign() -> Signature {
        return Signature(name: "consolinotes", email: "consolinotes@localhost")
    }

    public func commit(message: String? = nil, progress: GitProgress? = nil) throws {
        let repository = try getRepository()
        let lastCommit = try? repository.head().targetCommit()

        // Add all and save index
        let head = try repository.head().index()
        if let progress = progress {
            progress.log(message: "git add .")
        }

        let success = head.add(path: ".")

        // No commits yet or added files was found
        if success || lastCommit == nil {
            try head.save()

            do {
                progress?.log(message: "git commit")

                let sign = getSign()
                if lastCommit == nil {
                    let commitMessage = message ?? "consolinotes Init"
                    _ = try head.createInitialCommit(msg: commitMessage, signature: sign)
                } else {
                    let commitMessage = message ?? "Usual commit"
                    _ = try head.createCommit(msg: commitMessage, signature: sign)
                }

                progress?.log(message: "git commit done 🤟")

                cacheHistory(progress: progress)
            } catch {
                progress?.log(message: "commit error: \(error)")
            }
        } else {
            progress?.log(message: "git add: no new data")

            throw GitError.noAddedFiles
        }
    }

    public func checkGitState() throws -> Bool {
        let repository = try getRepository()
        let statuses = Statuses(repository: repository)

        isCleanGit = statuses.workingDirectoryClean
        return isCleanGit
    }

    public func getLocalBranch(repository: Repository) -> Branch? {
        do {
            return try repository.currentBranch()
        } catch {/**/}

        return nil
    }

    public func isUseWorkTree() -> Bool {
        return !UserDefaultsManagement.separateRepo
    }

    public func removeRepository(progress: GitProgress? = nil) {
        let repoURL = getRepositoryUrl()

        if FileManager.default.fileExists(atPath: repoURL.path) {
            try? FileManager.default.removeItem(at: repoURL)
        }

        removeCommitsCache()

        progress?.log(message: "git repository has been deleted")
    }

    public func removeCommitsCache() {
        if let url = getCommitsDiffsCache() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func loadCommitsCache() {
        if !commitsCache.isEmpty {
            return
        }

        if let commitsDiffCache = getCommitsDiffsCache(),
            let data = try? Data(contentsOf: commitsDiffCache),
            let result = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSArray.self, NSString.self], from: data) as? [String: [String]] {
            commitsCache = result
        }
    }

    public func cacheHistory(progress: GitProgress? = nil) {
        progress?.log(message: "git history caching ...")

        guard let repository = try? getRepository() else { return }

        do {
            let fileRevLog = try FileHistoryIterator(repository: repository, path: "Test", project: self)
            fileRevLog.walkCacheDiff()

            let cacheData = try? NSKeyedArchiver.archivedData(withRootObject: commitsCache, requiringSecureCoding: true)
            if let data = cacheData, let writeTo = getCommitsDiffsCache() {
                do {
                    try data.write(to: writeTo)
                } catch {
                    print("Caching error: " + error.localizedDescription)
                }
            }
        } catch {
            print(error)
        }

        progress?.log(message: "git history caching done 🤟")
    }

    public func getCommitsDiffsCache() -> URL? {
        guard let documentDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let fileName = "commitsDiff-\(settingsKey).cache"
        return documentDir.appendingPathComponent(fileName, isDirectory: false)
    }

    public func hasCommitsDiffsCache() -> Bool {
        guard let project = getGitProject() else { return false }

        if let url = project.getCommitsDiffsCache() {
            return FileManager.default.fileExists(atPath: url.path)
        }

        return false
    }

    public func getRepositoryState() -> RepositoryAction {
        return hasRepository() ? .commit : .initCommit
    }

    public func gitDo(_ action: RepositoryAction, progress: GitProgress? = nil) -> String? {
        do {
            if action == .initCommit { try initBareRepository() }
            try commit(message: nil, progress: progress)
            return nil
        } catch GitError.noAddedFiles {
            return nil
        } catch {
            return (error as? GitError)?.associatedValue() ?? error.localizedDescription
        }
    }

    /// Local history only. Existing remote configuration is never used.
    public func saveRevision(commitMessage: String? = nil) throws {
        try commit(message: commitMessage)
    }
}
