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

    /// True once both an EFFECTIVE server URL and token are available — a Keychain value, a
    /// bundle-injected one, or a mix of both. Phase 3.5 (zero-touch): a bundle-only install counts as
    /// configured with no Keychain write ever happening.
    static var isConfigured: Bool { effectiveURL != nil && effectiveToken != nil }

    /// Remove both stored values.
    static func clear() {
        SecItemDelete(baseQuery(account: serverURLAccount) as CFDictionary)
        SecItemDelete(baseQuery(account: tokenAccount) as CFDictionary)
    }

    // MARK: - Bundle fallback (Phase 3.5: zero-touch)
    //
    // Mirrors Strand/Oura/OuraCredentials.swift's shape: a pure, dict-driven function that's directly
    // unit-testable (`effectiveValue`), plus a thin `Bundle.main`-reading wrapper (`effectiveURL`/
    // `effectiveToken`) that can't be redirected in a test but has no logic of its own to get wrong.

    /// Read `key` from an Info-dictionary-shaped map, trimmed; blank/absent both read as nil so a
    /// build without injected credentials cleanly falls through to "unconfigured" rather than saving a
    /// whitespace server URL.
    private static func bundleValue(_ key: String, from info: [String: Any]) -> String? {
        guard let s = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    /// Keychain-wins-over-bundle precedence, as a pure function of its inputs — the seam that makes
    /// the precedence rule unit-testable without a real Info.plist (see `CloudSyncSettingsTests`).
    static func effectiveValue(keychain: String?, infoKey: String, info: [String: Any]) -> String? {
        keychain ?? bundleValue(infoKey, from: info)
    }

    /// The noop-cloud server URL a manual Save in the Data Sources card wrote to the Keychain, or the
    /// build-injected `CLOUDSYNC_URL` (from the untracked `OuraSecrets.xcconfig` → project.yml →
    /// Info.plist chain — see `OuraCredentials.swift`'s doc comment for the identical pattern) when no
    /// Keychain override exists. nil disables the whole cloud-sync lane.
    static var effectiveURL: String? {
        effectiveValue(keychain: serverURL, infoKey: "CLOUDSYNC_URL", info: Bundle.main.infoDictionary ?? [:])
    }

    /// The read-write token, same Keychain-wins-over-bundle precedence as `effectiveURL`.
    static var effectiveToken: String? {
        effectiveValue(keychain: token, infoKey: "CLOUDSYNC_TOKEN", info: Bundle.main.infoDictionary ?? [:])
    }

    /// True when the lane is configured ENTIRELY from the bundle-injected build credentials, with no
    /// Keychain override at all. Drives the Data Sources card: bundle-configured shows a one-line
    /// "Configured from build" note instead of the URL/token fields; any Keychain value (even a
    /// partial one) falls through to the manual fields so a user's own in-progress edit is never
    /// silently hidden behind the collapsed summary.
    static var isBundleConfigured: Bool {
        guard serverURL == nil, token == nil else { return false }
        let info = Bundle.main.infoDictionary ?? [:]
        return bundleValue("CLOUDSYNC_URL", from: info) != nil && bundleValue("CLOUDSYNC_TOKEN", from: info) != nil
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
