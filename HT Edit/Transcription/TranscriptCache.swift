//
//  TranscriptCache.swift
//  HT Edit
//

import Foundation

/// Finished transcripts on disk, so transcribing a file again with the same
/// model and context costs nothing.
actor TranscriptCache {
    nonisolated static let shared = TranscriptCache(
        directory: URL.cachesDirectory.appending(path: "Transcripts", directoryHint: .isDirectory)
    )

    /// Bump when the prompt or the stored format changes.
    nonisolated static let formatVersion = 1

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Word timing of transcripts with measured word times. Bump when the aligner changes.
    nonisolated static let alignedWordTiming = "words-mms-1"

    /// - Parameter wordTiming: how word times were found: empty when they're
    ///   estimated, `alignedWordTiming` when they're measured. Installing the
    ///   aligner later then transcribes again instead of keeping estimates.
    nonisolated static func key(for url: URL, model: String, context: String, wordTiming: String = "") -> String? {
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let timing = wordTiming.isEmpty ? "" : "|\(wordTiming)"
        return FileCacheKey.key(for: url, salt: "transcript|\(model)|\(context)|\(formatVersion)\(timing)")
    }

    func load(key: String) -> [TranscriptSegment]? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return try? JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    func store(_ segments: [TranscriptSegment], key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(segments).write(to: fileURL(for: key), options: .atomic)
        } catch {
            // A failed cache write only costs a new transcription next time.
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appending(path: key + ".json", directoryHint: .notDirectory)
    }
}
