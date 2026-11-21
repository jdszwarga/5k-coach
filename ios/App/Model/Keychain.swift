import Foundation
import Security

/// The Claude API key, kept in the Keychain (not in the saved state file).
enum Keychain {
    private static let service = "com.jdszwarga.fivekcoach"
    private static let account = "claude-api-key"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String) {
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
