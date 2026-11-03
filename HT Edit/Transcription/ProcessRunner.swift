//
//  ProcessRunner.swift
//  HT Edit
//

import Foundation

nonisolated struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

nonisolated enum ProcessRunnerError: Error, Equatable {
    case timedOut
}

/// Runs a command-line tool to completion off the main actor.
///
/// - Output goes to temporary files rather than pipes, so a chatty tool can
///   never block on a full pipe buffer.
/// - Cancelling the calling task, or passing `timeout`, terminates the process.
nonisolated enum ProcessRunner {
    @concurrent
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration
    ) async throws -> ProcessOutput {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "process-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdoutURL = scratch.appending(path: "stdout")
        let stderrURL = scratch.appending(path: "stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let (exits, exit) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            exit.yield(finished.terminationStatus)
            exit.finish()
        }
        try Task.checkCancellation()
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // First of: the process exits, the timeout passes, or the task is cancelled.
        let status: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await status in exits { return status }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let status else {
            try Task.checkCancellation()
            throw ProcessRunnerError.timedOut
        }
        return ProcessOutput(
            status: status,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }
}
