import Foundation
import Security

/// Small wrapper over generic-password Keychain items.
public struct KeychainStore: Sendable {
    /// The app group the app and the share extension both belong to. iOS
    /// accepts an app group as a Keychain access group, so items stored here
    /// are readable by both without a team-prefixed keychain-access-groups
    /// entitlement. Both targets' .entitlements files list it.
    public static let sharedAccessGroup = "group.com.matthuber.photoframe"

    public let service: String
    /// nil = the process's default access group (what the app used before
    /// the share extension existed).
    public let accessGroup: String?

    public init(service: String = "com.matthuber.photoframe", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Moves an item saved before the shared access group existed into it.
    /// A query without an access group searches every group the process may
    /// read, so it finds the old item and reports which group it is in; the
    /// value is written to `accessGroup` first and only then removed from the
    /// old group, so a failure never loses it.
    public func migrateFromDefaultGroup(account: String) {
        guard let accessGroup, string(for: account) == nil else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8),
              let oldGroup = item[kSecAttrAccessGroup as String] as? String, oldGroup != accessGroup,
              (try? set(value, for: account)) != nil else { return }
        query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: oldGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Stores `value`, or deletes the item when it is nil.
    public func set(_ value: String?, for account: String) throws {
        let query = baseQuery(account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Where the server URL and upload password live. Both are in the Keychain,
/// never in UserDefaults, in the access group the share extension can read.
public struct CredentialStore: Sendable {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore(accessGroup: KeychainStore.sharedAccessGroup)) {
        self.keychain = keychain
    }

    /// The app calls this at launch so a sign-in saved by an older build
    /// (default access group, invisible to the extension) keeps working and
    /// becomes visible to the share extension.
    public func migrateLegacyItems() {
        keychain.migrateFromDefaultGroup(account: "serverURL")
        keychain.migrateFromDefaultGroup(account: "password")
    }

    public var serverText: String? { keychain.string(for: "serverURL") }

    public func load() -> ServerCredentials? {
        guard let server = keychain.string(for: "serverURL").flatMap(ServerCredentials.parseServer),
              let password = keychain.string(for: "password"), !password.isEmpty else { return nil }
        return ServerCredentials(serverURL: server, password: password)
    }

    public func save(_ credentials: ServerCredentials) throws {
        try keychain.set(credentials.serverURL.absoluteString, for: "serverURL")
        try keychain.set(credentials.password, for: "password")
    }

    /// Signing out forgets the password but keeps the server address.
    public func forgetPassword() throws {
        try keychain.set(nil, for: "password")
    }
}
