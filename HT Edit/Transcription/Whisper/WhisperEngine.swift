//
//  WhisperEngine.swift
//  HT Edit
//
//  Speech to text on this Mac with Whisper large-v3-turbo (faster-whisper).
//  Nothing leaves the Mac and nothing is charged. Setup puts a Python
//  environment and the model in Application Support (see `whisper_setup.sh`).
//

import Foundation
import os

nonisolated enum WhisperError: LocalizedError, Equatable, FatalTranscriptionError {
    case notSetUp
    case serverStopped(String)
    case failed(String)

    var isFatal: Bool {
        switch self {
        case .notSetUp, .serverStopped: true
        case .failed: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSetUp: "Whisper isn't set up yet. Press Set Up Whisper."
        case .serverStopped(let reason): "Whisper stopped: \(reason)"
        case .failed(let reason): "Whisper failed: \(reason)"
        }
    }
}

/// Where Whisper lives on disk.
nonisolated struct WhisperInstallation: Sendable {
    static let modelName = "large-v3-turbo"

    var root: URL

    static let standard = WhisperInstallation(
        root: URL.applicationSupportDirectory.appending(path: "HT Edit/Whisper", directoryHint: .isDirectory)
    )

    var python: URL { root.appending(path: "venv/bin/python", directoryHint: .notDirectory) }
    var model: URL { root.appending(path: "models/\(Self.modelName)", directoryHint: .isDirectory) }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: model.appending(path: "model.bin").path)
    }

    /// The helper scripts shipped inside the app.
    static func bundledScript(_ name: String) -> URL? {
        let parts = name.split(separator: ".")
        return Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1]))
    }

    /// Runs `whisper_setup.sh`: creates the environment and downloads the model.
    /// Takes minutes the first time (about 1.7 GB); does nothing once everything is there.
    func setUp() async throws {
        guard let script = Self.bundledScript("whisper_setup.sh") else {
            throw WhisperError.failed("whisper_setup.sh is missing from the app.")
        }
        let output = try await ProcessRunner.run(
            URL(filePath: "/bin/zsh"), arguments: [script.path, root.path], timeout: .seconds(3600)
        )
        guard output.status == 0 else {
            let lines = (output.stdout + "\n" + output.stderr).split(separator: "\n").suffix(4).joined(separator: "\n")
            throw WhisperError.failed(lines.isEmpty ? "setup exited with status \(output.status)" : lines)
        }
    }
}

/// Transcribes speech windows with a long-running Whisper helper, so the model
/// is loaded once per app session instead of once per window.
actor WhisperEngine: TranscriptionEngine {
    private let installation: WhisperInstallation
    private var server: WhisperServer?

    init(installation: WhisperInstallation = .standard) {
        self.installation = installation
    }

    func checkStatus() async -> EngineStatus {
        guard WhisperInstallation.bundledScript("whisper_server.py") != nil else {
            return .failed("whisper_server.py is missing from the app.")
        }
        return installation.isInstalled ? .ready([]) : .needsSetup
    }

    func plan(_ url: URL, duration: Double) async throws -> [Range<Double>]? {
        let levels = try await MonoAudio.levels(url)
        return SpeechWindows.plan(levels: levels, duration: duration)
    }

    func transcribe(audio: URL, duration: Double, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        guard installation.isInstalled, let script = WhisperInstallation.bundledScript("whisper_server.py") else {
            throw WhisperError.notSetUp
        }
        let wav = audio.deletingPathExtension().appendingPathExtension("wav")
        try await MonoAudio.writeWAV(from: audio, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let server = self.server ?? WhisperServer(python: installation.python, script: script, model: installation.model)
        self.server = server
        do {
            return try await server.transcribe(wav: wav, language: options.language, prompt: options.context)
        } catch let error as WhisperError where error.isFatal {
            self.server = nil   // start a fresh helper next time
            throw error
        }
    }
}

/// The `whisper_server.py` process: one JSON request per line in, one reply per line out.
actor WhisperServer {
    private let python: URL
    private let script: URL
    private let model: URL

    private var process: Process?
    private var input: FileHandle?
    private var stderrURL: URL?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, any Error>] = []
    private var pending: [Int: CheckedContinuation<[TranscriptSegment], any Error>] = [:]
    private var nextID = 1

    init(python: URL, script: URL, model: URL) {
        self.python = python
        self.script = script
        self.model = model
    }

    func transcribe(wav: URL, language: String?, prompt: String) async throws -> [TranscriptSegment] {
        try await start()
        let id = nextID
        nextID += 1
        var request: [String: String] = ["wav": wav.path]
        if let language { request["language"] = language }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { request["prompt"] = prompt }
        let line = try Self.encode(id: id, request) + "\n"

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try input?.write(contentsOf: Data(line.utf8))
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: WhisperError.serverStopped(error.localizedDescription))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    deinit {
        process?.terminate()
    }

    // MARK: Process

    private func start() async throws {
        if ready, process?.isRunning == true { return }
        if process == nil { try launch() }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    private func launch() throws {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-u", script.path, model.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe()
        let stderrURL = FileManager.default.temporaryDirectory.appending(path: "whisper-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.stopped(status: status) }
        }
        try process.run()
        Log.transcription.notice("Whisper helper started (pid \(process.processIdentifier))")
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.stderrURL = stderrURL

        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    await self?.received(line)
                }
            } catch {}
        }
    }

    private func received(_ line: String) {
        guard let data = line.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            Log.transcription.error("Whisper helper said: \(line, privacy: .public)")
            return
        }
        if reply.ready == true {
            ready = true
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0.resume() }
            return
        }
        guard let id = reply.id, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = reply.error {
            continuation.resume(throwing: WhisperError.failed(error))
        } else {
            continuation.resume(returning: reply.segments ?? [])
        }
    }

    private func stopped(status: Int32) {
        let tail = stderrURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.split(separator: "\n").suffix(3).joined(separator: " ") } ?? ""
        let reason = tail.isEmpty ? "exit status \(status)" : String(tail.prefix(400))
        Log.transcription.error("Whisper helper exited: \(reason, privacy: .public)")
        let error = WhisperError.serverStopped(reason)
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters = []
        pending.values.forEach { $0.resume(throwing: error) }
        pending = [:]
        process = nil
        input = nil
        ready = false
        if let stderrURL { try? FileManager.default.removeItem(at: stderrURL) }
        stderrURL = nil
    }

    private func cancel(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // MARK: Wire format

    private struct Reply: Decodable {
        var ready: Bool?
        var id: Int?
        var segments: [TranscriptSegment]?
        var error: String?
    }

    private static func encode(id: Int, _ fields: [String: String]) throws -> String {
        struct Request: Encodable {
            var id: Int
            var wav: String
            var language: String?
            var prompt: String?
        }
        let request = Request(id: id, wav: fields["wav"] ?? "", language: fields["language"], prompt: fields["prompt"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(request), as: UTF8.self)
    }
}
