/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See Licenses/native/Apple-GenericKeychain.txt and THIRD_PARTY_NOTICES.md
 for the original GenericKeychain sample's licensing information.

 Modified for consolinotes: device-only, authenticated saved unlock passwords.
 */

import Foundation
import LocalAuthentication
import Security

/// Injection boundary for tests. Tests replace every operation; they never use a user's Keychain.
struct KeychainOperations {
    var copy: ([String: Any]) -> (OSStatus, AnyObject?)
    var add: ([String: Any]) -> OSStatus
    var update: ([String: Any], [String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static let system = KeychainOperations(
        copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

struct KeychainPasswordItem {
    enum KeychainError: Error {
        case noPassword
        case unexpectedPasswordData
        case protectionUnavailable
        case verificationFailed
        case emptyPassword
        case incorrectCurrentPassword
        case unhandledError(status: OSStatus)
    }

    let service: String
    let account: String
    var operations: KeychainOperations = .system

    /// SecItemCopyMatching authenticates access to the value. A separate successful
    /// LAContext.evaluatePolicy call is not a substitute for an item access control.
    func readPassword(context: LAContext) throws -> String {
        var query = keychainQuery(context: context)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = operations.copy(query)
        try Self.check(status)
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedPasswordData
        }
        return password
    }

    /// Updates authenticate the existing item before modifying it. In particular,
    /// cancellation, entitlement errors and locked Keychain errors never become adds.
    func savePassword(_ password: String, currentPassword: String? = nil, context: LAContext) throws {
        guard !password.isEmpty else { throw KeychainError.emptyPassword }
        let data = Data(password.utf8)
        do {
            let existing = try readPassword(context: context)
            if let currentPassword = currentPassword, !currentPassword.utf8.elementsEqual(existing.utf8) {
                throw KeychainError.incorrectCurrentPassword
            }
        } catch KeychainError.noPassword {
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil
            ) else { throw KeychainError.protectionUnavailable }

            var query = keychainQuery(context: context)
            query[kSecAttrAccessControl as String] = access
            query[kSecValueData as String] = data
            try Self.check(operations.add(query))
            return
        }

        try Self.check(operations.update(keychainQuery(context: context), [kSecValueData as String: data]))
    }

    /// This is the only operation allowed against the app's old file-based item.
    /// It is called only after an explicit save and authenticated protected read-back.
    func deleteLegacyItem() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrSynchronizable as String: false
        ]
        let status = operations.delete(query)
        if status != errSecItemNotFound { try Self.check(status) }
    }

    private func keychainQuery(context: LAContext) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context
        ]
    }

    private static func check(_ status: OSStatus) throws {
        if status == errSecItemNotFound { throw KeychainError.noPassword }
        guard status == errSecSuccess else { throw KeychainError.unhandledError(status: status) }
    }
}
