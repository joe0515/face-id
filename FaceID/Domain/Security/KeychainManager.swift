//
//  KeychainManager.swift
//  Face ID
//
//  Thin, password-agnostic wrapper around Keychain Services — save/read/delete/exists by account, plus a Touch-ID access control helper.
//

import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessControlFailed(String)
    case authenticationFailed
    /// The item's ACL dialog could not be presented (or was dismissed) — usually means
    /// this build hasn't been authorized yet, or the screen is locked and there is no
    /// UI session to host it.
    case interactionNotAllowed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "钥匙串中没有找到该项。"
        case .unexpectedData:
            return "钥匙串项格式异常。"
        case .accessControlFailed(let msg):
            return "无法创建钥匙串访问控制：\(msg)"
        case .authenticationFailed:
            return "验证被取消或失败。"
        case .interactionNotAllowed:
            return "钥匙串需要授权：请在系统弹窗里选择「始终允许」。"
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "钥匙串错误：\(message)"
        }
    }

    /// True when the failure means "this build holds no entitlement a gated item
    /// needs" — a build signed without a team. It has a fallback, so callers
    /// distinguish it from a real failure rather than surfacing it.
    ///
    /// Measured, not assumed: `SecItemAdd` with `kSecAttrAccessControl` returns
    /// `errSecMissingEntitlement` (-34018) for an unsigned build, an ad-hoc one, and
    /// one carrying every entitlement we can sign ad-hoc with. Adding
    /// `keychain-access-groups` to an ad-hoc signature does not help either — AMFI
    /// kills the process at launch (exit 137), because that entitlement requires a
    /// real Apple signing identity.
    var isMissingEntitlement: Bool {
        if case .osStatus(let status) = self { return status == errSecMissingEntitlement }
        return false
    }
}

enum KeychainManager {
    nonisolated static let service = "com.joeqiao.faceid"

    /// Attributes-only existence check — never prompts, even for access-controlled items.
    nonisolated static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecItemNotFound
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.authenticationFailed
        case errSecInteractionNotAllowed:
            // -25308: the ACL dialog couldn't be shown (locked screen, no UI session) or
            // the user dismissed it.
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Replaces any existing item. Stored device-local (`WhenUnlockedThisDeviceOnly`),
    /// with no access control — the only remaining keychain users are legacy items
    /// read by the one-time 1.2 → 1.3 migration, never new secrets (see
    /// `DeviceKeyStore` for why new secrets don't go in the keychain at all).
    nonisolated static func save(account: String, data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    nonisolated static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}
