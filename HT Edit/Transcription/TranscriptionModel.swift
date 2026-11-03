//
//  TranscriptionModel.swift
//  HT Edit
//

import Foundation

/// A model Antigravity can run that hears audio and returns timestamps.
nonisolated struct TranscriptionModel: Identifiable, Hashable, Sendable {
    /// The slug passed to `agy --model`.
    let id: String
    let displayName: String

    /// Every model the picker may offer, **cheapest first**.
    ///
    /// Only Gemini models that take audio input and return usable segment
    /// timestamps belong here. Antigravity also offers models that can't hear
    /// audio; they are deliberately left out. The picker narrows this list to
    /// what `agy models` reports for the signed-in account.
    static let catalog: [TranscriptionModel] = [
        TranscriptionModel(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite"),
        TranscriptionModel(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite"),
        TranscriptionModel(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash"),
        TranscriptionModel(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash"),
        TranscriptionModel(id: "gemini-3.1-pro", displayName: "Gemini 3.1 Pro"),
    ]

    /// The catalog entries that appear in `agy models` output, cheapest first.
    ///
    /// The output format isn't documented, so this matches each model's slug or
    /// display name anywhere in the text. A match inside a longer name doesn't
    /// count: `gemini-3.5-flash` must not match `gemini-3.5-flash-lite`, while
    /// `gemini-3.6-flash-preview` still counts as `gemini-3.6-flash`.
    static func available(inModelList output: String) -> [TranscriptionModel] {
        let text = output.lowercased()
        return catalog.filter { model in
            contains(text, name: model.id) || contains(text, name: model.displayName.lowercased())
        }
    }

    private static func contains(_ text: String, name: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: name, range: searchStart..<text.endIndex) {
            let rest = text[range.upperBound...]
            let continuesWord = rest.first.map { $0.isLetter || $0.isNumber } ?? false
            if !continuesWord, !rest.hasPrefix("-lite"), !rest.hasPrefix(" lite") {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }
}
