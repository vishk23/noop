// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation
import Security

/// Keychain Services wrapper for the noop-cloud server URL + read-write token. One service, two
/// generic-password accounts, plain UTF-8 string values — neither ever lands in UserDefaults, a
/// plist, or on disk in the clear. Mirrors OuraTokenStore's get/set/delete shape; value encoding
/// (trim, empty-means-clear) mirrors AICoach's AIKeyStore.
enum CloudSyncSettings {
    private static let service = "com.noop.cloudsync"
    private static let serverURLAccount = "server-url"
    private static let tokenAccount = "rw-token"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The noop-cloud server base URL (e.g. "https://vk-noop-cloud.fly.dev"), or nil if unset.
    static var serverURL: String? {
        get { load(account: serverURLAccount) }
        set { save(newValue, account: serverURLAccount) }
    }

    /// The read-write bearer token for the noop-cloud server, or nil if unset.
    static var token: String? {
        get { load(account: tokenAccount) }
        set { save(newValue, account: tokenAccount) }
    }

    /// True once both a server URL and a token are stored.
    static var isConfigured: Bool { serverURL != nil && token != nil }

    /// Remove both stored values.
    static func clear() {
        SecItemDelete(baseQuery(account: serverURLAccount) as CFDictionary)
        SecItemDelete(baseQuery(account: tokenAccount) as CFDictionary)
    }

    /// Store (or replace) `value` for `account`. Empty/whitespace input clears the item instead
    /// (so an accidental blank Save can't leave a dead-but-present Keychain entry).
    @discardableResult
    private static func save(_ value: String?, account: String) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(account: account)

        // Delete any existing item first so we always insert a single, fresh value (or none).
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        guard let data = trimmed.data(using: .utf8) else { return false }

        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Load the stored value for `account`, or nil if none.
    private static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }
}
#endif // CLOUD_SYNC
