//
//  TitleTemplates.swift
//  HT Edit
//

import Foundation

/// Finds the Final Cut title the user typed: by name (built-in titles and
/// those installed in ~/Movies/Motion Templates.localized/Titles.localized),
/// or by the path of its `.moti` file or folder.
nonisolated enum TitleTemplates {

    static let defaultCaptionTitle = "Basic Title"

    /// Titles that ship with Final Cut Pro, by lowercased name.
    static let builtIn: [String: TitleTemplate] = {
        let titles = [
            TitleTemplate(
                name: "Basic Title",
                uid: ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti",
                source: .builtIn
            ),
            TitleTemplate(
                name: "Basic Lower Third",
                uid: ".../Titles.localized/Lower Thirds.localized/Basic Lower Third.localized/Basic Lower Third.moti",
                source: .builtIn
            ),
        ]
        return Dictionary(uniqueKeysWithValues: titles.map { ($0.name.lowercased(), $0) })
    }()

    /// ~/Movies/Motion Templates.localized
    static var motionTemplatesDirectory: URL {
        URL.moviesDirectory.appending(path: "Motion Templates.localized", directoryHint: .isDirectory)
    }

    /// Every title installed under `motionTemplates`/Titles.localized, sorted by name.
    static func installed(in motionTemplates: URL = motionTemplatesDirectory) -> [TitleTemplate] {
        let titles = motionTemplates.appending(path: "Titles.localized", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: titles,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [String: TitleTemplate] = [:]
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "moti" {
            guard let template = template(at: url, motionTemplates: motionTemplates) else { continue }
            let key = template.name.lowercased()
            if result[key] == nil { result[key] = template }
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The title for what the user typed: a path (`/…` or `~/…`, to a `.moti`
    /// file or the folder holding one), or a name (case-insensitive; installed
    /// titles first, then built-in ones). An unknown name still gets the uid
    /// Final Cut would use, so installing it later relinks it.
    static func resolve(
        _ typed: String,
        installed: [TitleTemplate],
        motionTemplates: URL = motionTemplatesDirectory
    ) -> TitleTemplate {
        var trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = defaultCaptionTitle }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = (trimmed as NSString).expandingTildeInPath
            let url = URL(filePath: path)
            if let file = motiFile(at: url),
               let template = template(at: file, motionTemplates: motionTemplates) {
                return template
            }
            let name = displayName(url.deletingPathExtension().lastPathComponent)
            return TitleTemplate(name: name, uid: path, source: .notFound)
        }

        let key = trimmed.lowercased()
        if let match = installed.first(where: { $0.name.lowercased() == key }) { return match }
        if let match = builtIn[key] { return match }
        return TitleTemplate(name: trimmed, uid: "~/Titles.localized/\(trimmed)/\(trimmed).moti", source: .notFound)
    }

    /// `url` if it is a `.moti` file, or the first `.moti` file inside it if it is a folder.
    static func motiFile(at url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return url.pathExtension.lowercased() == "moti" ? url : nil }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "moti" {
            return file
        }
        return nil
    }

    /// The title for a `.moti` file. Final Cut only loads titles from Motion
    /// Templates, so a file anywhere else is reported as outside it.
    static func template(at file: URL, motionTemplates: URL) -> TitleTemplate? {
        let name = displayName(file.deletingPathExtension().lastPathComponent)
        let base = motionTemplates.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard components.count > base.count, Array(components.prefix(base.count)) == base else {
            return TitleTemplate(name: name, uid: file.path(percentEncoded: false), source: .outsideMotionTemplates)
        }
        let relative = components.dropFirst(base.count).joined(separator: "/")
        return TitleTemplate(name: name, uid: "~/" + relative, source: .installed)
    }

    /// `"Basic Title.localized"` → `"Basic Title"`.
    static func displayName(_ name: String) -> String {
        name.hasSuffix(".localized") ? String(name.dropLast(".localized".count)) : name
    }
}
