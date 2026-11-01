//
//  Log.swift
//  HT Edit
//

import os

/// Unified logging and signposts. View in Console.app (subsystem `ht.edit`)
/// or Instruments (os_signpost) to see where time goes during an import.
nonisolated enum Log {
    static let subsystem = "ht.edit"

    static let importing = Logger(subsystem: subsystem, category: "import")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")

    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
