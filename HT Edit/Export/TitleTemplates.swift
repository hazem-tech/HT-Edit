//
//  TitleTemplates.swift
//  HT Edit
//

import Foundation

/// Finds Final Cut title templates by name: the built-in ones HT Edit knows,
/// and any installed in ~/Movies/Motion Templates.localized/Titles.localized
/// (where Motion and third-party titles, such as an "Adjustment Layer", go).
nonisolated enum TitleTemplates {

    static let defaultCaptionTitle = "Basic Title"
    static let defaultAdjustmentLayer = "Adjustment Layer"

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

    /// ~/Movies/Motion Templates.localized/Titles.localized
    static var userTitlesDirectory: URL {
        URL.moviesDirectory
            .appending(path: "Motion Templates.localized", directoryHint: .isDirectory)
            .appending(path: "Titles.localized", directoryHint: .isDirectory)
    }

    /// Every title installed in `directory`, sorted by name.
    static func installed(in directory: URL = userTitlesDirectory) -> [TitleTemplate] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var result: [String: TitleTemplate] = [:]
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "moti" {
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > base.count, Array(components.prefix(base.count)) == base else { continue }
            let relative = components.dropFirst(base.count).joined(separator: "/")
            let name = displayName(url.deletingPathExtension().lastPathComponent)
            let key = name.lowercased()
            if result[key] == nil {
                result[key] = TitleTemplate(name: name, uid: "~/Titles.localized/" + relative, source: .installed)
            }
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The template called `name` (case-insensitive): installed titles first,
    /// then built-in ones. An unknown name still gets the uid Final Cut would
    /// use if it were installed, so it can be relinked by installing it.
    static func resolve(_ name: String, installed: [TitleTemplate]) -> TitleTemplate {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        if let match = installed.first(where: { $0.name.lowercased() == key }) { return match }
        if let match = builtIn[key] { return match }
        return TitleTemplate(
            name: trimmed,
            uid: "~/Titles.localized/\(trimmed)/\(trimmed).moti",
            source: .notFound
        )
    }

    /// `"Basic Title.localized"` → `"Basic Title"`.
    static func displayName(_ name: String) -> String {
        name.hasSuffix(".localized") ? String(name.dropLast(".localized".count)) : name
    }
}
