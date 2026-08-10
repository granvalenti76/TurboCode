import Foundation
import LocalAuthentication
import Security

enum CredentialStore {
    nonisolated private static let service = "art.granvalenti.turbocode"

    /// Reads a secret without allowing the Keychain to present UI.
    ///
    /// Request-scoped authentication must fail cleanly when macOS would need
    /// user interaction; a model request can then surface the provider error
    /// instead of blocking an unrelated app flow with a modal prompt.
    nonisolated static func value(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Checks whether a credential is available without loading its value.
    ///
    /// UI and routing code only need this presence signal. Keeping the secret
    /// out of those paths avoids repeated Keychain reads during view updates
    /// and session construction.
    nonisolated static func contains(account: String) -> Bool {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    nonisolated private static func baseQuery(for account: String) -> [String: Any] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Credential availability is queried while rendering model menus.
            // These checks must never summon a modal Keychain dialog or stall
            // unrelated profiles such as Codex.
            kSecUseAuthenticationContext as String: authenticationContext,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
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
