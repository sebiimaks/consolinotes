//
//  ImageAttachment.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/15/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation
import AVKit

import Cocoa
typealias PlatformImage = NSImage

// MARK: - NoteAttachment

class NoteAttachment {

    // MARK: - Properties

    public let url: URL
    public var imageCache: URL?

    // MARK: - Constants

    private enum Constants {
        static let previewPrefix = "Preview"
        static let thumbnailPrefix = "ThumbnailsBig"
        static let fontFamily = "Avenir Next"
        static let defaultFontSize: CGFloat = 14.0
        static let fileSizeThreshold = 10000
        static let bytesInMB: Double = 1_000_000
    }

    // MARK: - Initialization

    init(url: URL) {
        self.url = url
    }

    // MARK: - Public Methods

    public func getImageText() -> String {
        let fileSize = url.fileSize
        let sizeTitle = formatFileSize(Int(fileSize))
        return " \(url.lastPathComponent) – \(sizeTitle) 📎 "
    }

    public func getImageWidth(text: String) -> Double {
        let font = getAttachmentFont()
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    public func getAttachmentImage() -> PlatformImage? {
        let height = UserDefaultsManagement.noteFont.getAttachmentHeight()
        let text = getImageText()
        let width = getImageWidth(text: text)
        let imageSize = CGSize(width: width, height: height)

        return imageFromText(text: text, imageSize: imageSize)
    }

    // MARK: - Private Methods

    private func formatFileSize(_ size: Int) -> String {
        if size > Constants.fileSizeThreshold {
            let sizeInMB = Double(size) / Constants.bytesInMB
            return String(format: "%.2f MB", sizeInMB)
        }
        return "\(size) bytes"
    }

    private func getAttachmentFont() -> PlatformFont {
        let traits = NSFontTraitMask(rawValue: NSFontTraitMask.RawValue(
            NSFontBoldTrait | NSFontItalicTrait
        ))

        return NSFontManager().font(
            withFamily: Constants.fontFamily,
            traits: traits,
            weight: 1,
            size: CGFloat(UserDefaultsManagement.fontSize)
        ) ?? PlatformFont.systemFont(ofSize: Constants.defaultFontSize)
    }

    public func imageFromText(text: String, imageSize: CGSize) -> PlatformImage? {
        let font = getAttachmentFont()
        let attributes = createTextAttributes(font: font)
        let textSize = text.size(withAttributes: attributes)

        return createImageMacOS(text: text, imageSize: imageSize, attributes: attributes, textSize: textSize)
    }

    private func createTextAttributes(font: PlatformFont) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let isDark = UserDataService.instance.isDark
        let textColor: PlatformColor = isDark ? .white : .black
        let backgroundColor: PlatformColor = isDark ?
            NSColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 1.00) : .white

        return [
            .font: font,
            .foregroundColor: textColor,
            .backgroundColor: backgroundColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func calculateCenteredRect(textSize: CGSize, containerSize: CGSize) -> CGRect {
        return CGRect(
            x: (containerSize.width - textSize.width) / 2.0,
            y: (containerSize.height - textSize.height) / 2.0,
            width: textSize.width,
            height: textSize.height
        )
    }
}

// MARK: - Static Utility Methods (Platform-Independent)

extension NoteAttachment {
    public static func getCacheUrl(from url: URL, prefix: String = Constants.previewPrefix) -> URL? {
        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent(prefix)

        let filename = url.absoluteString.md5 + "." + url.pathExtension
        return temporary.appendingPathComponent(filename)
    }

    public static func savePreviewImage(url: URL, image: PlatformImage, prefix: String = Constants.previewPrefix) {
        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent(prefix)

        createDirectoryIfNeeded(at: temporary)

        guard let cacheUrl = getCacheUrl(from: url, prefix: prefix),
              let data = image.jpgData else {
            return
        }

        try? data.write(to: cacheUrl)
    }

    private static func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    public static func getImage(url: URL, size: CGSize) -> PlatformImage? {
        guard let image = loadImage(from: url, size: size) else {
            return nil
        }

        return getCachedOrResizedImage(original: image, url: url, size: size)
    }

    private static func loadImage(from url: URL, size: CGSize) -> PlatformImage? {
        if url.isVideo {
            return generateVideoThumbnail(from: url, size: size)
        }

        guard let imageData = try? Data(contentsOf: url) else {
            return nil
        }

        return NSImage(data: imageData)
    }

    private static func generateVideoThumbnail(from url: URL, size: CGSize) -> PlatformImage? {
        let asset = AVURLAsset(url: url, options: nil)
        let generator = AVAssetImageGenerator(asset: asset)

        guard let cgImage = try? generator.copyCGImage(
            at: CMTimeMake(value: 0, timescale: 1),
            actualTime: nil
        ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: size)
    }

    private static func getCachedOrResizedImage(
        original: PlatformImage,
        url: URL,
        size: CGSize
    ) -> PlatformImage? {
        let cacheURL = getCacheUrl(from: url, prefix: Constants.thumbnailPrefix)

        if let cacheURL = cacheURL,
           FileManager.default.fileExists(atPath: cacheURL.path) {
            if let cached = NSImage(contentsOfFile: cacheURL.path) {
                return cached
            }
        }

        guard let resized = original.resized(to: size) else {
            return original
        }

        savePreviewImage(url: url, image: resized, prefix: Constants.thumbnailPrefix)
        return resized
    }

    private static func resizeImage(_ image: PlatformImage, to size: CGSize) -> PlatformImage? {
        return image
    }
}

// MARK: - macOS Specific Methods

extension NoteAttachment {
    private func createImageMacOS(
        text: String,
        imageSize: CGSize,
        attributes: [NSAttributedString.Key: Any],
        textSize: CGSize
    ) -> NSImage? {
        let imageRect = NSRect(origin: .zero, size: imageSize)
        let image = NSImage(size: imageRect.size)

        image.lockFocus()
        defer { image.unlockFocus() }

        // Fill background
        (attributes[.backgroundColor] as? NSColor)?.setFill()
        imageRect.fill()

        // Draw centered text
        let textRect = calculateCenteredRect(textSize: textSize, containerSize: imageSize)
        text.draw(in: textRect, withAttributes: attributes)

        return image
    }
}
