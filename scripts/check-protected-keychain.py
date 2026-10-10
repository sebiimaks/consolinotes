#!/usr/bin/env python3
"""Compile and exercise the real protected-password lifecycle using an in-memory backend.

No user's Keychain is read or changed. Security APIs are compiled and access-control
objects are created, but all SecItem operations are replaced by the fixture below.
This cannot certify the OS authentication UI or an app's signing/provisioning profile.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Foundation
import Security
import LocalAuthentication

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func expectFailure(_ work: () throws -> Void) {
    do { try work(); fatalError("Expected failure") } catch { }
}
final class MemoryKeychain {
    var protected: Data?
    var ownLegacy: Data? = Data("old convenient password".utf8)
    let upstreamLegacy = Data("belongs to FSNotes".utf8)
    var events = [String]()
    var copies = 0
    var copyErrors = [Int: OSStatus]()
    var addError: OSStatus = errSecSuccess
    var updateError: OSStatus = errSecSuccess
    var deleteError: OSStatus = errSecSuccess
    var corruptReadback = false
    var readbackOverride: Data?
    var authenticationContexts = [LAContext]()

    init(_ password: String? = nil) { protected = password.map { Data($0.utf8) } }
    func checkProtected(_ query: [String: Any]) {
        expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String, "Wrong class")
        expect(query[kSecAttrService as String] as? String == KeychainConfiguration.serviceName, "Legacy secret read or unprotected fallback")
        expect(query[kSecAttrAccount as String] as? String == "Master Password", "Wrong account")
        expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true, "Protected operation targets file-based keychain")
        expect(query[kSecAttrSynchronizable as String] as? Bool == false, "Must never synchronize password")
        guard let context = query[kSecUseAuthenticationContext as String] as? LAContext else { fatalError("Missing context") }
        expect(context.touchIDAuthenticationAllowableReuseDuration == 0, "Must not reuse device unlock")
        authenticationContexts.append(context)
    }
    var operations: KeychainOperations {
        KeychainOperations(
            copy: { query in
                self.checkProtected(query)
                self.events.append("read-protected")
                self.copies += 1
                expect(query[kSecReturnData as String] as? Bool == true, "No data request")
                expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String, "Over-broad read")
                if let error = self.copyErrors[self.copies] { return (error, nil) }
                guard let value = self.protected else { return (errSecItemNotFound, nil) }
                if self.copies > 1, let override = self.readbackOverride { return (errSecSuccess, override as NSData) }
                return (errSecSuccess, (self.corruptReadback && self.copies > 1 ? Data("wrong".utf8) : value) as NSData)
            },
            add: { query in
                self.checkProtected(query)
                self.events.append("add-protected")
                guard let acl = query[kSecAttrAccessControl as String] else { fatalError("Missing user-presence control") }
                expect(CFGetTypeID(acl as CFTypeRef) == SecAccessControlGetTypeID(), "Not a Security access-control object")
                expect(query[kSecAttrAccessible as String] == nil, "Duplicate accessibility conflicts with access control")
                if self.addError != errSecSuccess { return self.addError }
                guard self.protected == nil else { return errSecDuplicateItem }
                self.protected = query[kSecValueData as String] as? Data
                return errSecSuccess
            },
            update: { query, attributes in
                self.checkProtected(query)
                self.events.append("update-protected")
                expect(attributes.count == 1 && attributes[kSecValueData as String] != nil, "Update must preserve existing protection")
                if self.updateError != errSecSuccess { return self.updateError }
                self.protected = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { query in
                self.events.append("delete-own-legacy")
                expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String, "Wrong delete class")
                expect(query[kSecAttrService as String] as? String == "consolinotes", "Deletes another service")
                expect(query[kSecAttrAccount as String] as? String == "Master Password", "Broad legacy deletion")
                expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false, "Must explicitly target old file-based item")
                expect(query[kSecAttrSynchronizable as String] as? Bool == false, "Must not delete synced data")
                if self.deleteError != errSecSuccess { return self.deleteError }
                self.ownLegacy = nil
                return errSecSuccess
            }
        )
    }
}

// First explicit save migrates only after authenticated readback.
do {
    let backend = MemoryKeychain()
    let result = try KeychainConfiguration.saveMasterPassword("fixture", currentPassword: "", operations: backend.operations)
    expect(result == .saved, "First save failed")
    expect(backend.events == ["read-protected", "add-protected", "read-protected", "delete-own-legacy"], "Unsafe migration order")
    expect(backend.ownLegacy == nil, "Own legacy not removed after verification")
    expect(backend.upstreamLegacy == Data("belongs to FSNotes".utf8), "Other app changed")
    expect(backend.authenticationContexts.allSatisfy { $0 === backend.authenticationContexts[0] }, "Save must share one authentication transaction")
}
// Every ordinary read targets only the protected namespace; absence never imports old values.
do {
    let backend = MemoryKeychain("fixture")
    let value = try KeychainConfiguration.readMasterPassword(operations: backend.operations)
    expect(value == "fixture" && backend.events == ["read-protected"], "Protected read failed")
    _ = try KeychainConfiguration.readMasterPassword(operations: backend.operations)
    expect(backend.authenticationContexts[0] !== backend.authenticationContexts[1], "Reads must use fresh contexts")
    let missing = MemoryKeychain()
    expectFailure { _ = try KeychainConfiguration.readMasterPassword(operations: missing.operations) }
    expect(missing.events == ["read-protected"] && missing.ownLegacy != nil, "Missing item triggered legacy access")
}
// Cancellation, failed authentication, locked Keychain and signing errors never turn into adds or legacy reads.
for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement] {
    let backend = MemoryKeychain("old")
    backend.copyErrors[1] = status
    expectFailure { _ = try KeychainConfiguration.readMasterPassword(operations: backend.operations) }
    expect(backend.events == ["read-protected"], "Read denial triggered fallback")
    let update = MemoryKeychain("old")
    update.copyErrors[1] = status
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword("new", currentPassword: "old", operations: update.operations) }
    expect(update.events == ["read-protected"], "Update denial caused mutation")
    expect(update.protected == Data("old".utf8) && update.ownLegacy != nil, "Denial lost recoverable credentials")
}
// Existing-password replacement authenticates and compares the typed current value before modifying.
do {
    let backend = MemoryKeychain("old")
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword("new", currentPassword: "wrong", operations: backend.operations) }
    expect(backend.events == ["read-protected"] && backend.protected == Data("old".utf8), "Wrong current password changed value")
    backend.events = []
    let result = try KeychainConfiguration.saveMasterPassword("new", currentPassword: "old", operations: backend.operations)
    expect(result == .saved && backend.protected == Data("new".utf8), "Replacement failed")
    expect(backend.events == ["read-protected", "update-protected", "read-protected", "delete-own-legacy"], "Unsafe replacement order")
}
// Failed writes and post-save verification preserve the old convenience item.
for status in [errSecMissingEntitlement, errSecDuplicateItem] {
    let backend = MemoryKeychain()
    backend.addError = status
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword("new", operations: backend.operations) }
    expect(backend.events == ["read-protected", "add-protected"] && backend.ownLegacy != nil, "Failed add removed legacy or fell back")
}
do {
    let backend = MemoryKeychain("old")
    backend.updateError = errSecAuthFailed
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword("new", operations: backend.operations) }
    expect(backend.protected == Data("old".utf8) && backend.ownLegacy != nil, "Failed update lost values")
    expect(backend.events == ["read-protected", "update-protected"], "Failed update continued migration")
}
for denied in [false, true] {
    let backend = MemoryKeychain()
    if denied { backend.copyErrors[2] = errSecUserCanceled } else { backend.corruptReadback = true }
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword("new", operations: backend.operations) }
    expect(backend.events == ["read-protected", "add-protected", "read-protected"], "Failed verification continued cleanup")
    expect(backend.ownLegacy != nil, "Unverified migration deleted legacy")
}
do {
    let backend = MemoryKeychain()
    backend.deleteError = errSecAuthFailed
    let result = try KeychainConfiguration.saveMasterPassword("new", operations: backend.operations)
    expect(result == .savedLegacyCleanupFailed && backend.ownLegacy != nil, "Incomplete cleanup incorrectly reported success")
    expect(backend.protected == Data("new".utf8), "Verified protected save lost")
    let noLegacy = MemoryKeychain()
    noLegacy.deleteError = errSecItemNotFound
    let noLegacyResult = try KeychainConfiguration.saveMasterPassword("new", operations: noLegacy.operations)
    expect(noLegacyResult == .saved, "Missing legacy item should not fail")
}
do {
    let backend = MemoryKeychain("old")
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword("", operations: backend.operations) }
    expect(backend.events.isEmpty && backend.protected == Data("old".utf8), "Empty replacement accessed Keychain")
    expect(KeychainConfiguration.isAuthenticationCancelled(KeychainPasswordItem.KeychainError.unhandledError(status: errSecUserCanceled)), "Cancellation classification failed")
    expect(!KeychainConfiguration.isAuthenticationCancelled(KeychainPasswordItem.KeychainError.noPassword), "Missing item is not cancellation")
}
do {
    let composed = "\u{00e9}", decomposed = "e\u{0301}"
    let backend = MemoryKeychain(composed)
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword("new", currentPassword: decomposed, operations: backend.operations) }
    expect(backend.events == ["read-protected"], "Canonical-equivalent password bytes allowed replacement")
    let readback = MemoryKeychain()
    readback.readbackOverride = Data(decomposed.utf8)
    expectFailure { _ = try KeychainConfiguration.saveMasterPassword(composed, operations: readback.operations) }
    expect(readback.ownLegacy != nil, "Different UTF-8 bytes verified and deleted legacy recovery")
}
print("Protected Keychain lifecycle: isolated save/read/migration/denial and exact password byte checks passed; no user Keychain accessed")
'''

with tempfile.TemporaryDirectory(prefix="consolinotes-keychain-") as directory:
    temp = Path(directory)
    main = temp / "main.swift"
    main.write_text(FIXTURE)
    executable = temp / "check-keychain"
    subprocess.run([
        "swiftc", str(ROOT / "FSNotesCore/KeychainPasswordItem.swift"),
        str(ROOT / "FSNotesCore/KeychainConfiguration.swift"), str(main),
        "-module-cache-path", str(temp / "module-cache"), "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
