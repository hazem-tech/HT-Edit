//
//  APIKeyStore.swift
//  HT Edit
//

import Foundation
import Security

/// The Gemini API key: the user's own key (stored in the Keychain) if set,
/// otherwise the default key bundled from `GeminiAPIKey.txt`.
///
/// `GeminiAPIKey.txt` is git-ignored: put a key in it next to this file to
/// ship a default. Without it the app asks for a key in the transcript settings.
nonisolated enum APIKeyStore {
    private static let service = "ht.edit.gemini"
    private static let account = "apiKey"

    /// The key bundled with the app, if any.
    static let defaultKey: String? = {
        guard let url = Bundle.main.url(forResource: "GeminiAPIKey", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }()

    /// The user's own key from the Keychain, if they entered one.
    static func loadCustomKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// Stores the user's key; an empty key removes it (the default is used again).
    @discardableResult
    static func saveCustomKey(_ key: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        var item = baseQuery
        item[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
