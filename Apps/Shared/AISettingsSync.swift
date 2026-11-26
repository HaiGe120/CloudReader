import CloudReaderCore
import Foundation
import Security

struct AIAPISecret: Codable {
    var value: String
    var origin: URL?
}

/// Store the endpoint and its origin-bound credential in one synchronizable item.
struct AISettingsSnapshot: Codable {
    var profile: AIProviderConfiguration
    var secret: AIAPISecret?
}

struct AISettingsKeychain {
    static let shared = AISettingsKeychain(account: "ai.sharedProfile.v1")
    let account: String

    private func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AIKeychainAccessGroup") as? String,
              !group.isEmpty else { throw CloudSyncError.authorization("The AI settings Keychain group is unavailable.") }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.haige120.cloudreader",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    func read() throws -> AISettingsSnapshot? {
        var query = try query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try JSONDecoder().decode(AISettingsSnapshot.self, from: data)
    }

    func write(_ snapshot: AISettingsSnapshot, onlyIfAbsent: Bool = false) throws {
        let query = try query()
        let data = try JSONEncoder().encode(snapshot)
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw failure(added) }
        if onlyIfAbsent { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> CloudSyncError {
        .authorization("iCloud Keychain could not access the AI settings (\(status)).")
    }
}
