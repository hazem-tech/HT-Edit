//
//  GeminiClient.swift
//  HT Edit
//

import Foundation
import os

nonisolated enum GeminiError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    /// Quota or rate limit hit; `retryAfter` is in seconds when Gemini says.
    case rateLimited(retryAfter: Double?)
    case unavailable
    case server(status: Int, message: String)
    case emptyResponse(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a Gemini API key in the transcript settings (gear button)."
        case .invalidAPIKey:
            "Gemini rejected the API key. Check it in the transcript settings."
        case .rateLimited(let retryAfter):
            "Gemini's quota for this quality level is used up" + (retryAfter.map { " (try again in \(Self.duration($0)))" } ?? "")
                + ". Try a lower quality level, or wait."
        case .unavailable:
            "Gemini is busy right now. Try again in a minute."
        case .server(let status, let message):
            "Gemini error \(status): \(message)"
        case .emptyResponse(let reason):
            "Gemini returned no text (\(reason))."
        case .invalidResponse:
            "Gemini returned a response the app couldn't read."
        }
    }

    /// Whether the next request would fail the same way (stop instead of trying other clips).
    var stopsBatch: Bool {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .rateLimited, .unavailable: true
        default: false
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        return "\(total / 3600) h \((total % 3600) / 60) min"
    }
}

/// Minimal REST client for the Gemini API (`generateContent` only).
///
/// Every method makes exactly one request, except a single automatic retry when
/// Gemini asks to wait less than `maximumAutomaticWait` (or is briefly overloaded).
nonisolated struct GeminiClient: Sendable {
    var apiKey: String
    var session: URLSession = .shared

    static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/")!
    static let maximumAutomaticWait = 30.0

    // MARK: Speech to text

    /// Transcribes `audio` with word timestamps. Times are seconds from the start of `audio`.
    @concurrent
    func transcribe(audio: Data, mimeType: String) async throws -> [TranscriptWord] {
        let body = Self.transcriptionBody(audio: audio, mimeType: mimeType)
        let response = try await send(model: TranscriptionTier.speechModel, body: body, timeout: 600)
        return try Self.words(from: response)
    }

    static func transcriptionBody(audio: Data, mimeType: String) -> Data {
        let body: [String: Any] = [
            "contents": [["parts": [["inlineData": ["mimeType": mimeType, "data": audio.base64EncodedString()]]]]],
            "generationConfig": ["audioTranscriptionConfig": ["wordTimestamp": true]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Reads `candidates[].content.parts[].audioTranscription.words[]`.
    static func words(from response: Data) throws -> [TranscriptWord] {
        let root = try json(response)
        guard let candidates = root["candidates"] as? [[String: Any]] else {
            throw emptyResponseError(root)
        }
        var words: [TranscriptWord] = []
        for candidate in candidates {
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                let entries = (part["audioTranscription"] as? [String: Any])?["words"] as? [[String: Any]] ?? []
                for entry in entries {
                    guard let text = entry["word"] as? String,
                          let start = seconds(entry["startOffset"]) else { continue }
                    let end = seconds(entry["endOffset"]) ?? start
                    words.append(TranscriptWord(text: text, start: start, end: max(start, end)))
                }
            }
        }
        return words.sorted { $0.start < $1.start }
    }

    /// Parses a protobuf duration (`"1.250s"`), or a plain number of seconds.
    static func seconds(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasSuffix("s") { text.removeLast() }
        return Double(text)
    }

    // MARK: Text generation

    /// One `generateContent` call. With `schemaJSON` (an OpenAPI schema as JSON
    /// text), the reply is JSON matching it.
    @concurrent
    func generate(model: String, thinkingLevel: String, system: String, prompt: String, schemaJSON: String? = nil) async throws -> String {
        do {
            let body = Self.textBody(thinkingLevel: thinkingLevel, system: system, prompt: prompt, schemaJSON: schemaJSON)
            return try Self.text(from: try await send(model: model, body: body, timeout: 300))
        } catch GeminiError.server(400, let message) where message.localizedCaseInsensitiveContains("thinking") {
            // A newer model behind the alias may not accept this thinking level: use its default.
            let body = Self.textBody(thinkingLevel: nil, system: system, prompt: prompt, schemaJSON: schemaJSON)
            return try Self.text(from: try await send(model: model, body: body, timeout: 300))
        }
    }

    static func textBody(thinkingLevel: String?, system: String, prompt: String, schemaJSON: String?) -> Data {
        var config: [String: Any] = [:]
        if let thinkingLevel { config["thinkingConfig"] = ["thinkingLevel": thinkingLevel] }
        if let schemaJSON, let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) {
            config["responseMimeType"] = "application/json"
            config["responseSchema"] = schema
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": config,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Concatenates the text parts of the first candidate (thought parts skipped).
    static func text(from response: Data) throws -> String {
        let root = try json(response)
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else {
            throw emptyResponseError(root)
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else {
            throw GeminiError.emptyResponse((candidate["finishReason"] as? String) ?? "no text")
        }
        return text
    }

    // MARK: Transport

    private func send(model: String, body: Data, timeout: TimeInterval) async throws -> Data {
        guard !apiKey.isEmpty else { throw GeminiError.missingAPIKey }
        var request = URLRequest(url: Self.baseURL.appending(path: "\(model):generateContent"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }

            let error = Self.error(status: status, body: data)
            if attempt == 1, let wait = Self.automaticRetryDelay(for: error) {
                Log.transcription.notice("\(model, privacy: .public): HTTP \(status), retrying in \(wait) s")
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            Log.transcription.error("\(model, privacy: .public): HTTP \(status)")
            throw error
        }
    }

    /// Short waits are retried once automatically; long ones are reported.
    static func automaticRetryDelay(for error: GeminiError) -> Double? {
        switch error {
        case .rateLimited(let retryAfter?) where retryAfter <= maximumAutomaticWait: retryAfter + 0.5
        case .unavailable: 3
        default: nil
        }
    }

    /// Maps an error response (`{"error": {"code", "message", "status", "details"}}`).
    static func error(status: Int, body: Data) -> GeminiError {
        let object = (try? json(body))?["error"] as? [String: Any] ?? [:]
        let message = (object["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let reason = object["status"] as? String ?? ""
        let details = object["details"] as? [[String: Any]] ?? []

        if status == 429 || reason == "RESOURCE_EXHAUSTED" {
            let delay = details.lazy.compactMap { seconds($0["retryDelay"]) }.first
            return .rateLimited(retryAfter: delay)
        }
        if status == 503 || reason == "UNAVAILABLE" { return .unavailable }
        let mentionsKey = message.localizedCaseInsensitiveContains("API key")
            || details.contains { ($0["reason"] as? String) == "API_KEY_INVALID" }
        if status == 401 || status == 403 || (status == 400 && mentionsKey) { return .invalidAPIKey }
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
        return .server(status: status, message: firstLine)
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }
        return object
    }

    private static func emptyResponseError(_ root: [String: Any]) -> GeminiError {
        let feedback = root["promptFeedback"] as? [String: Any]
        return .emptyResponse((feedback?["blockReason"] as? String) ?? "no candidates")
    }
}
