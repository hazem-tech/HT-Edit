//
//  ExecutableLocator.swift
//  HT Edit
//

import Foundation

/// Finds command-line tools the user installed (`agy`, `uv`).
///
/// Apps launched from the Finder don't get the shell's `PATH`, so this checks
/// the usual install folders first, then asks the login shell.
nonisolated enum ExecutableLocator {
    /// Where installers put tools: `~/.local/bin` (agy, uv), `~/.cargo/bin` (older uv), Homebrew.
    static let candidateDirectories = [
        URL.homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
        URL.homeDirectory.appending(path: ".cargo/bin", directoryHint: .isDirectory),
        URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
        URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
    ]

    static func locate(_ name: String) async -> URL? {
        for directory in candidateDirectories {
            let candidate = directory.appending(path: name, directoryHint: .notDirectory)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        guard let output = try? await ProcessRunner.run(
            URL(filePath: "/bin/zsh"), arguments: ["-lc", "command -v \(name)"], timeout: .seconds(5)
        ), output.status == 0,
              let path = output.stdout.split(separator: "\n").last.map(String.init),
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// The app's environment with `tool`'s folder and the usual tool folders on `PATH`.
    static func environment(for tool: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = [tool.deletingLastPathComponent().path] + candidateDirectories.map(\.path)
        let existing = environment["PATH"].map { [$0] } ?? ["/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = (extra + existing).joined(separator: ":")
        return environment
    }
}
