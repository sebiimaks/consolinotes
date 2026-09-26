//
//  File.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/4/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

class NameHelper {
    public static func getUniqueFileName(name: String, postfix: Int = 1, project: Project, ext: String) -> URL {

        var defaultName = UUID().uuidString
        if let naming = SettingsFilesNaming(rawValue: UserDefaultsManagement.naming.rawValue) {
            defaultName = naming.getName()
        }

        var postfix = postfix
        var name = name
            .trimmingCharacters(in: CharacterSet.whitespaces)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")

        if name.isEmpty {
            name = defaultName

            if UserDefaultsManagement.naming.usesSequenceSuffix {
                return sequencedFileName(name, project: project, ext: ext)
            }
        }

        var fileUrl = project.url
        fileUrl.appendPathComponent(name + "." + ext, isDirectory: false)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileUrl.path) {
            let regex = try? NSRegularExpression(pattern: "(.+)\\s(\\d)+$", options: .caseInsensitive)

            if let result = regex?.firstMatch(in: name, range: NSRange(0..<name.count)) {

                if let range = Range(result.range(at: 1), in: name) {
                    name = String(name[range])
                }

                if let range = Range(result.range(at: 2), in: name) {
                    let digit = name[range]

                    if let converted = Int(digit) {
                        postfix = converted
                    }
                }
            }

            let increment = postfix + 1
            let newName = name + " " + String(increment)
            return NameHelper.getUniqueFileName(name: newName, postfix: increment, project: project, ext: ext)
        }

        return fileUrl
    }

    /// The first free name out of `name`, `name_001`, `name_002` and so on.
    private static func sequencedFileName(_ name: String, project: Project, ext: String) -> URL {
        var fileUrl = project.url.appendingPathComponent(name + "." + ext, isDirectory: false)
        var number = 0

        while FileManager.default.fileExists(atPath: fileUrl.path) {
            number += 1
            let numbered = name + "_" + String(format: "%03d", number)
            fileUrl = project.url.appendingPathComponent(numbered + "." + ext, isDirectory: false)
        }

        return fileUrl
    }

    public static func generateCopy(file: URL, dstDir: URL? = nil, number: Int = 1) -> URL {
        let dst = dstDir ?? file.deletingLastPathComponent()
        let ext = file.pathExtension
        var name = file.deletingPathExtension().lastPathComponent

        let regex = try? NSRegularExpression(pattern: "(.+)\\s(?:Copy\\s)+(?:\\d)+$", options: .caseInsensitive)
        if let result = regex?.firstMatch(in: name, range: NSRange(0..<name.count)) {
            if let range = Range(result.range(at: 1), in: name) {
                name = String(name[range])
            }
        }

        var endName = name
        if !endName.hasSuffix(" Copy") {
            endName += " Copy"
        }

        if number > 1 {
            endName += " " + String(number)
        }

        let newDst = dst.appendingPathComponent(endName + "." + ext, isDirectory: false)

        if !FileManager.default.fileExists(atPath: newDst.path) {
            return newDst
        }

        return generateCopy(file: file, dstDir: dst, number: number + 1)
    }
}
