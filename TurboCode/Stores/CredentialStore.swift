import Foundation
import LocalAuthentication
import Security

enum CredentialStore {
    private static let service = Bundle.main.bundleIdentifier ?? "art.granvalenti.turbocode"

    static func value(for account: String) -> String? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Credential availability is queried while constructing ChatStore
            // and rendering the model menu. Those background checks must never
            // summon a modal Keychain dialog and stall unrelated profiles such
            // as Codex. A credential that needs renewed authorization is
            // treated as unavailable until the user saves it again in Settings.
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            let status = SecItemDelete(lookup as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError(status: status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var insertion = lookup
            insertion[kSecValueData as String] = data
            let status = SecItemAdd(insertion as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialError(status: status) }
        } else if updateStatus != errSecSuccess {
            throw CredentialError(status: updateStatus)
        }
    }
}

private struct CredentialError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error (status)"
    }
}
