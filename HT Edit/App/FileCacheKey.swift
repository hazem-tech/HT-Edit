//
//  FileCacheKey.swift
//  HT Edit
//

import CryptoKit
import Foundation

/// Cache keys for derived data (waveforms, transcripts) of a media file.
///
/// A key covers the file's path, size and modification date plus a `salt`
/// for the settings that produced the data, so an edited file, or a change
/// of settings, gets a new key automatically.
nonisolated enum FileCacheKey {
    /// The key for the file at `url`, or `nil` if its attributes can't be read.
    static func key(for url: URL, salt: String) -> String? {
        // `URL` caches resource values; read fresh ones so an edited file gets a new key.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let identity = "\(url.standardizedFileURL.path)|\(size)|\(modified)|\(salt)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
