//
//  NSPasteboard+.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 25.09.2020.
//  Copyright © 2020 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

extension NSPasteboard {
    // Notes and folders dragged within consolinotes. Distinct from FSNotes, so a drag from FSNotes isn't taken for one of ours.
    public static var note: NSPasteboard.PasteboardType {
        .init("io.github.sebiimaks.consolinotes.pasteboard.note")
    }

    public static var project: NSPasteboard.PasteboardType {
        .init("io.github.sebiimaks.consolinotes.pasteboard.project")
    }

    // Bounded structured content; never decode legacy arbitrary object archives.
    public static var attributed: NSPasteboard.PasteboardType {
        .init("io.github.sebiimaks.consolinotes.pasteboard.content.v1")
    }
}


/// The Find query belongs to this process, never to the system Find pasteboard.
enum LocalFindState {
    static var query = ""
}

/// Clipboard data has no archived classes, styles, file wrappers or external URLs.
/// Markdown formatting is already represented by text; tasks are serialized as Markdown.
enum NotePasteboardCodec {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumTextBytes = 2 * 1024 * 1024
    static let maximumAttachmentBytes = 8 * 1024 * 1024
    struct Attachment: Codable {
        let location: Int
        let filename: String
        let title: String
        let data: Data
    }
    struct Payload: Codable {
        let version: Int
        let text: String
        let attachments: [Attachment]
    }

    static func encode(_ source: NSAttributedString) -> Data? {
        let text = NSMutableAttributedString(attributedString: source).unloadTasks()
        text.enumerateAttribute(.todo, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil {
                text.removeAttribute(.attachment, range: range)
                text.removeAttribute(.todo, range: range)
            }
        }
        guard text.string.utf8.count <= maximumTextBytes else { return nil }
        var attachments = [Attachment]()
        var valid = true
        var total = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard value != nil else { return }
            guard range.length == 1, attachments.count < 256,
                  let url = text.attribute(.attachmentUrl, at: range.location, effectiveRange: nil) as? URL,
                  (url.isFileURL || url.scheme == "consolinotes-memory") else { valid = false; stop.pointee = true; return }
            let pending = text.attribute(.attachmentSave, at: range.location, effectiveRange: nil) as? Data
            let memory = text.attribute(.attachmentMemoryData, at: range.location, effectiveRange: nil) as? Data
            guard let data = pending ?? memory ?? (url.isFileURL ? readAttachment(url) : nil), data.count <= maximumAttachmentBytes,
                  total <= maximumBytes / 2 - data.count else { valid = false; stop.pointee = true; return }
            total += data.count
            let name = url.lastPathComponent
            guard validFilename(name) else { valid = false; stop.pointee = true; return }
            let title = text.attribute(.attachmentTitle, at: range.location, effectiveRange: nil) as? String ?? ""
            guard title.utf8.count <= 4096 else { valid = false; stop.pointee = true; return }
            attachments.append(Attachment(location: range.location, filename: name, title: title, data: data))
        }
        guard valid, let result = try? JSONEncoder().encode(Payload(version: 1, text: text.string, attachments: attachments)),
              result.count <= maximumBytes else { return nil }
        return result
    }

    static func decode(_ data: Data) -> NSMutableAttributedString? {
        guard data.count <= maximumBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1,
              payload.text.utf8.count <= maximumTextBytes, payload.attachments.count <= 256 else { return nil }
        let text = payload.text as NSString
        var previous = -1
        var total = 0
        for item in payload.attachments {
            guard item.location > previous, item.location < text.length,
                  text.character(at: item.location) == 0xfffc,
                  validFilename(item.filename), item.title.utf8.count <= 4096,
                  item.data.count <= maximumAttachmentBytes,
                  total <= maximumBytes / 2 - item.data.count else { return nil }
            total += item.data.count
            previous = item.location
        }
        let result = NSMutableAttributedString(string: payload.text)
        for item in payload.attachments {
            // This URL supplies only a filename. The embedded bytes are consumed by the
            // normal attachment importer; no source path from the sender is opened.
            result.addAttributes([
                .attachment: NSTextAttachment(),
                .attachmentSave: item.data,
                .attachmentUrl: URL(fileURLWithPath: "/clipboard/" + item.filename),
                .attachmentPath: "",
                .attachmentTitle: item.title
            ], range: NSRange(location: item.location, length: 1))
        }
        return result
    }

    private static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func readAttachment(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size <= UInt64(maximumAttachmentBytes) else { return nil }
        do {
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: maximumAttachmentBytes + 1) ?? Data()
            return data.count <= maximumAttachmentBytes ? data : nil
        } catch { return nil }
    }
}

/// Local-only, expiring clipboard writes. Never clear a newer copy from another app.
enum SensitiveClipboard {
    static var expirySeconds: TimeInterval {
        get {
            let value = UserDefaults.standard.object(forKey: "privateClipboardExpirySeconds") as? Double ?? 60
            return [30.0, 60, 120, 300].contains(value) ? value : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: "privateClipboardExpirySeconds") }
    }
    private static var ownedBoard: NSPasteboard?
    private static var ownedChange: Int?
    private static var ownedToken: String?
    private static var timer: Timer?
    private static let ownershipType = NSPasteboard.PasteboardType("io.github.sebiimaks.consolinotes.clipboard-owner")

    static func writeString(_ string: String, to board: NSPasteboard = .general, expiresAfter: TimeInterval? = nil) {
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        writeItem(item, to: board, expiresAfter: expiresAfter)
    }

    @discardableResult
    static func write(_ source: NSAttributedString, plainText: String, to board: NSPasteboard = .general,
                      requireCompleteContent: Bool = false) -> Bool {
        // Finish all file reads before claiming the pasteboard, so a slow attachment
        // cannot cause us to claim a newer copy from another application.
        let data = NotePasteboardCodec.encode(source)
        guard !requireCompleteContent || data != nil else { return false }
        let item = NSPasteboardItem()
        item.setString(plainText, forType: .string)
        if let data = data { item.setData(data, forType: NSPasteboard.attributed) }
        return writeItem(item, to: board)
    }

    static func writeURL(_ url: URL, to board: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: url.isFileURL ? .fileURL : .URL)
        item.setString(url.absoluteString, forType: .string)
        writeItem(item, to: board)
    }

    @discardableResult
    private static func writeItem(_ item: NSPasteboardItem, to board: NSPasteboard, expiresAfter: TimeInterval? = nil) -> Bool {
        let token = UUID().uuidString
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString(token, forType: ownershipType)
        timer?.invalidate(); timer = nil
        ownedBoard = nil; ownedChange = nil; ownedToken = nil
        board.prepareForNewContents(with: .currentHostOnly)
        guard board.writeObjects([item]) else { return false }
        let change = board.changeCount
        guard board.string(forType: ownershipType) == token, board.changeCount == change else { return false }
        ownedBoard = board; ownedChange = change; ownedToken = token
        timer = Timer(timeInterval: expiresAfter ?? expirySeconds, repeats: false) { _ in clearOwned() }
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
        return true
    }

    static func clearOwned() {
        timer?.invalidate(); timer = nil
        if let board = ownedBoard, board.changeCount == ownedChange,
           board.string(forType: ownershipType) == ownedToken, board.changeCount == ownedChange { board.clearContents() }
        ownedBoard = nil; ownedChange = nil; ownedToken = nil
    }
}
