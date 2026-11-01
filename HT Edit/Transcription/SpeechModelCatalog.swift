//
//  SpeechModelCatalog.swift
//  HT Edit
//

import Foundation
import Speech
import WhisperKit

nonisolated enum SpeechEngineKind: String, Sendable, Hashable {
    /// Whisper Core ML models from Hugging Face (`argmaxinc/whisperkit-coreml`).
    case whisperKit
    /// Apple's on-device SpeechTranscriber.
    case apple
}

/// A downloadable speech model that meets the app's rules: it runs on this Mac
/// without a network, transcribes Arabic, and gives timestamps.
nonisolated struct SpeechModel: Identifiable, Sendable, Hashable {
    /// Stable ID: `<engine>:<variant>`.
    var id: String { "\(engine.rawValue):\(variant)" }
    var engine: SpeechEngineKind
    /// Whisper model folder name, or a locale identifier for Apple.
    var variant: String
    var displayName: String
    var summary: String
    /// Approximate download size, if known.
    var sizeMB: Int?
    var isRecommended = false
}

/// Finds the models that fit the rules.
///
/// Sources checked (Nov 2026): WhisperKit's Core ML Whisper models are the
/// only open models with an Apple-silicon runtime that handle Arabic *and*
/// give word timestamps. Models that are more accurate on Arabic (Jais-ASR,
/// Cohere Transcribe Arabic, omniASR LLM) don't give timestamps; Moonshine
/// Arabic has no timestamps; Parakeet and SenseVoice don't support Arabic.
/// Apple's SpeechTranscriber is offered only when this Mac reports Arabic.
nonisolated enum SpeechModelCatalog {
    static let whisperRepo = "argmaxinc/whisperkit-coreml"

    // MARK: Rules

    /// Whisper variants that can transcribe Arabic. English-only variants
    /// (`*.en`) and Distil-Whisper (English-only) are excluded.
    static func arabicCapable(_ variants: [String]) -> [String] {
        variants.filter(isArabicCapable)
    }

    static func isArabicCapable(_ variant: String) -> Bool {
        let name = variant.lowercased()
        let isEnglishOnly = name.hasSuffix(".en") || name.contains(".en_") || name.contains(".en/")
        return !isEnglishOnly && !name.contains("distil")
    }

    // MARK: Whisper

    /// The Arabic-capable Whisper models this Mac supports, from Hugging Face.
    /// Models WhisperKit marks as not supported on this device are left out.
    static func whisperKitModels(downloadBase: URL) async throws -> [SpeechModel] {
        let available = try await WhisperKit.fetchAvailableModels(from: whisperRepo, downloadBase: downloadBase)
        let support = await WhisperKit.recommendedRemoteModels(from: whisperRepo, downloadBase: downloadBase)
        let disabled = Set(support.disabled)
        return arabicCapable(available)
            .filter { !disabled.contains($0) }
            .map { whisperModel(variant: $0, isRecommended: $0 == support.default) }
    }

    static func whisperModel(variant: String, isRecommended: Bool = false) -> SpeechModel {
        let info = describe(whisperVariant: variant)
        return SpeechModel(
            engine: .whisperKit,
            variant: variant,
            displayName: info.name,
            summary: info.summary,
            sizeMB: info.sizeMB,
            isRecommended: isRecommended
        )
    }

    /// Human-readable name, description and approximate size for a WhisperKit folder name
    /// such as `openai_whisper-large-v3-v20240930_626MB`.
    static func describe(whisperVariant variant: String) -> (name: String, summary: String, sizeMB: Int?) {
        var base = variant
        for prefix in ["openai_whisper-", "whisper-"] where base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
        }

        // Suffixes: `_turbo` (WhisperKit's faster build) and `_<n>MB` (compressed).
        var isTurboBuild = false
        var compressedMB: Int?
        var parts = base.split(separator: "_").map(String.init)
        while parts.count > 1, let last = parts.last {
            if last == "turbo" {
                isTurboBuild = true
            } else if last.hasSuffix("MB"), let size = Int(last.dropLast(2)) {
                compressedMB = size
            } else {
                break
            }
            parts.removeLast()
        }
        let size = parts.joined(separator: "_")

        let (name, summary): (String, String) = switch size {
        case "tiny": ("Whisper Tiny", "Fastest, lowest accuracy. Good for a quick test.")
        case "base": ("Whisper Base", "Very fast, low accuracy.")
        case "small": ("Whisper Small", "Fast, fair Arabic accuracy.")
        case "medium": ("Whisper Medium", "Slower, good Arabic accuracy.")
        case "large-v2": ("Whisper Large v2", "Slow, high accuracy.")
        case "large-v3": ("Whisper Large v3", "Slow, the most accurate Whisper for Arabic.")
        case "large-v3-v20240930": ("Whisper Large v3 Turbo", "Close to Large v3 accuracy, much faster.")
        default: ("Whisper \(size)", "Multilingual Whisper model.")
        }

        var extras: [String] = []
        if isTurboBuild { extras.append("Turbo build: faster on Apple silicon.") }
        if compressedMB != nil { extras.append("Compressed: smaller download, slightly lower accuracy.") }
        let fullName = name + (isTurboBuild ? " (Turbo build)" : "") + (compressedMB.map { " – \($0) MB" } ?? "")
        return (fullName, ([summary] + extras).joined(separator: " "), compressedMB ?? approximateSizesMB[variant])
    }

    /// Download sizes of the uncompressed variants, from Hugging Face (Nov 2026).
    private static let approximateSizesMB: [String: Int] = [
        "openai_whisper-tiny": 77,
        "openai_whisper-base": 147,
        "openai_whisper-small": 486,
        "openai_whisper-medium": 1_530,
        "openai_whisper-large-v2": 3_090,
        "openai_whisper-large-v2_turbo": 3_096,
        "openai_whisper-large-v3": 3_090,
        "openai_whisper-large-v3_turbo": 3_195,
        "openai_whisper-large-v3-v20240930": 1_620,
        "openai_whisper-large-v3-v20240930_turbo": 1_638,
    ]

    // MARK: Apple

    /// Apple on-device models for Arabic, if this Mac's SpeechTranscriber
    /// supports any Arabic locale, and which of them are installed.
    static func appleModels() async -> (models: [SpeechModel], installedIDs: Set<String>) {
        guard SpeechTranscriber.isAvailable else { return ([], []) }
        let supported = await SpeechTranscriber.supportedLocales.filter(isArabic)
        let installed = Set(await SpeechTranscriber.installedLocales.filter(isArabic).map(\.identifier))
        let models = supported.map { locale in
            let region = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            return SpeechModel(
                engine: .apple,
                variant: locale.identifier,
                displayName: "Apple Speech – \(region)",
                summary: "Built into macOS. Downloaded and updated by the system, and shared with other apps."
            )
        }
        return (models, Set(models.filter { installed.contains($0.variant) }.map(\.id)))
    }

    static func isArabic(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "ar"
    }
}
