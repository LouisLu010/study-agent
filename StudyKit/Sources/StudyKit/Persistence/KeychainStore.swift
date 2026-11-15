import Foundation
import Security

/// 把每个服务商的 API Key 存在本机钥匙串里，不跨设备同步（见 docs/adr/0001）。
public enum KeychainStore {
    private static let service = "com.louislu.studyagent.apikey"

    public static func apiKey(for providerID: UUID) -> String? {
        var query = baseQuery(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 保存 API Key。传入空字符串时删除。
    public static func setAPIKey(_ key: String, for providerID: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey(for: providerID)
            return
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(for: providerID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    public static func deleteAPIKey(for providerID: UUID) {
        SecItemDelete(baseQuery(for: providerID) as CFDictionary)
    }

    private static func baseQuery(for providerID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
        ]
    }
}
