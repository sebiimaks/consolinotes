//
//  Preferences.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 8/8/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

import Cocoa

public class UserDefaultsManagement {
    

    typealias Color = NSColor
    typealias Image = NSImage
    typealias Font = NSFont

    public static var shared: UserDefaults? = UserDefaults.standard
    public static var DefaultFontSize = 14

    static var DefaultSnapshotsInterval = 1
    static var DefaultSnapshotsIntervalMinutes = 5
    
    static var DefaultFontColor = Color.black
    static var DefaultBgColor = Color.white

    private struct Constants {
        static let AppearanceTypeKey = "appearanceType"
        static let AskCommitMessage = "askCommitMessage"
        static let AutoInsertHeader = "autoInsertHeader"
        static let AutoVersioning = "autoVersioning"
        static let AutomaticSpellingCorrection = "automaticSpellingCorrection"
        static let AutomaticQuoteSubstitution = "automaticQuoteSubstitution"
        static let AutomaticDataDetection = "automaticDataDetection"
        static let AutomaticLinkDetection = "automaticLinkDetection"
        static let AutomaticTextReplacement = "automaticTextReplacement"
        static let AutomaticDashSubstitution = "automaticDashSubstitution"
        static let AutomaticConflictsResolution = "automaticConflictsResolution"
        static let BackupManually = "backupManually"
        static let BgColorKey = "bgColorKeyed"
        static let boldKey = "boldKeyed"
        static let CacheDiff = "cacheDiff"
        static let CellSpacing = "cellSpacing"
        static let CellFrameOriginY = "cellFrameOriginY"
        static let ClickableLinks = "clickableLinks"
        static let CodeFontNameKey = "codeFont"
        static let CodeFontSizeKey = "codeFontSize"
        static let codeBlockHighlight = "codeBlockHighlight"
        static let CodeBlocksWithSyntaxHighlighting = "codeBlocksWithSyntaxHighlighting"
        static let codeTheme = "codeTheme2025"
        static let ContinuousSpellChecking = "continuousSpellChecking"
        static let CrashedLastTime = "crashedLastTime"
        static let DefaultLanguageKey = "defaultLanguage"
        static let DefaultKeyboardKey = "defaultKeyboard"
        static let FontNameKey = "font"
        static let FontSizeKey = "fontsize"
        static let FontColorKey = "fontColorKeyed"
        static let FullScreen = "fullScreen"
        static let FirstLineAsTitle = "firstLineAsTitle"
        static let MaxChildDirs = "maxChildDirs"
        static let NoteType = "noteType"
        static let NoteExtension = "noteExtension"
        static let GrammarChecking = "grammarChecking"
        static let GitStorage = "gitStorage"
        static let HideDate = "hideDate"
        static let HideOnDeactivate = "hideOnDeactivate"
        static let HideSidebar = "hideSidebar"
        static let HidePreviewKey = "hidePreview"
        static let HidePreviewImages = "hidePreviewImages"
        static let ImagesWidthKey = "imagesWidthKey"
        static let IndentUsing = "indentUsing"
        static let InlineTags = "inlineTags"
        static let IsFirstLaunch = "isFirstLaunch"
        static let italicKey = "italicKeyed"
        static let LastCommitMessage = "lastCommitMessage"
        static let LastNews = "lastNews"
        static let LastSelectedPath = "lastSelectedPath"
        static let LastScreenX = "lastScreenX"
        static let LastScreenY = "lastScreenY"
        static let LastSidebarItem = "lastSidebarItem"
        static let LastProjectURL = "lastProjectUrl"
        static let LineHeightMultipleKey = "lineHeightMultipleKey"
        static let LineSpacingEditorKey = "lineSpacingEditor"
        static let LineWidthKey = "lineWidth"
        static let LockOnSleep = "lockOnSleep"
        static let LockOnScreenActivated = "lockOnScreenActivated"
        static let LockAfterIDLE = "lockAfterIdle"
        static let LockAfterUserSwitch = "lockAfterUserSwitch"
        static let MarginSizeKey = "marginSize"
        static let SuppressNewEncryptionFormatNotice = "suppressNewEncryptionFormatNotice"
        static let MathJaxPreview = "mathJaxPreview"
        static let NonContiguousLayout = "allowsNonContiguousLayout"
        static let NoteContainer = "noteContainer"
        static let Preview = "preview"
        static let PreviewFontSize = "previewFontSize"
        static let ProjectsKey = "projects"
        static let RecentSearches = "recentSearches"
        static let SearchHighlight = "searchHighlighting"
        static let SeparateRepo = "separateRepo"
        static let ShowDockIcon = "showDockIcon"
        static let shouldFocusSearchOnESCKeyDown = "shouldFocusSearchOnESCKeyDown"
        static let ShowInMenuBar = "showInMenuBar"
        static let SmartInsertDelete = "smartInsertDelete"
        static let SnapshotsInterval = "snapshotsInterval"
        static let SnapshotsIntervalMinutes = "snapshotsIntervalMinutes"
        static let SortBy = "sortBy"
        static let StorageType = "storageType"
        static let StoragePathKey = "storageUrl"
        static let TableOrientation = "isUseHorizontalMode"
        static let TextMatchAutoSelection = "textMatchAutoSelection"
        static let TrashKey = "trashKey"
        static let UseTextBundleToStoreDates = "useTextBundleToStoreDates"
        static let AutocloseBrackets = "autocloseBrackets"
        static let Welcome = "welcome2026"
    }

    static var codeFontName: String {
        get {
            if let returnFontName = shared?.object(forKey: Constants.CodeFontNameKey) as? String {
                return returnFontName
            } else {
                return "JetBrains Mono"
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.CodeFontNameKey)
        }
    }

    static var codeFontSize: Int {
        get {
            if let returnFontSize = shared?.object(forKey: Constants.CodeFontSizeKey) as? Int {
                return returnFontSize
            } else {
                return self.DefaultFontSize
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.CodeFontSizeKey)
        }
    }

    static var fontName: String? {
        get {
            if let returnFontName = shared?.object(forKey: Constants.FontNameKey) as? String {
                return returnFontName
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.FontNameKey)
        }
    }
    
    static var fontSize: Int {
        get {
            if let returnFontSize = shared?.object(forKey: Constants.FontSizeKey) as? Int {
                return returnFontSize
            } else {
                return self.DefaultFontSize
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.FontSizeKey)
        }
    }
    
    static var externalEditor: String {
        get {
            
            if let name = shared?.object(forKey: "externalEditorApp") as? String, name.count > 0 {
                return name
            } else {
                return "TextEdit"
            }
        }
        set {
            shared?.set(newValue, forKey: "externalEditorApp")
        }
    }

    static var horizontalOrientation: Bool {
        get {
            if let returnHorizontalOrientation = shared?.object(forKey: Constants.TableOrientation) as? Bool {
                return returnHorizontalOrientation
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.TableOrientation)
            
            // reset the note list height / width
            shared?.removeObject(forKey: "NSSplitView Subview Frames EditorSplitView")
            
            if (newValue){
                // for top-to-bottom layout, set note list cell height to 0
                cellSpacing = 0
            } else {
                // for side-by-side layout, reset note list cell height to default
                shared?.removeObject(forKey: Constants.CellSpacing)
            }
        }
    }
    
    /// The selected private library, prepared explicitly before Storage starts.
    static var localDocumentsContainer: URL? { privateLibraryURL }
    static var defaultLocalDocuments: URL? { privateLibraryURL }

    static var privateLibraryURL: URL? {
        get { shared?.url(forKey: "privateLibraryURL") }
        set { shared?.set(newValue, forKey: "privateLibraryURL") }
    }

    static var librarySetupVersion: Int {
        get { shared?.integer(forKey: "librarySetupVersion") ?? 0 }
        set { shared?.set(newValue, forKey: "librarySetupVersion") }
    }

    static var privateLibraryBackupIncluded: Bool {
        get { shared?.bool(forKey: "privateLibraryBackupIncluded") ?? false }
        set { shared?.set(newValue, forKey: "privateLibraryBackupIncluded") }
    }

    /// Do not probe access here or silently replace a missing library. Startup
    /// resolves its bookmark and asks for access before any notes are loaded.
    static var customStoragePath: String? {
        get { shared?.string(forKey: Constants.StoragePathKey) }
        set { shared?.set(newValue, forKey: Constants.StoragePathKey) }
    }

    static var configuredStorageURL: URL? {
        if let path = customStoragePath { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        return privateLibraryURL
    }

    static var hasPreviousLibraryConfiguration: Bool {
        guard let preferences = shared else { return false }
        return [Constants.StoragePathKey, Constants.StorageType, Constants.CrashedLastTime,
                Constants.IsFirstLaunch, Constants.Welcome, Constants.LastSelectedPath]
            .contains { preferences.object(forKey: $0) != nil }
    }

    static var legacyDocumentsURL: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Documents/consolinotes", isDirectory: true)
    }

    static var storagePath: String? { configuredStorageURL?.path }

    public static var storageType: StorageType {
        get {
            if let type = shared?.object(forKey: Constants.StorageType) as? Int {
                return StorageType(rawValue: type) ?? .none
            }
            return .none
        }
        set {
            shared?.set(newValue.rawValue, forKey: Constants.StorageType)
        }
    }
    
    static var storageUrl: URL? {
        get {
            if let path = storagePath {
                let expanded = NSString(string: path).expandingTildeInPath

                return URL.init(fileURLWithPath: expanded, isDirectory: true).standardized
            }
            
            return nil
        }
    }

    static var preview: Bool {
        get {
            if let preview = shared?.object(forKey: Constants.Preview) as? Bool {
                return preview
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.Preview)
        }
    }
    
    static var lastSync: Date? {
        get {
            if let sync = shared?.object(forKey: "lastSync") as? Date {
                return sync
            } else {
                return nil
            }
        }
        set {
            shared?.set(newValue, forKey: "lastSync")
        }
    }
    
    static var hideOnDeactivate: Bool {
        get {
            if let hideOnDeactivate = shared?.object(forKey: Constants.HideOnDeactivate) as? Bool {
                return hideOnDeactivate
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.HideOnDeactivate)
        }
    }
    
    static var cellSpacing: Int {
        get {
            if let cellSpacing = shared?.object(forKey: Constants.CellSpacing) as? NSNumber {
                return cellSpacing.intValue
            } else {
                return 33
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.CellSpacing)
        }
    }
        
    static var cellViewFrameOriginY: CGFloat? {
        get {
            if let number = shared?.object(forKey: Constants.CellFrameOriginY) as? NSNumber {
                return CGFloat(number.doubleValue)
            }
            return nil
        }
        set {
            if let newValue = newValue {
                shared?.set(Double(newValue), forKey: Constants.CellFrameOriginY)
            } else {
                shared?.removeObject(forKey: Constants.CellFrameOriginY)
            }
        }
    }
    
    static var hidePreview: Bool {
        get {
            if let returnMode = shared?.object(forKey: Constants.HidePreviewKey) as? Bool {
                return returnMode
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.HidePreviewKey)
        }
    }
        
    static var sort: SortBy {
        get {
            if let result = shared?.object(forKey: "sortBy") as? String, let sortBy = SortBy(rawValue: result) {
                return sortBy
            } else {
                return .modificationDate
            }
        }
        set {
            shared?.set(newValue.rawValue, forKey: "sortBy")
        }
    }
    
    static var sortDirection: Bool {
        get {
            if let returnMode = shared?.object(forKey: "sortDirection") as? Bool {
                return returnMode
            } else {
                return true
            }
        }
        set {
            shared?.set(newValue, forKey: "sortDirection")
        }
    }
    
    static var hideSidebar: Bool {
        get {
            if let hide = shared?.object(forKey: "hideSidebar") as? Bool {
                return hide
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: "hideSidebar")
        }
    }
    
    static var notesTableWidth: CGFloat {
        get {
            if let value = shared?.object(forKey: "sidebarSize") as? Int {
                return CGFloat(value)
            }

            return 300
        }
        set {
            shared?.set(Int(newValue), forKey: "sidebarSize")
        }
    }
    
    static var hideSidebarTable: Bool {
        get {
            if let hide = shared?.object(forKey: "hideRealSidebar") as? Bool {
                return hide
            }
            
            return false
        }
        set {
            shared?.set(newValue, forKey: "hideRealSidebar")
        }
    }
    
    static var sidebarTableWidth: CGFloat {
        get {
            if let size = shared?.object(forKey: "realSidebarSize") as? Int {
                return CGFloat(size)
            }
            return 150
        }
        set {
            shared?.set(Int(newValue), forKey: "realSidebarSize")
        }
    }
    
    static var codeBlockHighlight: Bool {
        get {
            if let highlight = shared?.object(forKey: Constants.codeBlockHighlight) as? Bool {
                return highlight
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.codeBlockHighlight)
        }
    }

    static var lastSelectedURL: URL? {
        get {
            if let url = shared?.url(forKey: Constants.LastSelectedPath) {
                return url
            }
            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastSelectedPath)
        }
    }
    
    static var focusInEditorOnNoteSelect: Bool {
        get {
            if let result = shared?.object(forKey: "focusInEditorOnNoteSelect") as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: "focusInEditorOnNoteSelect")
        }
    }
    
    static var defaultKeyboard: String? {
        get {
            if let dk = shared?.string(forKey: Constants.DefaultKeyboardKey) as? String {
                return dk
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.DefaultKeyboardKey)
        }
    }
    
    static var defaultLanguage: Int {
        get {
            if let dl = shared?.object(forKey: Constants.DefaultLanguageKey) as? Int {
                return dl
            }

            if let code = NSLocale.current.languageCode {
                return LanguageType.withCode(rawValue: code)
            }
            
            return 0
        }
        set {
            shared?.set(newValue, forKey: Constants.DefaultLanguageKey)
        }
    }
    
    static var autocloseBrackets: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutocloseBrackets) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutocloseBrackets)
        }
    }
    
    static var lastProjectURL: URL? {
        get {
            if let lastProject = shared?.url(forKey: Constants.LastProjectURL) {
                return lastProject
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastProjectURL)
        }
    }

    static var lastSidebarItem: Int? {
        get {
            if let index = shared?.object(forKey: Constants.LastSidebarItem) as? Int {
                return index
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastSidebarItem)
        }
    }
    
    static var showDockIcon: Bool {
        get {
            if let result = shared?.object(forKey: Constants.ShowDockIcon) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.ShowDockIcon)
        }
    }
    
    static var editorLineSpacing: Float {
        get {
            if let result = shared?.object(forKey: Constants.LineSpacingEditorKey) as? Float {
                return Float(Int(result))
            } else {
                return 4
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.LineSpacingEditorKey)
        }
    }
    
    static var lineHeightMultiple: CGFloat {
        get {
            if let result = shared?.object(forKey: Constants.LineHeightMultipleKey) as? Float {
                return CGFloat(result)
            } else {
                return 1.4
            }
        }
        set {
            shared?.set(Float(newValue), forKey: Constants.LineHeightMultipleKey)
        }
    }

    static var imagesWidth: Float {
        get {
            if let result = shared?.object(forKey: Constants.ImagesWidthKey) as? Float {
                return result
            }
            return 450
        }
        set {
            shared?.set(newValue, forKey: Constants.ImagesWidthKey)
        }
    }

    static var lineWidth: Float {
        get {
            if let result = shared?.object(forKey: Constants.LineWidthKey) as? Float {
                return result
            }
            return 1000
        }
        set {
            shared?.set(newValue, forKey: Constants.LineWidthKey)
        }
    }
    
    static var textMatchAutoSelection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.TextMatchAutoSelection) as? Bool {
                return result
            }
            
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.TextMatchAutoSelection)
        }
    }
    
    static var continuousSpellChecking: Bool {
        get {
            if let result = shared?.object(forKey: Constants.ContinuousSpellChecking) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.ContinuousSpellChecking)
        }
    }
    
    static var grammarChecking: Bool {
        get {
            if let result = shared?.object(forKey: Constants.GrammarChecking) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.GrammarChecking)
        }
    }
    
    static var smartInsertDelete: Bool {
        get {
            if let result = shared?.object(forKey: Constants.SmartInsertDelete) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.SmartInsertDelete)
        }
    }
    
    static var automaticSpellingCorrection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticSpellingCorrection) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticSpellingCorrection)
        }
    }
    
    static var automaticQuoteSubstitution: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticQuoteSubstitution) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticQuoteSubstitution)
        }
    }
    
    static var automaticDataDetection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticDataDetection) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticDataDetection)
        }
    }
    
    static var automaticLinkDetection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticLinkDetection) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticLinkDetection)
        }
    }
        
    static var automaticTextReplacement: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticTextReplacement) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticTextReplacement)
        }
    }
    
    static var automaticDashSubstitution: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticDashSubstitution) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticDashSubstitution)
        }
    }

    static var isHiddenSidebar: Bool {
        get {
            if let result = shared?.object(forKey: Constants.HideSidebar) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.HideSidebar)
        }
    }
    
    static var shouldFocusSearchOnESCKeyDown: Bool {
        get {
            if let result = UserDefaults.standard.object(forKey: Constants.shouldFocusSearchOnESCKeyDown) as? Bool {
                return result
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.shouldFocusSearchOnESCKeyDown)
        }
    }
    
    static var automaticConflictsResolution: Bool {
        get {
            if let result = UserDefaults.standard.object(forKey: Constants.AutomaticConflictsResolution) as? Bool {
                return result
            }
            return false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.AutomaticConflictsResolution)
        }
    }

    static var useTextBundleMetaToStoreDates: Bool {
        get {
            if let result = UserDefaults.standard.object(forKey: Constants.UseTextBundleToStoreDates) as? Bool {
                return result
            }
            
            return false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UseTextBundleToStoreDates)
        }
    }

    static var showInMenuBar: Bool {
        get {
            if let result = shared?.object(forKey: Constants.ShowInMenuBar) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.ShowInMenuBar)
        }
    }
    
    static var fileContainer: NoteContainer {
        get {
            if let result = shared?.object(forKey: Constants.NoteContainer) as? Int, let container = NoteContainer(rawValue: result) {
                return container
            }
            return .none
        }
        set {
            shared?.set(newValue.rawValue, forKey: Constants.NoteContainer)
        }
    }

    static var fileFormat: NoteType {
        get {
            return .Markdown
        }
        set {
            shared?.set(newValue.tag, forKey: Constants.NoteType)
        }
    }

    static var noteExtension: String {
        get {
            if let result = shared?.object(forKey: Constants.NoteExtension) as? String {
                return result
            }

            return "markdown"
        }
        set {
            shared?.set(newValue, forKey: Constants.NoteExtension)
        }
    }

    static var previewFontSize: Int {
        get {
            if let result = shared?.object(forKey: Constants.PreviewFontSize) as? Int {
                return result
            }
            return 11
        }
        set {
            shared?.set(newValue, forKey: Constants.PreviewFontSize)
        }
    }

    static var hidePreviewImages: Bool {
        get {
            if let result = shared?.object(forKey: Constants.HidePreviewImages) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.HidePreviewImages)
        }
    }

    static var suppressNewEncryptionFormatNotice: Bool {
        get { shared?.bool(forKey: Constants.SuppressNewEncryptionFormatNotice) ?? false }
        set { shared?.set(newValue, forKey: Constants.SuppressNewEncryptionFormatNotice) }
    }

    static var lockOnSleep: Bool {
        get {
            if let result = shared?.object(forKey: Constants.LockOnSleep) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.LockOnSleep)
        }
    }

    static var lockOnScreenActivated: Bool {
        get {
            if let result = shared?.object(forKey: Constants.LockOnScreenActivated) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.LockOnScreenActivated)
        }
    }

    static var lockOnUserSwitch: Bool {
        get {
            if let result = shared?.object(forKey: Constants.LockAfterUserSwitch) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.LockAfterUserSwitch)
        }
    }

    static var hideDate: Bool {
        get {
            if let result = shared?.object(forKey: Constants.HideDate) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.HideDate)
        }
    }

    static var indentUsing: Int {
        get {
            if let result = shared?.integer(forKey: Constants.IndentUsing) {
                return result
            }

            return 0
        }
        set {
            shared?.set(newValue, forKey: Constants.IndentUsing)
        }
    }

    static var firstLineAsTitle: Bool {
        get {
            if let result = shared?.object(forKey: Constants.FirstLineAsTitle) as? Bool {
                return result
            }

            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.FirstLineAsTitle)
        }
    }

    static var marginSize: Float {
        get {
            if let result = shared?.object(forKey: Constants.MarginSizeKey) as? Float {
                return result
            }
            return 20
        }
        set {
            shared?.set(newValue, forKey: Constants.MarginSizeKey)
        }
    }

    static var gitStorage: URL? {
        get {
            if let repositories = shared?.url(forKey: Constants.GitStorage) {
                if !FileManager.default.fileExists(atPath: repositories.path) {
                    try? FileManager.default.createDirectory(at: repositories, withIntermediateDirectories: true, attributes: nil)
                }

                return repositories
            }

            if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let repositories = applicationSupport.appendingPathComponent("Repositories")
                
                if !FileManager.default.fileExists(atPath: repositories.path) {
                    try? FileManager.default.createDirectory(at: repositories, withIntermediateDirectories: true, attributes: nil)
                }
                
                return repositories
            }
            
            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.GitStorage)
        }
    }
    
    
    

    static var snapshotsInterval: Int {
        get {
            if let interval = shared?.object(forKey: Constants.SnapshotsInterval) as? Int {
                return interval
            }

            return self.DefaultSnapshotsInterval
        }
        set {
            shared?.set(newValue, forKey: Constants.SnapshotsInterval)
        }
    }
    

    static var snapshotsIntervalMinutes: Int {
        get {
            if let interval = shared?.object(forKey: Constants.SnapshotsIntervalMinutes) as? Int {
                return interval
            }

            return self.DefaultSnapshotsIntervalMinutes
        }
        set {
            shared?.set(newValue, forKey: Constants.SnapshotsIntervalMinutes)
        }
    }

    static var backupManually: Bool {
        get {
            if let returnMode = shared?.object(forKey: Constants.BackupManually) as? Bool {
                return returnMode
            } else {
                return true
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.BackupManually)
        }
    }

    static var fullScreen: Bool {
        get {
            if let result = shared?.object(forKey: Constants.FullScreen) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.FullScreen)
        }
    }

    static var inlineTags: Bool {
        get {
            if let result = shared?.object(forKey: Constants.InlineTags) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.InlineTags)
        }
    }

    static var showWelcome: Bool {
        get {
            if let result = shared?.object(forKey: Constants.Welcome) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.Welcome)
        }
    }

    static var mathJaxPreview: Bool {
        get {
            if let result = shared?.object(forKey: Constants.MathJaxPreview) as? Bool {
                return result
            }

            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.MathJaxPreview)
        }
    }
    
    static var sidebarVisibilityInbox: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityInbox") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityInbox")
        }
    }

    static var sidebarVisibilityNotes: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityNotes") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityNotes")
        }
    }

    static var sidebarVisibilityTodo: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityTodo") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityTodo")
        }
    }

    static var sidebarVisibilityUntagged: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityUntagged") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityUntagged")
        }
    }

    static var sidebarVisibilityTrash: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityTrash") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityTrash")
        }
    }

    static var crashedLastTime: Bool {
        get {
            if let result = shared?.object(forKey: Constants.CrashedLastTime) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.CrashedLastTime)
        }
    }

    static var lastNews: Date? {
        get {
            if let sync = shared?.object(forKey: "lastNews") {
                return sync as? Date
            } else {
                return nil
            }
        }
        set {
            shared?.set(newValue, forKey: "lastNews")
        }
    }

    static var naming: SettingsFilesNaming {
        get {
            if let result = shared?.object(forKey: "naming") as? Int, let settings = SettingsFilesNaming(rawValue: result) {
                return settings
            }

            return .autoRename
        }
        set {
            shared?.set(newValue.rawValue, forKey: "naming")
        }
    }

    static var autoInsertHeader: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutoInsertHeader) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.AutoInsertHeader)
        }
    }

    static var nonContiguousLayout: Bool {
        get {
            if let result = shared?.object(forKey: Constants.NonContiguousLayout), let data = result as? Bool {
                return data
            }

            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.NonContiguousLayout)
        }
    }

    static var codeBlocksWithSyntaxHighlighting: Bool {
        get {
            if let result = shared?.object(forKey: Constants.CodeBlocksWithSyntaxHighlighting) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.CodeBlocksWithSyntaxHighlighting)
        }
    }

    static var lastScreenX: Int? {
        get {
            if let value = shared?.object(forKey: Constants.LastScreenX) as? Int {
                return value
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastScreenX)
        }
    }

    static var lastScreenY: Int? {
        get {
            if let value = shared?.object(forKey: Constants.LastScreenY) as? Int {
                return value
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastScreenY)
        }
    }

    // Search history is session-only. Remove earlier builds' persisted queries on access.
    private static var sessionRecentSearches: [String]?
    static var recentSearches: [String]? {
        get {
            shared?.removeObject(forKey: Constants.RecentSearches)
            return sessionRecentSearches
        }
        set {
            shared?.removeObject(forKey: Constants.RecentSearches)
            sessionRecentSearches = newValue
        }
    }

    static var searchHighlight: Bool {
        get {
            if let result = shared?.object(forKey: Constants.SearchHighlight) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.SearchHighlight)
        }
    }

    static var autoVersioning: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutoVersioning) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.AutoVersioning)
        }
    }
    
    
    
    
    
    
    
    
    

    
    
    
    static var clickableLinks: Bool {
        get {
            if let highlight = shared?.object(forKey: Constants.ClickableLinks) as? Bool {
                return highlight
            }
            
                return false
        }
        set {
            shared?.set(newValue, forKey: Constants.ClickableLinks)
        }
    }
    
    static var trashURL: URL? {
        get {
            if let trashUrl = shared?.url(forKey: Constants.TrashKey) {
                return trashUrl
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.TrashKey)
        }
    }
    
    static var separateRepo: Bool {
        get {
            if let result = shared?.object(forKey: Constants.SeparateRepo) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.SeparateRepo)
        }
    }
    
    static var askCommitMessage: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AskCommitMessage) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AskCommitMessage)
        }
    }
    
    static var lastCommitMessage: String? {
        get {
            if let result = shared?.object(forKey: Constants.LastCommitMessage) as? String, result.count > 0 {
                return result
            }
            
            return nil
        }
        
        set {
            shared?.set(newValue, forKey: Constants.LastCommitMessage)
        }
    }
    
    static var maxChildDirs: Int {
        get {
            if let maxChildDirs = shared?.object(forKey: Constants.MaxChildDirs),
                let value = maxChildDirs as? Int {

                if value < 200 {
                    return 200
                }

                return value
            }

            return 200
        }
        set {
            shared?.set(newValue, forKey: Constants.MaxChildDirs)
        }
    }

    static var codeTheme: EditorTheme {
        get {
            guard
                let raw = UserDefaults.standard.string(forKey: Constants.codeTheme),
                let theme = EditorTheme(rawValue: raw)
            else {
                return .consolinotes
            }
                
            return theme
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Constants.codeTheme)
        }
    }
    
    static var isFirstLaunch: Bool {
        get {
            if let result = shared?.object(forKey: Constants.IsFirstLaunch) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.IsFirstLaunch)
        }
    }
    
    static var italic: String {
        get {
            if let returnFontName = shared?.object(forKey: Constants.italicKey) as? String {
                return returnFontName
            }
            
            return "*"
        }
        set {
            shared?.set(newValue, forKey: Constants.italicKey)
        }
    }
    
    static var bold: String {
        get {
            if let returnFontName = shared?.object(forKey: Constants.boldKey) as? String {
                return returnFontName
            }
            
            return "__"
        }
        set {
            shared?.set(newValue, forKey: Constants.boldKey)
        }
    }
}
