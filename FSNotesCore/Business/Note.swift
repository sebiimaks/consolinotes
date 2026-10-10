//
//  NoteMO+CoreDataClass.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 9/24/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//
//

import Foundation
import AppKit
import ZipArchive
import LocalAuthentication

public class Note: NSObject  {
    @objc var title: String = ""
    var project: Project
    var container: NoteContainer = .none
    var type: NoteType = .Markdown
    var url: URL

    var content: NSMutableAttributedString = NSMutableAttributedString()
    var creationDate: Date? = Date()

    let dateFormatter = DateFormatter()
    let undoManager = UndoManager()

    public var tags = [String]()
    public var originalExtension: String?
    
    public var isBlocked: Bool = false

    /*
     Filename with extension ie "example.textbundle"
     */
    public var name = String()

    /*
     Filename "example"
     */
    public var fileName = String()
    public var preview: String = ""

    public var isPinned: Bool = false
    public var modifiedLocalAt = Date()

    public var imageUrl: [URL]?
    public var attachments: [URL]?
    public var isParsed = false

    private var decryptedTemporarySrc: URL?
    private var encryptionSession: EncryptedNoteCodec.Session?
    private var plaintextCleanupPending = false
    private var retainedPlaintextDirectories = Set<URL>()
    public var hasPendingPlaintextCleanup: Bool { plaintextCleanupPending || !retainedPlaintextDirectories.isEmpty }
    private let writeLock = NSRecursiveLock()
    public private(set) var lastWriteError: String?
    private var saveFailurePresented = false

    private enum PersistenceError: LocalizedError {
        case missingPassword, archiveFailed, invalidBundle, destinationExists
        var errorDescription: String? {
            switch self {
            case .missingPassword: return "The note's encryption password is unavailable."
            case .archiveFailed: return "The note could not be packaged for encryption."
            case .invalidBundle: return "The note's text bundle could not be read or written."
            case .destinationExists: return "A note already exists at the destination."
            }
        }
    }

    public var isLoaded = false
    public var isLoadedFromCache = false

    public var password: String?

    public var cacheLock: Bool = false
    public var cacheHash: UInt64?
    
    
    public var previewState: Bool = false

    private var selectedRange: NSRange?
    
    public var contentOffset = CGPoint()
    public var contentOffsetWeb = CGPoint()
    
    public var scrollPosition: Int?
    public var scrollOffset: CGFloat?

    public var codeBlockRangesCache: [NSRange]?

    // Load exist
    
    init(url: URL, with project: Project, modified: Date? = nil, created: Date? = nil) {
        if let modified = modified {
            modifiedLocalAt = modified
        }
        
        if let created = created {
            creationDate = created
        }

        self.url = url.standardized
        self.project = project
        super.init()

        self.parseURL(loadProject: false)
    }
    
    // Make new
    
    init(name: String? = nil, project: Project? = nil, type: NoteType? = nil, cont: NoteContainer? = nil) {
        let project = project ?? Storage.shared().getDefault()!
        
        let name = name ?? String()

        self.project = project
        self.name = name
        
        self.container = cont ?? UserDefaultsManagement.fileContainer
        self.type = type ?? UserDefaultsManagement.fileFormat
        
        let ext = container == .none
            ? self.type.getExtension(for: container)
            : "textbundle"
                
        url = NameHelper.getUniqueFileName(name: name, project: project, ext: ext)

        super.init()

        self.parseURL()
    }

    init(meta: NoteMeta, project: Project) {
        isLoadedFromCache = true
        
        if meta.title.count > 0 || (meta.imageUrl != nil && meta.imageUrl!.count > 0) {
            isParsed = true
        }
        
        url = meta.url
        attachments = meta.attachments
        imageUrl = meta.imageUrl
        title = meta.title
        preview = meta.preview
        modifiedLocalAt = meta.modificationDate
        creationDate = meta.creationDate
        isPinned = meta.pinned
        tags = meta.tags
        selectedRange = meta.selectedRange
        self.project = project

        super.init()

        parseURL(loadProject: false)
        if isEncrypted() { cleanOut() }
    }
    
    public func fileSize(atPath path: String) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? Int64 {
                return fileSize
            }
        } catch {
            print("Error retrieving file size: \(error.localizedDescription)")
        }
        return nil
    }
    
    public func isValidForCaching() -> Bool {
        return isLoaded || title.count > 0 || isEncrypted() || imageUrl != nil
    }

    func getMeta() -> NoteMeta {
        let date = creationDate ?? Date()
        // Never persist decrypted note metadata, including when the note is unlocked.
        let sensitive = isEncrypted()
        return NoteMeta(
            url: url,
            attachments: sensitive ? nil : attachments,
            imageUrl: sensitive ? nil : imageUrl,
            title: sensitive ? "" : title,
            preview: sensitive ? "" : preview,
            modificationDate: modifiedLocalAt,
            creationDate: date,
            pinned: isPinned,
            tags: sensitive ? [] : tags,
            selectedRange: sensitive ? nil : selectedRange
        )
    }

    /// Important for decrypted temporary containers
    public func getURL() -> URL {
        if !plaintextCleanupPending, let url = self.decryptedTemporarySrc {
            return url
        }

        return self.url
    }
    
    public func loadProject() {
        let sharedStorage = Storage.shared()
        
        if let project = sharedStorage.getProjectByNote(url: url) {
            self.project = project
        }
    }

    public func forceLoad(skipCreateDate: Bool = false, loadTags: Bool = true) {
        invalidateCache()
        load(tags: loadTags)

        if !skipCreateDate {
            loadCreationDate()
        }
        
        loadModifiedLocalAt()
    }

    public func setCreationDate(string: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let userDate = formatter.date(from: string)
        let attributes = [FileAttributeKey.creationDate: userDate]

        do {
            try FileManager.default.setAttributes(attributes as [FileAttributeKey : Any], ofItemAtPath: url.path)

            creationDate = userDate
            
            if isTextBundle() {
                writeTextBundleInfo(url: getURL())
            }
            return true
        } catch {
            print(error)
            return false
        }
    }

    public func setCreationDate(date: Date) -> Bool {
        let attributes = [FileAttributeKey.creationDate: date]

        do {
            try FileManager.default.setAttributes(attributes as [FileAttributeKey : Any], ofItemAtPath: url.path)

            creationDate = date
            
            if isTextBundle() {
                writeTextBundleInfo(url: getURL())
            }
            
            return true
        } catch {
            return false
        }
    }
    
    private func readTitleAndPreview() -> (String?, String?) {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            print("Can not open the file.")
            return (nil, nil)
        }
        defer { fileHandle.closeFile() }
        
        var saveChars = false
        var title = String()
        var preview = String()
        
        while let char = String(data: fileHandle.readData(ofLength: 1), encoding: .utf8) {
            if char == "\n" {
                if saveChars {
                    preview += " "
                } else {
                    saveChars = true
                }
                continue
            }
            
            if saveChars {
                preview += char
                if preview.count >= 100 {
                    break
                }
            } else {
                title += char
            }
        }
        
        preview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (title, preview)
    }

    public func uiLoad() {
        if let size = fileSize(atPath: self.url.path), size > 100000 {
            loadFileName()
            
            let data = readTitleAndPreview()
            if let title = data.0 {
                self.title = title.trimMDSyntax()
            }
            
            if let preview = data.1 {
                self.preview = preview.trimMDSyntax()
            }
            
            return
        }
        
        load(tags: true)
    }
    
    func load(tags: Bool = true) {

        if let attributedString = getContent() {
            cacheHash = nil
            content = attributedString.loadAttachments(self)
        }

        loadFileName()
        loadPreviewInfo()
        
        if !isTrash() && tags {
            loadTags()
        }

        isLoaded = true
    }

    func reload() -> Bool {
        guard let modifiedAt = getFileModifiedDate() else { return false }
                        
        if (modifiedAt != modifiedLocalAt) {
            if let attributedString = getContent() {
                cacheHash = nil
                content = attributedString.loadAttachments(self)
                cacheCodeBlocks()
            }

            loadModifiedLocalAt()
            return true
        }
        
        return false
    }

    public func forceReload() {
        if container != .encryptedTextPack, let attributedString = getContent() {
            cacheHash = nil
            content = attributedString.loadAttachments(self)
        }
    }
    
    public func loadModifiedLocalAt() {
        modifiedLocalAt = getFileModifiedDate() ?? Date.distantPast
    }

    public func loadCreationDate() {
        creationDate = getFileCreationDate() ?? Date.distantPast
    }
    
    public func isTextBundle() -> Bool {
        return (container == .textBundle || container == .textBundleV2)
    }

    public func isFullLoadedTextBundle() -> Bool {
        return getContentFileURL() != nil
    }
    
    public func getExtensionForContainer() -> String {
        return type.getExtension(for: container)
    }

    public func getFileModifiedDate() -> Date? {
        let url = getURL()

        if isUnlocked() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: self.url.path)
                return attr[FileAttributeKey.modificationDate] as? Date
            } catch {/*_*/}
        }

        if UserDefaultsManagement.useTextBundleMetaToStoreDates && isTextBundle() {
            let textBundleURL = url
            let json = textBundleURL.appendingPathComponent("info.json")

            if let jsonData = try? Data(contentsOf: json),
               let info = try? JSONDecoder().decode(TextBundleInfo.self, from: jsonData),
               let modified = info.modified {

                return Date(timeIntervalSince1970: TimeInterval(modified))
            }
        }

        if let contentUrl = getContentFileURL() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: contentUrl.path)

                return attr[FileAttributeKey.modificationDate] as? Date
            } catch {
                print("Note modification date load error: \(error.localizedDescription)")
            }
        }

        return
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
    }

    public func getFileCreationDate() -> Date? {
        let url = getURL()

        if isUnlocked() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: self.url.path)
                return attr[FileAttributeKey.creationDate] as? Date
            } catch {/*_*/}
        }

        if UserDefaultsManagement.useTextBundleMetaToStoreDates && isTextBundle() {
            let textBundleURL = url
            let json = textBundleURL.appendingPathComponent("info.json")

            if let jsonData = try? Data(contentsOf: json),
               let info = try? JSONDecoder().decode(TextBundleInfo.self, from: jsonData),
               let created = info.created {
                
                return Date(timeIntervalSince1970: TimeInterval(created))
            }
        }

        if let contentUrl = getContentFileURL() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: contentUrl.path)

                return attr[FileAttributeKey.creationDate] as? Date
            } catch {
                print("Note creation date load error: \(error.localizedDescription)")
            }
        }

        return
            (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate
    }
    
    func move(to: URL, project: Project? = nil, forceRewrite: Bool = false) -> Bool {
        let sharedStorage = Storage.shared()

        do {
            var destination = to

            if FileManager.default.fileExists(atPath: to.path) && !forceRewrite {
                guard let project = project ?? sharedStorage.getProjectByNote(url: to) else { return false }

                let ext = url.pathExtension
                destination = NameHelper.getUniqueFileName(name: title, project: project, ext: ext)
            }

            try FileManager.default.moveItem(at: url, to: destination)
            removeCacheForPreviewImages()

            let restorePin = isPinned
            if isPinned {
                removePin()
            }

            overwrite(url: destination)

            if restorePin {
                addPin()
            }

            print("File moved from \"\(url.deletingPathExtension().lastPathComponent)\" to \"\(destination.deletingPathExtension().lastPathComponent)\"")
        } catch {
            Swift.print(error)
            return false
        }

        return true
    }
    
    func getNewURL(name: String) -> URL {
        let escapedName = name
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")
        
        var newUrl = url.deletingLastPathComponent()
        newUrl.appendPathComponent(escapedName + "." + url.pathExtension)
        return newUrl
    }

    public func remove() {
        guard let result = removeFile() else { return }
        if case .deleted = result, isPinned { removePin() }
    }

    public func isEmpty() -> Bool {
        return content.length == 0 && !isEncrypted()
    }

    enum RemovalResult {
        case deleted
        case trashed(destination: URL, original: URL)
    }

    func removeFile(completely: Bool = false) -> RemovalResult? {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentRemovalFailure()
            return nil
        }
        if isUnlocked() || hasPendingPlaintextCleanup {
            guard lock() else { presentSaveFailure(); return nil }
            refreshEditorsAfterRemovalLock()
        }

        if isTrash() || completely {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                presentRemovalFailure()
                return nil
            }

            // Flat-note attachments can be shared by other notes, including
            // locked notes whose references are deliberately not cached.
            // Only an enclosing TextBundle's own assets are removed here.
            return .deleted
        }

        do {
            guard let dst = Storage.shared().trashItem(url: url) else {
                var resultingItemUrl: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemUrl)

                let originalURL = url
                guard let dst = resultingItemUrl else { return .deleted }
                overwrite(url: dst as URL)
                return .trashed(destination: self.url, original: originalURL)
            }

            try FileManager.default.moveItem(at: url, to: dst)

            let originalURL = url
            // Move the note first: a refused filesystem move must not relocate
            // its attachments away from the still-visible original note.
            self.url = dst
            if let trash = Storage.shared().getDefaultTrash() { moveImages(to: trash) }
            overwrite(url: dst)
            return .trashed(destination: self.url, original: originalURL)

        } catch {
            presentRemovalFailure()
        }

        return nil
    }

    private func presentRemovalFailure() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The note could not be removed"
            alert.informativeText = "The note remains in the app. Check its file location and permissions, then try again. Any encrypted working copy that was saved successfully is now locked."
            alert.runModal()
        }
    }

    private func refreshEditorsAfterRemovalLock() {
        let refresh = {
            ViewController.shared()?.reloadAllOpenedWindows(note: self)
            ViewController.shared()?.notesTableView.reloadRow(note: self)
            ViewController.shared()?.sidebarOutlineView.reloadTags()
        }
        if Thread.isMainThread { refresh() }
        else { DispatchQueue.main.async(execute: refresh) }
    }

    func preserveAfterExternalRemoval() {
        writeLock.lock()
        defer { writeLock.unlock() }
        lastWriteError = "The note file was removed outside the app. Its working content has been retained; save or export it before closing."
        presentSaveFailure()
    }

    public func getAttachPrefix(url: URL? = nil) -> String {
        if let url = url, !url.isImage {
            return "files/"
        }

        return "i/"
    }

    public func move(from imageURL: URL, imagePath: String, to project: Project, copy: Bool = false) {
        let dstPrefix = getAttachPrefix(url: imageURL)
        let dest = project.url.appendingPathComponent(dstPrefix, isDirectory: true)

        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false, attributes: nil)

            if let data = "true".data(using: .utf8) {
                try? dest.setExtendedAttribute(data: data, forName: "es.fsnot.hidden.dir")
            }
        }

        do {
            if copy {
                try FileManager.default.copyItem(at: imageURL, to: dest)
            } else {
                try FileManager.default.moveItem(at: imageURL, to: dest)
            }
        } catch {
            if let fileName = ImagesProcessor.getFileName(from: imageURL, to: dest, ext: imageURL.pathExtension) {
                let dest = dest.appendingPathComponent(fileName)

                if copy {
                    try? FileManager.default.copyItem(at: imageURL, to: dest)
                } else {
                    try? FileManager.default.moveItem(at: imageURL, to: dest)
                }

                let prefix = "]("
                let postfix = ")"
                
                let imagePath = imagePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? imagePath

                let find = prefix + imagePath + postfix
                let replace = prefix + dstPrefix + fileName + postfix

                guard find != replace else { return }

                while content.mutableString.contains(find) {
                    let range = content.mutableString.range(of: find)
                    content.replaceCharacters(in: range, with: replace)
                }
            }
        }
    }

    public func moveImages(to project: Project) {
        if type == .Markdown && container == .none {
            let imagesMeta = content.getImagesAndFiles()
            for imageMeta in imagesMeta {
                let imagePath = project.url.appendingPathComponent(imageMeta.path).path
                project.storage.hideImages(directory: imagePath, srcPath: imagePath)

                // Copy if image used more then one time on project
                let copy = self.project.countNotes(contains: imageMeta.url) > 0
                move(from: imageMeta.url, imagePath: imageMeta.path, to: project, copy: copy)
            }

            if imagesMeta.count > 0 {
                if save() {
                    Storage.shared().add(self)
                }
            }
        }
    }
    
    private func getDefaultTrashURL() -> URL? {
        if let url = Storage.shared().getDefaultTrash()?.url {
            return url
        }

        return nil
    }
        
    public func getPreviewLabel(with text: String? = nil) -> String {
        var preview: String = ""
        let content = text ?? self.content.string
        let length = text?.count ?? self.content.string.count

        if length > 250 {
            if text == nil {
                let startIndex = content.index((content.startIndex), offsetBy: 0)
                let endIndex = content.index((content.startIndex), offsetBy: 250)
                preview = String(content[startIndex...endIndex])
            } else {
                preview = String(content.prefix(250))
            }
        } else {
            preview = content
        }
        
        preview = preview.replacingOccurrences(of: "\n", with: " ")
        if (
            UserDefaultsManagement.horizontalOrientation
                && content.hasPrefix(" – ") == false
            ) {
            preview = " – " + preview
        }

        preview = preview.condenseWhitespace()

        if preview.starts(with: "![") {
            return ""
        }

        return preview
    }
    
    @objc func getDateForLabel() -> String {
        guard !UserDefaultsManagement.hideDate else { return String() }

        let date = self.project.storage.getSortByState() == .creationDate
            ? creationDate
            : modifiedLocalAt

        guard let date = date else { return String() }

        if NSCalendar.current.isDateInToday(date) {
            return dateFormatter.formatTimeForDisplay(date)
        } else {
            return dateFormatter.formatDateForDisplay(date)
        }
    }

    @objc func getCreationDateForLabel() -> String? {
        guard let creationDate = self.creationDate else { return nil }
        guard !UserDefaultsManagement.hideDate else { return nil }

        let calendar = NSCalendar.current
        if calendar.isDateInToday(creationDate) {
            return dateFormatter.formatTimeForDisplay(creationDate)
        }
        else {
            return dateFormatter.formatDateForDisplay(creationDate)
        }
    }
    
    func getContent() -> NSMutableAttributedString? {
        guard container != .encryptedTextPack, let url = getContentFileURL() else { return nil }

        do {
            return try NSMutableAttributedString(url: url, options: [
                .documentType : NSAttributedString.DocumentType.plain,
                .characterEncoding : NSNumber(value: String.Encoding.utf8.rawValue)
            ], documentAttributes: nil)
        } catch {
            if let data = try? Data(contentsOf: url) {
                let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: nil, usedLossyConversion: nil)

                return try? NSMutableAttributedString(url: url, options: [
                    .documentType : NSAttributedString.DocumentType.plain,
                    .characterEncoding : NSNumber(value: encoding)
                ], documentAttributes: nil)
            }
        }
        
        return nil
    }
    
    func isMarkdown() -> Bool {
        return type == .Markdown
    }
    
    func addPin() {
        isPinned = true
    }

    func removePin() {
        if isPinned {
            isPinned = false
        }
    }
    
    func togglePin() {
        if !isPinned {
            addPin()
        } else {
            removePin()
        }
    }
    
    func cleanMetaData(content: String) -> String {
        var extractedTitle = String()
        var author = String()
        var date = String()

        if (content.hasPrefix("---\n")) {
            let searchStart = content.index(content.startIndex, offsetBy: 4)

            if let closingRange = content.range(of: "\n---\n", range: searchStart..<content.endIndex) {
                let yamlBlock = String(content[searchStart..<closingRange.lowerBound])
                let remainingContent = String(content[closingRange.upperBound...])

                let headerList = yamlBlock.components(separatedBy: "\n")
                for header in headerList {
                    if header.hasPrefix("title:") {
                        extractedTitle = header.replacingOccurrences(of: "title:", with: "").trim()

                        if extractedTitle.hasPrefix("\"") && extractedTitle.hasSuffix("\""){
                            extractedTitle = String(extractedTitle.dropFirst(1))
                            extractedTitle = String(extractedTitle.dropLast(1))
                        }
                    }

                    if header.hasPrefix("author:") {
                        author = header.replacingOccurrences(of: "author:", with: "").trim()

                        if author.hasPrefix("\"") && author.hasSuffix("\""){
                            author = String(author.dropFirst(1))
                            author = String(author.dropLast(1))
                        }
                    }

                    if header.hasPrefix("date:") {
                        date = header.replacingOccurrences(of: "date:", with: "").trim()

                        if date.hasPrefix("\"") && date.hasSuffix("\""){
                            date = String(date.dropFirst(1))
                            date = String(date.dropLast(1))
                        }
                    }
                }

                var result = String()

                if (extractedTitle.count > 0) {
                    result = "# " + extractedTitle + "\n\n"
                }

                if (author.count > 0) {
                    result += "_" + author + "_\n\n"
                }

                if (date.count > 0) {
                    result += "_" + date + "_\n\n"
                }

                if result.count > 0 {
                    result += "\n\n***\n\n"
                }

                result += remainingContent

                return result
            }
        }

        return content
    }
    
    func getPrettifiedContent() -> String {
        let mutable = NotesTextProcessor.convertAppTags(in: self.content.unloadAttachments(), codeBlockRanges: codeBlockRangesCache)
        let content = NotesTextProcessor.convertAppLinks(in: mutable, codeBlockRanges: codeBlockRangesCache)
        let result = cleanMetaData(content: content.string)
        let prettifiedContent = replaceHorizontalRulesOutsideCodeBlocks(in: result)

        return prettifiedContent
    }

    public func overwrite(url: URL) {
        self.url = url

        parseURL()
    }

    func parseURL(loadProject: Bool = true) {
        if (url.pathComponents.count > 0) {
            container = .withExt(rawValue: url.pathExtension)
            name = url.lastPathComponent
            
            if isTextBundle() {
                type = .Markdown
                container = .textBundle

                let infoUrl = url.appendingPathComponent("info.json")

                if FileManager.default.fileExists(atPath: infoUrl.path) {
                    do {
                        let jsonData = try Data(contentsOf: infoUrl)
                        let info = try JSONDecoder().decode(TextBundleInfo.self, from: jsonData)

                        if info.version == 0x02 {
                            type = NoteType.withUTI(rawValue: info.type)
                            container = .textBundleV2
                            originalExtension = info.flatExtension

                            if UserDefaultsManagement.useTextBundleMetaToStoreDates {
                                if let created = info.created {
                                    creationDate = Date(timeIntervalSince1970: TimeInterval(created))
                                }

                                if let modified = info.modified {
                                    modifiedLocalAt = Date(timeIntervalSince1970: TimeInterval(modified))
                                }
                            }
                        }
                    } catch {
                        print("TB loading error \(error)")
                    }
                }
            }
            
            if container == .none {
                type = .withExt(rawValue: url.pathExtension)
            }
            
            loadTitle()
            loadFileName()
        }

        if loadProject {
            self.loadProject()
        }
    }

    private func loadTitle() {
        if !project.settings.isFirstLineAsTitle() {
            title = url
                .deletingPathExtension()
                .pathComponents
                .last!
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "/", with: "")
        }
    }

    private func loadFileName() {
        fileName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")
    }

    public func getFileName() -> String {
        return fileName
    }

    public func save(attributed: NSAttributedString) {
        guard !isEncryptedAndLocked() else { return }
        let copy = NSMutableAttributedString(attributedString: attributed)
        if !save(content: copy) { presentSaveFailure() }
        isBlocked = false
    }

    @discardableResult
    public func save(content: NSMutableAttributedString) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isEncryptedAndLocked() else { return false }
        self.content = content
        modifiedLocalAt = Date()
        let success = write(attributedString: content.unloadAttachments())
        if success { Storage.shared().add(self) }
        return success
    }

    public func presentSaveFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.saveFailurePresented else { return }
            self.saveFailurePresented = true
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "The note could not be saved safely"
            alert.informativeText = (self.lastWriteError ?? "The operation failed.") +
                " Your working content has been kept. Resolve the storage problem and try again before closing the app."
            alert.runModal()
            self.saveFailurePresented = false
        }
    }

    public func replace(tag: String, with string: String) {
        content.replaceTag(name: tag, with: string)
        _ = save()
    }

    public func delete(tag: String) {
        content.replaceTag(name: tag, with: "")
        _ = save()
    }
        
    public func save() -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        if plaintextCleanupPending { return lock() }
        let attributedString = self.content.unloadAttachments()

        return write(attributedString: attributedString)
    }

    private func write(attributedString: NSAttributedString) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard !isEncryptedAndLocked() else {
            lastWriteError = "Unlock the note before saving changes."
            return false
        }
        let url = getURL()
        let attributes = getFileAttributes()
        
        do {
            let fileWrapper = getFileWrapper(attributedString: attributedString)

            if isTextBundle() {
                let jsonUrl = url.appendingPathComponent("info.json")
                let fileExist = FileManager.default.fileExists(atPath: jsonUrl.path)

                if !fileExist {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
                }

                if UserDefaultsManagement.useTextBundleMetaToStoreDates || !fileExist {
                    self.writeTextBundleInfo(url: url)
                }
            }

            let contentSrc: URL? = getContentFileURL()
            let dst = contentSrc ?? getContentSaveURL()

            var originalContentsURL: URL? = nil
            if let contentSrc = contentSrc {
                originalContentsURL = contentSrc
            }

            try fileWrapper.write(to: dst, options: .atomic, originalContentsURL: originalContentsURL)
            try FileManager.default.setAttributes(attributes, ofItemAtPath: dst.path)

            if decryptedTemporarySrc != nil {
                try writeEncrypted()
            }
            isLoaded = true
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }

        return true
    }

    private func getContentSaveURL() -> URL {
        let url = getURL()

        if isTextBundle() {
            let ext = getExtensionForContainer()
            return url.appendingPathComponent("text.\(ext)")
        }

        return url
    }

    public func getContentFileURL() -> URL? {
        guard !plaintextCleanupPending else { return nil }
        var url = getURL()

        if isTextBundle() {
            let ext = getExtensionForContainer()
            url = url.appendingPathComponent("text.\(ext)")

            if !FileManager.default.fileExists(atPath: url.path) {
                url = url.deletingLastPathComponent()

                if let dirList = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                    let first = dirList.first(where: { $0.starts(with: "text.") })
                {
                    url = url.appendingPathComponent(first)

                    return url
                }

                return nil
            }

            return url
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        return nil
    }
    
    private func getTextBundleJsonInfo() -> String {
        var data = [
            "transient": "true",
            "type": "\"\(type.uti)\"",
            "creatorIdentifier": "\"\(Bundle.main.bundleIdentifier ?? "io.github.sebiimaks.consolinotes")\"",
            "version": "2"
        ]

        if let originalExtension = originalExtension {
            data["flatExtension"] = "\"\(originalExtension)\""
        }

        if UserDefaultsManagement.useTextBundleMetaToStoreDates {
            let creationDate = self.creationDate ?? Date()
            let modificationDate = self.modifiedLocalAt

            data["created"] = "\(Int(creationDate.timeIntervalSince1970))"
            data["modified"] = "\(Int(modificationDate.timeIntervalSince1970))"
        }

        var result = [String]()

        for key in [
            "transient",
            "type",
            "creatorIdentifier",
            "version",
            "flatExtension",
            "created",
            "modified"
        ] {
            if let value = data[key] {
                result.append("    \"\(key)\" : \(value)")
            }
        }

        return "{\n" + result.joined(separator: ",\n") + "\n}"
    }

    private func getAssetsFileWrapper() -> FileWrapper {
        let wrapper = FileWrapper.init(directoryWithFileWrappers: [:])
        wrapper.preferredFilename = "assets"

        do {
            let assets = url.appendingPathComponent("assets")

            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: assets.path, isDirectory: &isDir) && isDir.boolValue {
                let files = try FileManager.default.contentsOfDirectory(atPath: assets.path)
                for file in files {
                    let fileData = try Data(contentsOf: assets.appendingPathComponent(file))
                    wrapper.addRegularFile(withContents: fileData, preferredFilename: file)
                }
            }
        } catch {
            print(error)
        }

        return wrapper
    }
    
    private func writeTextBundleInfo(url: URL) {
        let url = url.appendingPathComponent("info.json")
        let info = getTextBundleJsonInfo()

        try? info.write(to: url, atomically: true, encoding: String.Encoding.utf8)
    }
        
    func getFileAttributes() -> [FileAttributeKey: Any] {
        let sourceURL = getContentFileURL() ?? url
        
        var attributes: [FileAttributeKey: Any] = [
            .modificationDate: modifiedLocalAt,
            .creationDate: creationDate
        ]

        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else {
            return attributes
        }

        if let creationDate = sourceAttributes[.creationDate] {
            attributes[.creationDate] = creationDate
        }

        if let permissions = sourceAttributes[.posixPermissions] {
            attributes[.posixPermissions] = permissions
        }

        return attributes
    }
    
    func getFileWrapper(attributedString: NSAttributedString, forcePlain: Bool = false) -> FileWrapper {
        do {
            let range = NSRange(location: 0, length: attributedString.length)

            return try attributedString.fileWrapper(from: range, documentAttributes: [
                .documentType : NSAttributedString.DocumentType.plain,
                .characterEncoding : NSNumber(value: String.Encoding.utf8.rawValue)
            ])
        } catch {
            return FileWrapper()
        }
    }
        
    func getTitleWithoutLabel() -> String {
        let title = url.deletingPathExtension().pathComponents.last!
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")

        if title.isValidUUID {
            return ""
        }

        return title
    }
    
    func isTrash() -> Bool {
        return project.isTrash
    }
    
    public func contains<S: StringProtocol>(terms: [S]) -> Bool {
        return name.localizedStandardContains(terms) || content.string.localizedStandardContains(terms)
    }

    public func loadTags() {
        if UserDefaultsManagement.inlineTags {
            _ = scanContentTags()
        }
    }
    
    public func scanContentTags() -> ([String], [String]) {
        if !isLoaded {
            cacheCodeBlocks()
        }
        
        var added = [String]()
        var removed = [String]()

        let matchingOptions = NSRegularExpression.MatchingOptions(rawValue: 0)
        let options: NSRegularExpression.Options = [
            .allowCommentsAndWhitespace,
            .anchorsMatchLines
        ]

        var tags = [String]()
        
        do {
            let range = NSRange(content.string.startIndex..., in: content.string)
            let re = try NSRegularExpression(pattern: FSParser.tagsPattern, options: options)
            
            re.enumerateMatches(
                in: content.string,
                options: matchingOptions,
                range: range,
                using: { (result, flags, stop) -> Void in
                    
                    guard var range = result?.range(at: 1) else { return }
                    let cleanTag = content.mutableString.substring(with: range)
                    
                    range = NSRange(location: range.location - 1, length: range.length + 1)

                    if let codeBlockRangesCache = codeBlockRangesCache {
                        for codeRange in codeBlockRangesCache {
                            if NSIntersectionRange(codeRange, range).length > 0 {
                                return
                            }
                        }
                    }

                    let spanBlock = FSParser.getSpanCodeBlockRange(content: content, range: range)
                    
                    if spanBlock == nil && isValid(tag: cleanTag) {
                        
                        let parRange = content.mutableString.paragraphRange(for: range)
                        let par = content.mutableString.substring(with: parRange)
                        if par.starts(with: "    ") || par.starts(with: "\t") {
                            return
                        }
                        
                        if cleanTag.last == "/" {
                            tags.append(String(cleanTag.dropLast()))
                        } else {
                            tags.append(cleanTag)
                        }
                    }
                }
            )
        } catch {
            print("Tags parsing: \(error)")
        }

        if tags.contains("notags") {
            removed = self.tags

            self.tags.removeAll()
            return (added, removed)
        }

        for noteTag in self.tags {
            if !tags.contains(noteTag) {
                removed.append(noteTag)
            }
        }
        
        for tag in tags {
            if !self.tags.contains(tag) {
                added.append(tag)
            }
        }

        self.tags = tags

        return (added, removed)
    }

    private var excludeRanges = [NSRange]()

    public func isValid(tag: String) -> Bool {
        if tag.isNumber {
            return false
        }

        if tag.isHexColor() {
            return false
        }

        return true
    }
    
    public func getAttachmentFileUrl(name: String) -> URL? {
        guard !isEncryptedAndLocked() else { return nil }
        var path = name
        // Older encrypted notes can refer to the project's shared i/ directory.
        // Keep that relative convention without accepting arbitrary absolute paths.
        if path.hasPrefix("/i/") { path.removeFirst() }
        let root: URL
        if isEncrypted() && path.hasPrefix("i/") { root = project.url }
        else { root = isTextBundle() ? getURL() : project.url }
        return LocalPreviewSecurity.attachmentURL(path, root: root)
    }

    public func getDupeName() -> String? {
        var url = self.url
        let ext = url.pathExtension
        url.deletePathExtension()

        var name = url.lastPathComponent
        url.deleteLastPathComponent()

        let regex = try? NSRegularExpression(pattern: "(.+)\\sCopy\\s(\\d)+$", options: .caseInsensitive)
        if let result = regex?.firstMatch(in: name, range: NSRange(0..<name.count)) {
            if let range = Range(result.range(at: 1), in: name) {
                name = String(name[range])
            }
        }

        var endName = name
        if !endName.hasSuffix(" Copy") {
            endName += " Copy"
        }

        let dstUrl = NameHelper.getUniqueFileName(name: endName, project: project, ext: ext)

        return dstUrl.deletingPathExtension().lastPathComponent
    }

    public func loadPreviewInfo() {
        guard !isParsed || title.isEmpty && (imageUrl?.isEmpty ?? true) else { return }
        
        defer {
            imageUrl = getImagesFromContent()
            isParsed = true
        }
        
        if content.string.hasPrefix("---") {
            if parseYAMLBlock() {
                return
            }
        }
        
        if project.settings.isFirstLineAsTitle() {
            let lines = getNonEmptyLines()
            if !lines.isEmpty {
                title = lines.first!.trim()
                
                let result = lines.dropFirst()
                preview =
                    result.joined(separator: " ")
                        .trimMDSyntax()
                        .condenseWhitespace()
                
                return
            }
        }
        
        loadTitleFromFileName()
        preview = getPreviewLabel()
    }

    public func getImagesFromContent() -> [URL] {
        var urls = [URL]()

        let range = NSRange(location: 0, length: content.length)
        content.enumerateAttribute(.attachment, in: range) { (value, vRange, _) in
            guard let meta = content.getMeta(at: vRange.location) else { return }

            if meta.url.isMedia {
                urls.append(meta.url)
            }
        }

        return urls
    }

    public func invalidateCache() {
        self.imageUrl = nil
        self.preview = String()
        self.title = String()
        self.isParsed = false
    }

    public func isEqualURL(url: URL) -> Bool {
        return url.path == self.url.path
    }

    public func append(string: NSMutableAttributedString) {
        content.append(string)
    }

    public func append(image data: Data, url: URL? = nil) {
        guard let path = ImagesProcessor.writeFile(data: data, url: url, note: self) else { return }

        var prefix = "\n\n"
        if content.length == 0 {
            prefix = String()
        }

        let markdown = NSMutableAttributedString(string: "\(prefix)![](\(path))")
        append(string: markdown)
    }

    @objc public func getName() -> String {
        if title.isValidUUID {
            return "Untitled Note"
        }

        return title
    }

    public func getCacheForPreviewImage(at url: URL) -> URL? {
        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            temporary.appendPathComponent("Preview")

        if let filePath = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {

            return temporary.appendingPathComponent(filePath)
        }

        return nil
    }

    public func removeCacheForPreviewImages() {
        loadPreviewInfo()

        guard let imageURLs = imageUrl else { return }

        for url in imageURLs {
            if let imageURL = getCacheForPreviewImage(at: url) {
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    try? FileManager.default.removeItem(at: imageURL)
                }
            }
        }
    }

    private func convertFlatToTextBundle() -> URL {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        let temporaryProject = Project(storage: project.storage, url: temporary)

        let currentName = url.deletingPathExtension().lastPathComponent
        let note = Note(name: currentName, project: temporaryProject, type: type, cont: .textBundleV2)

        note.originalExtension = url.pathExtension
        note.content = content

        let imagesMeta = content.getImagesAndFiles()
        let mutableContent = content.unloadAttachments()

        // write textbundle body
        guard note.write(attributedString: mutableContent) else { return note.url }

        for imageMeta in imagesMeta {
            moveFilesFlatToAssets(attributedString: mutableContent, from: imageMeta.url, imagePath: imageMeta.path, to: note.url)
        }

        // write updated image pathes
        guard note.write(attributedString: mutableContent) else {
            return note.url
        }

        return note.url
    }

    private func convertTextBundleToFlat(name: String) {
        let textBundleURL = url
        let json = textBundleURL.appendingPathComponent("info.json")

        if let jsonData = try? Data(contentsOf: json),
            let info = try? JSONDecoder().decode(TextBundleInfo.self, from: jsonData) {
                        
            let ext = NoteType.withUTI(rawValue: info.type).getExtension(for: .textBundleV2)
            let flatExtension = info.flatExtension ?? ext
            
            let fileName = "text.\(ext)"

            let uniqueURL = NameHelper.getUniqueFileName(name: name, project: project, ext: flatExtension)
            let flatURL = url.appendingPathComponent(fileName)

            url = uniqueURL
            type = .withExt(rawValue: flatExtension)
            container = .none

            try? FileManager.default.moveItem(at: flatURL, to: uniqueURL)

            moveFilesAssetsToFlat(src: textBundleURL, project: project)

            try? FileManager.default.removeItem(at: textBundleURL)
        }
    }

    private func moveFilesFlatToAssets(attributedString: NSMutableAttributedString, from imageURL: URL, imagePath: String, to dest: URL) {
        let dest = dest.appendingPathComponent("assets")

        guard let fileName = imageURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }

        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false, attributes: nil)
        }

        do {
            try FileManager.default.moveItem(at: imageURL, to: dest.appendingPathComponent(fileName))

            let prefix = "]("
            let postfix = ")"

            let find = prefix + imagePath + postfix
            let replace = prefix + "assets/" + imageURL.lastPathComponent + postfix

            guard find != replace else { return }

            while attributedString.mutableString.contains(find) {
                let range = attributedString.mutableString.range(of: find)
                attributedString.replaceCharacters(in: range, with: replace)
            }
        } catch {
            print("Enc error: \(error)")
        }
    }

    private func moveFilesAssetsToFlat(src: URL, project: Project) {
        let mutableContent =
            NSMutableAttributedString(attributedString: content).unloadAttachments()

        let imagesMeta = content.getImagesAndFiles()
        for imageMeta in imagesMeta {
            let fileName = imageMeta.url.lastPathComponent
            var dst: URL?
            var prefix = "files/"

            if imageMeta.url.isImage {
                prefix = "i/"
            }

            dst = project.url.appendingPathComponent(prefix + fileName)

            guard let moveTo = dst else { continue }

            let dstDir = project.url.appendingPathComponent(prefix)
            let moveFrom = src.appendingPathComponent("assets/" + fileName)

            do {
                if !FileManager.default.fileExists(atPath: dstDir.path) {
                    try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: false, attributes: nil)
                }

                try FileManager.default.moveItem(at: moveFrom, to: moveTo)

            } catch {
                if let fileName = ImagesProcessor.getFileName(from: moveTo, to: dstDir, ext: moveTo.pathExtension) {

                    let moveTo = dstDir.appendingPathComponent(fileName)
                    try? FileManager.default.moveItem(at: moveFrom, to: moveTo)
                }
            }

            guard let escapedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }

            let find = "](assets/" + escapedFileName + ")"
            let replace = "](" + prefix + escapedFileName + ")"

            guard find != replace else { return }

            while mutableContent.mutableString.contains(find) {
                let range = mutableContent.mutableString.range(of: find)
                mutableContent.replaceCharacters(in: range, with: replace)
            }
        }

        content = mutableContent.loadAttachments(self)
        _ = save()
    }

    private func loadTextBundle() -> Bool {
        do {
            let url = getURL()
            let json = url.appendingPathComponent("info.json")
            let jsonData = try Data(contentsOf: json)
            let info = try JSONDecoder().decode(TextBundleInfo.self, from: jsonData)

            type = .withUTI(rawValue: info.type)

            if info.version == 1 {
                container = .textBundle
                return true
            }

            container = .textBundleV2
            return true
        } catch {
            print("Can not load TextBundle: \(error)")
        }

        return false
    }

    private func commitEncrypted(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        try file.synchronize()
    }

    private func writeEncrypted() throws {
        guard let baseTextPack = decryptedTemporarySrc, let session = encryptionSession else {
            throw PersistenceError.missingPassword
        }
        try PrivateWorkingDirectory.protectTree(baseTextPack)
        try PrivateNoteArchive.validateSourceDirectory(baseTextPack)
        let textPackURL = baseTextPack.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".textpack")
        defer { try? FileManager.default.removeItem(at: textPackURL) }
        guard SSZipArchive.createZipFile(atPath: textPackURL.path, withContentsOfDirectory: baseTextPack.path) else {
            throw PersistenceError.archiveFailed
        }
        try PrivateWorkingDirectory.protectFile(textPackURL)
        let data = try Data(contentsOf: textPackURL)
        let encryptedData = try EncryptedNoteCodec.seal(data, session: session)
        try commitEncrypted(encryptedData, to: url)
        var attributes = getFileAttributes()
        attributes[.posixPermissions] = 0o600
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    public func unLock(password: String, reload: Bool = false) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        if isUnlocked() && !reload { return true }
        // External updates must not replace local edits whose encrypted save failed.
        if reload && lastWriteError != nil && !plaintextCleanupPending { return false }
        let previousTemporary = decryptedTemporarySrc
        let previousCleanupPending = plaintextCleanupPending
        let previousSession = encryptionSession
        let previousContainer = container
        let previousType = type
        guard let directory = Storage.shared().makeTempEncryptionDirectory() else { return false }
        var keepDirectory = false
        defer { if !keepDirectory { try? FileManager.default.removeItem(at: directory) } }
        do {
            let data = try Data(contentsOf: url)
            let temporaryTextPack = directory.appendingPathComponent("note.textpack")
            let temporaryTextBundle = directory.appendingPathComponent("note.textbundle")
            let opened = try EncryptedNoteCodec.open(data, password: password)
            try opened.data.write(to: temporaryTextPack, options: .atomic)
            try PrivateWorkingDirectory.protectFile(temporaryTextPack)
            guard PrivateNoteArchive.extract(temporaryTextPack, to: temporaryTextBundle) else {
                throw PersistenceError.invalidBundle
            }
            try PrivateWorkingDirectory.protectTree(temporaryTextBundle)
            try FileManager.default.removeItem(at: temporaryTextPack)
            decryptedTemporarySrc = temporaryTextBundle
            plaintextCleanupPending = false
            guard loadTextBundle(), let decodedContent = getContent() else {
                throw PersistenceError.invalidBundle
            }
            // Fully read the incoming body before touching the previous working copy.
            let loadedContent = decodedContent.loadAttachments(self)
            self.password = password
            encryptionSession = opened.session
            invalidateCache()
            content = loadedContent
            isLoaded = true
            loadFileName()
            loadPreviewInfo()
            loadTitle()
            lastWriteError = nil
            keepDirectory = true
            // The new working copy is now authoritative. An old-directory
            // cleanup failure must never roll back to a partially deleted copy.
            if let previous = previousTemporary {
                let oldDirectory = previous.deletingLastPathComponent()
                do {
                    try removePlaintextWorkingDirectory(oldDirectory)
                    retainedPlaintextDirectories.remove(oldDirectory)
                } catch {
                    retainedPlaintextDirectories.insert(oldDirectory)
                    presentCleanupWarning()
                }
            }
            return true
        } catch {
            decryptedTemporarySrc = previousTemporary
            plaintextCleanupPending = previousCleanupPending
            encryptionSession = previousSession
            container = previousContainer
            type = previousType
            lastWriteError = error.localizedDescription
            return false
        }
    }

    public func unEncrypt(password: String) -> Bool {
        guard unLock(password: password) else { return false }
        return unEncryptUnlocked()
    }

    public func unEncryptUnlocked() -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !plaintextCleanupPending, let source = decryptedTemporarySrc else { return false }
        let original = url
        let destination = project.url.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".textbundle")
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw PersistenceError.destinationExists }
            guard save() else { return false }
            // Keep the ciphertext until a complete plaintext copy exists.
            try FileManager.default.copyItem(at: source, to: destination)
            do { try FileManager.default.removeItem(at: original) }
            catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            let cleanupDirectories = retainedPlaintextDirectories.union([source.deletingLastPathComponent()])
            for directory in cleanupDirectories {
                do { try removePlaintextWorkingDirectory(directory) }
                catch { presentCleanupWarning() }
            }
            // The user deliberately converted this note to a complete
            // plaintext copy. Cleanup warnings do not turn it into a locked note.
            retainedPlaintextDirectories.removeAll()
            decryptedTemporarySrc = nil
            encryptionSession = nil
            password = nil
            url = destination
            container = .textBundleV2
            invalidateCache()
            load()
            parseURL()
            lastWriteError = nil
            return true
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
    }

    private func makeEncryptionBundle(in directory: URL) throws -> URL {
        let temporaryProject = Project(storage: project.storage, url: directory)
        let temporaryNote = Note(name: "note", project: temporaryProject, type: type, cont: .textBundleV2)
        temporaryNote.originalExtension = url.pathExtension
        let body = content.unloadAttachments()
        let assets = temporaryNote.url.appendingPathComponent("assets")
        guard temporaryNote.write(attributedString: body) else { throw PersistenceError.invalidBundle }
        var copied = [URL: String]()
        for attachment in content.getImagesAndFiles() {
            let name: String
            if let existing = copied[attachment.url] { name = existing }
            else {
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                name = UUID().uuidString + "." + attachment.url.pathExtension
                try FileManager.default.copyItem(at: attachment.url, to: assets.appendingPathComponent(name))
                copied[attachment.url] = name
            }
            let find = "](" + attachment.path + ")"
            body.mutableString.replaceOccurrences(of: find, with: "](assets/" + name + ")", options: [], range: NSRange(location: 0, length: body.length))
        }
        guard temporaryNote.write(attributedString: body), temporaryNote.loadTextBundle(),
              temporaryNote.getContent() != nil else { throw PersistenceError.invalidBundle }
        try PrivateWorkingDirectory.protectTree(temporaryNote.url)
        return temporaryNote.url
    }

    private func removePlaintextSource(at source: URL) throws {
        try FileManager.default.removeItem(at: source)
    }

    private func presentCleanupWarning() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Note saved; cleanup incomplete"
            alert.informativeText = "The note was saved successfully, but temporary plaintext files could not be removed. Temporary copies may remain until they are cleaned up."
            alert.runModal()
        }
    }

    public func encrypt(password: String) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isEncrypted(), !password.isEmpty else { return false }
        guard let directory = Storage.shared().makeTempEncryptionDirectory() else { return false }
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = url
        let destination = project.url.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".etp")
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw PersistenceError.destinationExists }
            // Cached notes may have metadata only. Never replace an existing
            // body with the empty in-memory placeholder during folder encryption.
            if !isLoaded && FileManager.default.fileExists(atPath: original.path) {
                guard let loaded = getContent() else { throw PersistenceError.invalidBundle }
                content = loaded.loadAttachments(self)
                isLoaded = true
            }
            let source: URL
            if isTextBundle() && FileManager.default.fileExists(atPath: original.path) {
                guard save() else { return false }
                source = original
            } else {
                source = try makeEncryptionBundle(in: directory)
            }
            let archive = directory.appendingPathComponent("note.textpack")
            try PrivateNoteArchive.validateSourceDirectory(source)
            guard SSZipArchive.createZipFile(atPath: archive.path, withContentsOfDirectory: source.path) else {
                throw PersistenceError.archiveFailed
            }
            try PrivateWorkingDirectory.protectFile(archive)
            let data = try Data(contentsOf: archive)
            let session = try EncryptedNoteCodec.makeSession(password: password)
            let encrypted = try EncryptedNoteCodec.seal(data, session: session)
            try commitEncrypted(encrypted, to: destination)
            do {
                if FileManager.default.fileExists(atPath: original.path) { try removePlaintextSource(at: original) }
            } catch {
                // Removing a directory may fail after deleting some children.
                // The committed ciphertext may now be the only complete copy.
                lastWriteError = "The encrypted copy was saved, but the original plaintext could not be fully removed. The encrypted copy has been preserved; this conversion is incomplete. " + error.localizedDescription
                return false
            }
            url = destination
            container = .encryptedTextPack
            self.password = nil
            encryptionSession = nil
            cleanOut()
            parseURL()
            project.removeCache()
            purgeSensitiveDerivedData()
            lastWriteError = nil
            do { try FileManager.default.removeItem(at: directory) }
            catch { presentCleanupWarning() }
            return true
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
    }

    public func encryptAndUnlock(password: String) {
        if encrypt(password: password) { _ = unLock(password: password) }
        else if !isEncrypted() { presentSaveFailure() }
    }

    public func cleanOut() {
        isParsed = false
        imageUrl = nil
        attachments = nil
        tags.removeAll()
        cacheHash = nil
        content = NSMutableAttributedString(string: "")
        preview = ""
        title = ""
        selectedRange = nil
        undoManager.removeAllActions()
    }

    private func purgeSensitiveDerivedData() {
        MPreviewView.purgeSensitivePreviews()
        for name in ["MainNotesList", "ThumbnailsBig", "Preview"] {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    public func isUnlocked() -> Bool { decryptedTemporarySrc != nil && !plaintextCleanupPending }
    public func isEncrypted() -> Bool { container == .encryptedTextPack || isUnlocked() }
    public func isEncryptedAndLocked() -> Bool { container == .encryptedTextPack && !isUnlocked() }

    public var usesLegacyEncryption: Bool { encryptionSession?.format == .legacy }

    /// The user explicitly opts in; ordinary edits retain the original format.
    @discardableResult
    public func upgradeEncryption(password: String) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard isUnlocked(), let previous = encryptionSession, previous.format == .legacy,
              let currentPassword = self.password, currentPassword.utf8.elementsEqual(password.utf8) else {
            lastWriteError = "Unlock this legacy note with its existing password before upgrading encryption."
            return false
        }
        guard save() else { return false }
        do {
            let modern = try EncryptedNoteCodec.makeSession(password: password)
            encryptionSession = modern
            // An atomic replacement may succeed before chmod/fsync reports an
            // error. Retain the requested modern format so a retry cannot
            // silently downgrade ciphertext already committed on disk.
            return save()
        } catch {
            encryptionSession = previous
            lastWriteError = error.localizedDescription
            return false
        }
    }

    public func lock() -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let temporaryURL = decryptedTemporarySrc else { return false }
        // Once ciphertext was committed, a failed recursive cleanup may leave
        // an incomplete bundle. Subsequent attempts must only retry cleanup.
        if plaintextCleanupPending {
            guard FileManager.default.fileExists(atPath: url.path) else {
                lastWriteError = "The encrypted file is missing. Remaining working files have been retained for recovery."
                return false
            }
        } else {
            guard save() else { return false }
        }
        retainedPlaintextDirectories.insert(temporaryURL.deletingLastPathComponent())
        do {
            for directory in Array(retainedPlaintextDirectories) {
                try removePlaintextWorkingDirectory(directory)
                retainedPlaintextDirectories.remove(directory)
            }
            decryptedTemporarySrc = nil
            plaintextCleanupPending = false
            encryptionSession = nil
            password = nil
            container = .encryptedTextPack
            cleanOut()
            parseURL()
            project.removeCache()
            purgeSensitiveDerivedData()
            lastWriteError = nil
            return true
        } catch {
            plaintextCleanupPending = true
            encryptionSession = nil
            password = nil
            container = .encryptedTextPack
            cleanOut()
            parseURL()
            project.removeCache()
            purgeSensitiveDerivedData()
            refreshEditorsAfterRemovalLock()
            lastWriteError = "The encrypted note was saved, but temporary plaintext cleanup is incomplete. Retry locking or quitting to finish cleanup. " + error.localizedDescription
            return false
        }
    }

    private func removePlaintextWorkingDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func showIconInList() -> Bool {
        return (isPinned || isEncrypted())
    }

    public func getShortTitle() -> String {
        let fileName = getFileName()

        if fileName.isValidUUID {
            return "▽"
        }

        return fileName
    }

    public func getTitle() -> String? {
        if isEncrypted() && !isUnlocked() {
            return getFileName()
        }

        if title.count > 0 {
            if title.isValidUUID && project.settings.isFirstLineAsTitle() {
                return nil
            }

            if title.starts(with: "![") {
                return nil;
            }
            
            return title
        }

        if getFileName().isValidUUID {
            let previewCharsQty = preview.count
            if previewCharsQty > 0 {
                return "Untitled Note"
            }
        }

        return nil
    }

    public func rename(to name: String) {
        var name = name
        var i = 1

        while project.fileExist(fileName: name, ext: url.pathExtension) {

            // disables renaming loop
            if fileName.startsWith(string: name) {
                return
            }

            let items = name.split(separator: " ")

            if let last = items.last, let position = Int(last) {
                let full = items.dropLast()

                name = full.joined(separator: " ") + " " + String(position + 1)

                i = position + 1
            } else {
                name = name + " " + String(i)

                i += 1
            }
        }

        let isPinned = self.isPinned
        let dst = getNewURL(name: name)

        removePin()

        if isUnlocked() && !lock() {
            presentSaveFailure()
            return
        }

        if move(to: dst) {
            url = dst
            parseURL()
        }

        if isPinned {
            addPin()
        }
    }

    public func getCursorPosition() -> Int? {
        var position: Int?

        if let data = try? url.extendedAttribute(forName: "co.fluder.fsnotes.cursor") {
            position = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                ptr.load(as: Int.self)
            }

            return position
        }

        return nil
    }

    public func addTag(_ name: String) {
        guard !tags.contains(name) else { return }

        let lastParRange = content.mutableString.paragraphRange(for: NSRange(location: content.length, length: 0))
        let string = content.attributedSubstring(from: lastParRange).string.trim()

        if string.count != 0 && (
            !string.starts(with: "#") || string.starts(with: "# ")
        ) {
            let newLine = NSAttributedString(string: "\n\n")
            content.append(newLine)
        }

        var prefix = String()
        if string.starts(with: "#") {
            prefix += " "
        }

        content.append(NSAttributedString(string: prefix + "#" + name))
        if save() {
            Storage.shared().add(self)
        }
    }

    public func resetAttributesCache() {
        cacheHash = nil
    }
    
    public func getLatinName() -> String {
        let name = (self.fileName as NSString)
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? self.fileName
        
        return name.replacingOccurrences(of: " ", with: "_")
    }
    
    public func convertContainer(to: NoteContainer) {
        if to == .textBundleV2 {
            let tempUrl = convertFlatToTextBundle()
            
            let name = url.deletingPathExtension().lastPathComponent
            let uniqueURL = NameHelper.getUniqueFileName(name: name, project: project, ext: "textbundle")

            do {
                let oldUrl = url
                url = uniqueURL
                try FileManager.default.moveItem(at: tempUrl, to: uniqueURL)
                try FileManager.default.removeItem(at: oldUrl)
            } catch {/*_*/}
        } else {
            let name = url.deletingPathExtension().lastPathComponent
            
            convertTextBundleToFlat(name: name)
        }
        
        invalidateCache()
        load()
        parseURL()
    }

    public func getAutoRenameTitle() -> String? {
        if UserDefaultsManagement.naming != .autoRename && UserDefaultsManagement.naming != .autoRenameNew {
            return nil
        }
        
        if UserDefaultsManagement.naming == .autoRenameNew && isOlderThan30Seconds(from: creationDate) {
            return nil
        }
        
        if content.string.startsWith(string: "---") {
            loadPreviewInfo()
        }

        let title = title.trunc(length: 64)

        if fileName == title || title.count == 0 || isEncrypted() {
            return nil
        }

        if project.fileExist(fileName: title, ext: url.pathExtension) {
            return nil
        }

        return title
    }

    public func setSelectedRange(range: NSRange? = nil) {
        selectedRange = range
    }

    public func getSelectedRange() -> NSRange? {
        return selectedRange
    }

    public func setContentOffset(contentOffset: CGPoint) {
        self.contentOffset = contentOffset
    }

    public func getContentOffset() -> CGPoint {
        return contentOffset
    }

    public func getRelatedPath() -> String {
        return project.getNestedPath() + "/" + name
    }

    func isOlderThan30Seconds(from date: Date? = nil) -> Bool {
        guard let date = date else { return false }

        let thirtySecondsAgo = Date().addingTimeInterval(-30)
        return date < thirtySecondsAgo //Returns false if date is not older than 30 seconds
    }
    
    public func loadPreviewState() {
        previewState = project.settings.notesPreview.contains(name)
    }

    public func cacheCodeBlocks() {
        let ranges = CodeBlockDetector.shared.findCodeBlocks(in: content)
        codeBlockRangesCache = ranges
    }

    public func isInCodeBlockRange(range: NSRange) -> Bool {
        guard let codeBlockRangesCache = codeBlockRangesCache else { return false }

        for codeRange in codeBlockRangesCache {
            if NSIntersectionRange(range, codeRange).length > 0 {
                return true
            }
        }

        return false
    }

    public func save(data: Data, preferredName: String? = nil) -> (String, URL)? {
        guard !isEncryptedAndLocked() else { return nil }
        // Get attach dir
        let attachDir = getAttachDirectory(data: data)

        // Create if not exist
        if !FileManager.default.fileExists(atPath: attachDir.path, isDirectory: nil) {
            try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true, attributes: nil)
        }

        guard let fileName = getFileName(dst: attachDir, preferredName: preferredName) else { return nil }

        let fileUrl = attachDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileUrl, options: .atomic)
            if isEncrypted() { try PrivateWorkingDirectory.protectTree(getURL()) }
        } catch {
            print("Attachment error: \(error)")
            return nil
        }

        let lastTwo = fileUrl.deletingLastPathComponent().lastPathComponent + "/" + fileUrl.lastPathComponent

        return (lastTwo, fileUrl)
    }

    public func getAttachDirectory(data: Data) -> URL {
        if isTextBundle() {
            return getURL().appendingPathComponent("assets", isDirectory: true)
        }

        let prefix = data.getFileType() != .unknown ? "i" : "files"

        return project.url.appendingPathComponent(prefix, isDirectory: true)
    }

    public func getFileName(dst: URL, preferredName: String? = nil) -> String? {
        var name = preferredName ?? UUID().uuidString.lowercased()
        let ext = (name as NSString).pathExtension

        while true {
            let destination = dst.appendingPathComponent(name)
            let icloud = destination.appendingPathExtension("icloud")

            if FileManager.default.fileExists(atPath: destination.path) || FileManager.default.fileExists(atPath: icloud.path) {
                let newBase = UUID().uuidString.lowercased()
                if ext.isEmpty {
                    name = newBase
                } else {
                    name = "\(newBase).\(ext)"
                }
                continue
            }

            return name
        }
    }

    public func saveSimple() -> Bool {
        return write(attributedString: content)
    }

    public func cache() {
        if cacheLock { return }

        let hash = content.string.fnv1a
        cacheLock = true

        if let copy = content.mutableCopy() as? NSMutableAttributedString {
            NotesTextProcessor.highlight(attributedString: copy)
            cacheCodeBlocks()

            if content.string.fnv1a == copy.string.fnv1a {
                content = copy
                cacheHash = hash
            }
        }

        cacheLock = false
    }
}
