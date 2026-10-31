//
//  LevelsCache.swift
//  HT Edit
//

import CryptoKit
import Foundation

/// On-disk cache of finished audio analyses ("peak files"), so a file that was
/// imported before shows its waveform instantly.
///
/// Entries are keyed by path, size, modification date and analysis settings,
/// so an edited file is re-analyzed automatically.
actor LevelsCache {
    nonisolated static let shared = LevelsCache(directory: LevelsCache.defaultDirectory)

    /// Bump when the analysis algorithm or file layout changes.
    nonisolated static let formatVersion: UInt32 = 1
    private nonisolated static let magic: UInt32 = 0x48_54_4C_56 // "HTLV"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "Levels", directoryHint: .isDirectory)
    }

    /// Cache key for the file at `url`, or `nil` if its attributes can't be read.
    nonisolated static func key(for url: URL, windowDuration: Double) -> String? {
        // `URL` caches resource values; read fresh ones so an edited file gets a new key.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let identity = "\(url.standardizedFileURL.path)|\(size)|\(modified)|\(windowDuration)|\(formatVersion)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func load(key: String) -> AudioLevels? {
        guard let data = try? Data(contentsOf: fileURL(for: key), options: .mappedIfSafe) else { return nil }
        return Self.decode(data)
    }

    func store(_ levels: AudioLevels, key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(levels).write(to: fileURL(for: key), options: .atomic)
        } catch {
            // A failed cache write only costs a re-analysis next time.
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appending(path: key + ".levels", directoryHint: .notDirectory)
    }

    // MARK: Binary format
    // magic u32 | version u32 | sampleRate i32 | reserved u32 | framesPerWindow i64 | frameCount i64 | windowCount i64
    // rmsDB [f32 × windowCount] | peakDB [f32 × windowCount]   (little endian)

    private nonisolated static let headerSize = 4 * 4 + 3 * 8

    nonisolated static func encode(_ levels: AudioLevels) -> Data {
        var data = Data()
        data.reserveCapacity(headerSize + levels.windowCount * 8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(magic)
        append(formatVersion)
        append(levels.sampleRate)
        append(UInt32(0))
        append(Int64(levels.framesPerWindow))
        append(Int64(levels.frameCount))
        append(Int64(levels.windowCount))
        levels.rmsDB.withUnsafeBytes { data.append(contentsOf: $0) }
        levels.peakDB.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    nonisolated static func decode(_ data: Data) -> AudioLevels? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { raw -> AudioLevels? in
            func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
                T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            guard read(UInt32.self, at: 0) == magic,
                  read(UInt32.self, at: 4) == formatVersion else { return nil }
            let sampleRate = read(Int32.self, at: 8)
            let framesPerWindow = Int(read(Int64.self, at: 16))
            let frameCount = Int(read(Int64.self, at: 24))
            let windowCount = Int(read(Int64.self, at: 32))
            let arrayBytes = windowCount * MemoryLayout<Float>.stride
            guard sampleRate > 0, framesPerWindow > 0, windowCount >= 0,
                  raw.count == headerSize + 2 * arrayBytes else { return nil }

            func floats(at offset: Int) -> [Float] {
                [Float](unsafeUninitializedCapacity: windowCount) { buffer, initialized in
                    let destination = UnsafeMutableRawBufferPointer(buffer)
                    destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + arrayBytes)]))
                    initialized = windowCount
                }
            }
            var levels = AudioLevels()
            levels.sampleRate = sampleRate
            levels.framesPerWindow = framesPerWindow
            levels.frameCount = frameCount
            levels.rmsDB = floats(at: headerSize)
            levels.peakDB = floats(at: headerSize + arrayBytes)
            levels.isComplete = true
            return levels
        }
    }
}
