import Foundation
import Security
import os

/// Stores the raw license token string in the login Keychain instead of
/// `UserDefaults` — plain preference-file storage for something that gates
/// paid functionality was weaker than it needed to be, and the license
/// format rewrite already requires every user to re-enter a key, so there's
/// no migration cost to also moving where it's kept.
enum KeychainLicenseStore {
    private static let service = "lonewolf.JgDo.license"
    private static let account = "license-token"

    static func load() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            SecItemCopyMatching(query as CFDictionary, ptr)
        }
        query.removeValue(forKey: kSecReturnData as String)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                AppLog.license.error("Keychain read failed with status \(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Upserts the token: tries an update first (the common case after the
    /// first activation), adds a new item if none exists yet.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                AppLog.license.error("Keychain add failed with status \(addStatus, privacy: .public)")
                return false
            }
            return true
        }
        guard updateStatus == errSecSuccess else {
            AppLog.license.error("Keychain update failed with status \(updateStatus, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AppLog.license.error("Keychain delete failed with status \(status, privacy: .public)")
            return false
        }
        return true
    }
}
