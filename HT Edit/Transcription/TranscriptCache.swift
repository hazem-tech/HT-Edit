//
//  TranscriptCache.swift
//  HT Edit
//

import CryptoKit
import Foundation

/// Finished transcripts on disk, so transcribing a file again with the same
/// model and context costs nothing.
actor TranscriptCache {
    nonisolated static let shared = TranscriptCache(
        directory: URL.cachesDirectory.appending(path: "Transcripts", directoryHint: .isDirectory)
    )

    /// Bump when the transcription pipeline or the stored format changes.
    nonisolated static let formatVersion = 2

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Whisper's transcript of a file with these options.
    nonisolated static func key(for url: URL, options: TranscriptionOptions) -> String? {
        let context = options.context.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileCacheKey.key(for: url, salt: "transcript|whisper-\(WhisperInstallation.modelName)|\(options.language ?? "auto")|\(context)|\(formatVersion)")
    }

    /// The proofread version of exactly `raw`, by `model` with `context`.
    nonisolated static func cleanupKey(for url: URL, raw: [TranscriptSegment], model: String, context: String) -> String? {
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.map(\.text).joined(separator: "\n")
        return FileCacheKey.key(for: url, salt: "cleanup|\(model)|\(context)|\(formatVersion)|\(Self.digest(text))")
    }

    private nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
