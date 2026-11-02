//
//  TranscriptionSettings.swift
//  HT Edit
//

import Foundation

/// Cost/quality level. Timing always comes from Gemini's dedicated speech
/// model (exact word timestamps); the tier picks the language model used to
/// polish the text and to write summaries.
nonisolated enum TranscriptionTier: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, medium, high

    var id: String { rawValue }

    /// Speech-to-text with word timestamps, used by every tier.
    static let speechModel = "gemini-3.5-transcribe"

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .low:
            "Cheapest. One request per clip. The text is polished only when you add context or key words."
        case .medium:
            "Every transcript is polished by a stronger model (one more request per clip). Free keys only get a few of these a day."
        case .high:
            "Most accurate polishing and summaries. Needs a paid API key."
        }
    }

    /// Language model for polishing and summaries.
    var textModel: String {
        switch self {
        case .low: "gemini-flash-lite-latest"
        case .medium: "gemini-flash-latest"
        case .high: "gemini-pro-latest"
        }
    }

    /// Least thinking each model accepts: thinking tokens cost money and time.
    var thinkingLevel: String {
        switch self {
        case .low: "minimal"
        case .medium, .high: "low"
        }
    }

    /// Whether a text pass runs after speech-to-text. On Low it only runs when
    /// the user gave context or key words, so the default costs one request per clip.
    func runsTextPass(hasContext: Bool) -> Bool {
        self != .low || hasContext
    }
}

/// Transcription options, persisted in `UserDefaults`.
nonisolated struct TranscriptionSettings: Codable, Equatable, Sendable {
    var tier: TranscriptionTier = .low
    /// Free text describing the video (topic, speakers, spelling notes).
    var context = ""
    /// Names and terms, separated by commas or new lines.
    var keywords = ""
    var showsCaptions = true

    static let `default` = TranscriptionSettings()

    var trimmedContext: String { context.trimmingCharacters(in: .whitespacesAndNewlines) }

    var keywordList: [String] {
        var seen = Set<String>()
        return keywords
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// `true` when the user typed something the transcript should take into account.
    var hasContext: Bool { !trimmedContext.isEmpty || !keywordList.isEmpty }

    var runsTextPass: Bool { tier.runsTextPass(hasContext: hasContext) }

    /// Identifies everything that changes the polished text (for caching).
    var textPassFingerprint: String {
        "\(tier.textModel)|\(trimmedContext)|\(keywordList.joined(separator: ","))"
    }

    // MARK: Persistence

    private static let defaultsKey = "transcriptionSettings"

    static func load(from defaults: UserDefaults = .standard) -> TranscriptionSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TranscriptionSettings.self, from: data) else { return .default }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
