/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See Licenses/native/Apple-GenericKeychain.txt and THIRD_PARTY_NOTICES.md
 for the original GenericKeychain sample's licensing information.
 */

import Foundation
import LocalAuthentication
import Security

struct KeychainConfiguration {
    static let serviceName = "io.github.sebiimaks.consolinotes.saved-unlock.v2"
    private static let oldOwnServiceName = "consolinotes"
    static let masterPasswordAccount = "Master Password"

    /// Legacy values are deliberately not read here, including when the protected
    /// item is absent or access is denied. Users can always enter a note's password.
    static func readMasterPassword(operations: KeychainOperations = .system) throws -> String {
        let context = authenticationContext(reason: "Unlock your encrypted notes with the saved password")
        defer { context.invalidate() }
        return try KeychainPasswordItem(service: serviceName, account: masterPasswordAccount, operations: operations)
            .readPassword(context: context)
    }

    enum SaveResult {
        case saved
        case savedLegacyCleanupFailed
    }

    /// Explicit re-entry migrates the convenience password, never a note's encryption.
    /// The FSNotes application's saved password is never read, copied or deleted.
    static func saveMasterPassword(_ password: String, currentPassword: String? = nil,
                                   operations: KeychainOperations = .system) throws -> SaveResult {
        let context = authenticationContext(reason: "Protect your saved unlock password on this Mac")
        defer { context.invalidate() }
        let item = KeychainPasswordItem(service: serviceName, account: masterPasswordAccount, operations: operations)
        try item.savePassword(password, currentPassword: currentPassword, context: context)
        guard try item.readPassword(context: context).utf8.elementsEqual(password.utf8) else {
            throw KeychainPasswordItem.KeychainError.verificationFailed
        }

        do {
            try KeychainPasswordItem(service: oldOwnServiceName, account: masterPasswordAccount, operations: operations)
                .deleteLegacyItem()
        } catch {
            // The protected value is verified. Report the incomplete cleanup without
            // claiming the successful save failed or deleting another application's item.
            return .savedLegacyCleanupFailed
        }
        return .saved
    }

    static func isAuthenticationCancelled(_ error: Error) -> Bool {
        if case KeychainPasswordItem.KeychainError.unhandledError(let status) = error {
            return status == errSecUserCanceled
        }
        return false
    }

    static func isMissingEntitlement(_ error: Error) -> Bool {
        if case KeychainPasswordItem.KeychainError.unhandledError(let status) = error {
            return status == errSecMissingEntitlement
        }
        return false
    }

    private static func authenticationContext(reason: String) -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = 0
        return context
    }
}
