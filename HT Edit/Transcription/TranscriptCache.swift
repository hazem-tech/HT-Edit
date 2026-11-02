//
//  TranscriptCache.swift
//  HT Edit
//

import CryptoKit
import Foundation

/// On-disk JSON cache for transcription results, so nothing is ever sent to
/// Gemini twice:
/// - word timings, keyed by the media file (path, size, modification date);
/// - polished phrases, keyed by the words and the text-pass settings;
/// - summaries, keyed by the transcript text and the model.
actor TranscriptCache {
    nonisolated static let shared = TranscriptCache(directory: TranscriptCache.defaultDirectory)

    /// Bump when the cached formats change.
    nonisolated static let formatVersion = 1

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "Transcripts", directoryHint: .isDirectory)
    }

    // MARK: Keys

    /// Key for the word timings of the file at `url`, or `nil` if it can't be read.
    nonisolated static func wordsKey(for url: URL) -> String? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "words-" + hash("\(url.standardizedFileURL.path)|\(size)|\(modified)|\(TranscriptionTier.speechModel)|\(formatVersion)")
    }

    nonisolated static func phrasesKey(wordsKey: String, settings: TranscriptionSettings) -> String {
        "phrases-" + hash("\(wordsKey)|\(settings.textPassFingerprint)|\(formatVersion)")
    }

    nonisolated static func summaryKey(transcript: String, settings: TranscriptionSettings) -> String {
        "summary-" + hash("\(transcript)|\(settings.textPassFingerprint)|\(formatVersion)")
    }

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Storage

    func load<Value: Decodable & Sendable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func store<Value: Encodable & Sendable>(_ value: Value, key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: fileURL(for: key), options: .atomic)
        } catch {
            // A failed cache write only costs a repeated request later.
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appending(path: key + ".json", directoryHint: .notDirectory)
    }
}
