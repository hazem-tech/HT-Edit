//
//  SpeechModelStore.swift
//  HT Edit
//

import Foundation
import Observation
import os
import Speech
import WhisperKit

/// The speech models the user can download, which ones are on this Mac, and
/// which one transcribes.
///
/// Whisper models are stored in Application Support (inside the app's
/// sandbox). A model counts as downloaded only once it has been fully
/// downloaded *and* loaded once, so transcription never needs the network.
@Observable
final class SpeechModelStore {
    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var whisperModels: [SpeechModel] = []
    private(set) var appleModels: [SpeechModel] = []
    private(set) var catalogState: CatalogState = .idle
    private(set) var downloadedIDs: Set<String> = []
    /// Download progress (0…1) of models being downloaded.
    private(set) var downloadProgress: [String: Double] = [:]
    /// Models downloaded and being loaded once (tokenizer, Core ML compile).
    private(set) var preparingIDs: Set<String> = []
    var errorMessage: String?

    var selectedModelID: String? {
        didSet { defaults.set(selectedModelID, forKey: Self.selectionKey) }
    }

    let directory: URL

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var downloadTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    private static let selectionKey = "speechModelID"
    private nonisolated static let readyMarker = ".htedit-ready"

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Speech Models", directoryHint: .isDirectory)
    }

    init(directory: URL = SpeechModelStore.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        self.selectedModelID = defaults.string(forKey: Self.selectionKey)
        let local = Self.downloadedWhisperVariants(in: directory)
        whisperModels = local.map { SpeechModelCatalog.whisperModel(variant: $0) }
        downloadedIDs = Set(whisperModels.map(\.id))
    }

    // MARK: Derived

    var allModels: [SpeechModel] { whisperModels + appleModels }

    /// The model used to transcribe: selected and downloaded.
    var selectedModel: SpeechModel? {
        allModels.first { $0.id == selectedModelID && downloadedIDs.contains($0.id) }
    }

    func isDownloaded(_ model: SpeechModel) -> Bool { downloadedIDs.contains(model.id) }
    func isDownloading(_ model: SpeechModel) -> Bool { downloadProgress[model.id] != nil }
    func isPreparing(_ model: SpeechModel) -> Bool { preparingIDs.contains(model.id) }

    func engine(for model: SpeechModel) -> any TranscriptionEngine {
        switch model.engine {
        case .whisperKit:
            WhisperKitEngine(modelFolder: whisperFolder(for: model.variant), tokenizerFolder: directory)
        case .apple:
            AppleSpeechEngine(locale: Locale(identifier: model.variant))
        }
    }

    // MARK: Catalog

    /// Fetches the full list (needs the network for Whisper models). Models
    /// already on disk stay listed when offline.
    func refresh() async {
        guard catalogState != .loading else { return }
        catalogState = .loading
        let directory = directory
        do {
            let remote = try await SpeechModelCatalog.whisperKitModels(downloadBase: directory)
            let remoteIDs = Set(remote.map(\.id))
            let localOnly = whisperModels.filter { downloadedIDs.contains($0.id) && !remoteIDs.contains($0.id) }
            whisperModels = remote + localOnly
            catalogState = .loaded
        } catch {
            Log.transcription.error("Model list failed: \(error.localizedDescription, privacy: .public)")
            catalogState = .failed(error.localizedDescription)
        }
        await refreshLocal()
    }

    /// Rescans what's on disk and which Apple models are installed (no network).
    func refreshLocal() async {
        let apple = await SpeechModelCatalog.appleModels()
        appleModels = apple.models
        let onDisk = Self.downloadedWhisperVariants(in: directory).map { SpeechModelCatalog.whisperModel(variant: $0) }
        let listed = Set(whisperModels.map(\.id))
        whisperModels += onDisk.filter { !listed.contains($0.id) }
        downloadedIDs = Set(onDisk.map(\.id)).union(apple.installedIDs)
    }

    // MARK: Download

    func download(_ model: SpeechModel) {
        let id = model.id
        guard downloadTasks[id] == nil, !downloadedIDs.contains(id) else { return }
        errorMessage = nil
        downloadProgress[id] = 0
        Log.transcription.notice("Download \(id, privacy: .public)")
        let token = UUID()
        let task = Task {
            defer {
                // A cancelled download that's restarted belongs to the new task now.
                if downloadTasks[id]?.token == token {
                    downloadTasks[id] = nil
                    downloadProgress[id] = nil
                    preparingIDs.remove(id)
                }
            }
            do {
                switch model.engine {
                case .whisperKit: try await downloadWhisper(model)
                case .apple: try await downloadApple(model)
                }
                try Task.checkCancellation()
                downloadedIDs.insert(id)
                if selectedModel == nil { selectedModelID = id }
                Log.transcription.notice("Downloaded \(id, privacy: .public)")
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                Log.transcription.error("Download \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = "\(model.displayName): \(error.localizedDescription)"
            }
        }
        downloadTasks[id] = (token, task)
    }

    func cancelDownload(_ model: SpeechModel) {
        downloadTasks.removeValue(forKey: model.id)?.task.cancel()
        downloadProgress[model.id] = nil
        preparingIDs.remove(model.id)
    }

    /// Removes a downloaded model. Apple models are released to the system,
    /// which deletes them later if no other app uses them.
    func delete(_ model: SpeechModel) {
        cancelDownload(model)
        switch model.engine {
        case .whisperKit:
            let folder = whisperFolder(for: model.variant)
            if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
                do {
                    try FileManager.default.removeItem(at: folder)
                } catch {
                    errorMessage = "\(model.displayName): \(error.localizedDescription)"
                    return
                }
            }
        case .apple:
            let locale = Locale(identifier: model.variant)
            Task { _ = await AssetInventory.release(reservedLocale: locale) }
        }
        downloadedIDs.remove(model.id)
        if selectedModelID == model.id { selectedModelID = nil }
    }

    private func downloadWhisper(_ model: SpeechModel) async throws {
        let id = model.id
        let folder = try await WhisperKit.download(
            variant: model.variant,
            downloadBase: directory,
            from: SpeechModelCatalog.whisperRepo
        ) { [weak self] progress in
            guard let self else { return }
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self.updateProgress(fraction, for: id)
            }
        }
        try Task.checkCancellation()
        preparingIDs.insert(id)
        try await WhisperKitEngine(modelFolder: folder, tokenizerFolder: directory).prepare()
        try Task.checkCancellation()
        try Data().write(to: folder.appending(path: Self.readyMarker))
    }

    private func downloadApple(_ model: SpeechModel) async throws {
        let id = model.id
        let transcriber = AppleSpeechEngine.makeTranscriber(locale: Locale(identifier: model.variant))
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return // Already installed.
        }
        let progress = request.progress
        let poll = Task {
            while !Task.isCancelled {
                updateProgress(progress.fractionCompleted, for: id)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
    }

    /// Ignores late progress reports for downloads that already ended.
    private func updateProgress(_ fraction: Double, for id: String) {
        guard downloadTasks[id] != nil else { return }
        downloadProgress[id] = fraction
    }

    // MARK: Disk layout

    /// WhisperKit's layout: `<base>/models/<repo>/<variant>`.
    func whisperFolder(for variant: String) -> URL {
        Self.whisperRepoFolder(in: directory).appending(path: variant, directoryHint: .isDirectory)
    }

    private nonisolated static func whisperRepoFolder(in directory: URL) -> URL {
        directory.appending(path: "models/\(SpeechModelCatalog.whisperRepo)", directoryHint: .isDirectory)
    }

    /// Variants whose download and first load both finished.
    nonisolated static func downloadedWhisperVariants(in directory: URL) -> [String] {
        let repo = whisperRepoFolder(in: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repo.path(percentEncoded: false))) ?? []
        return names.sorted().filter { name in
            FileManager.default.fileExists(atPath: repo.appending(path: name).appending(path: readyMarker).path(percentEncoded: false))
        }
    }
}
