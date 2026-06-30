import Foundation
import Security

/// Minimal Keychain wrapper for storing API secrets.
///
/// Secrets never touch UserDefaults or disk in plain text — they live in the
/// login keychain keyed by `service`.
enum Keychain {
    private static let service = "com.winday.notetaker.secrets"

    static func set(_ value: String?, for key: String) {
        // Always remove first so we cleanly overwrite or delete.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)

        guard let value, let data = value.data(using: .utf8), !value.isEmpty else {
            return
        }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}
