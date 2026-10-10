#!/usr/bin/env python3
"""Exercise the real PIV envelope with ephemeral RSA keys and isolated files.

The injected backend replaces BOTH enumeration and private-key operations. These
tests never query the user's Keychain, enumerate tokens, or prompt for a real PIN.
They cannot certify hardware policies, macOS token authentication UI or signing.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Foundation
import Security
import CryptoKit
import LocalAuthentication
import CryptoTokenKit
import Darwin

func expect(_ value: @autoclosure () throws -> Bool, _ message: String) {
    do { if try !value() { fatalError(message) } }
    catch { fatalError("Unexpected fixture error: \(error)") }
}
func fails(_ work: () throws -> Void) {
    do { try work(); fatalError("Expected failure") } catch { }
}
func expectError(_ expected: PIVPasswordProvider.ProviderError, _ work: () throws -> Void) {
    do { try work(); fatalError("Expected failure") }
    catch let error as PIVPasswordProvider.ProviderError {
        expect(String(describing: error) == String(describing: expected), "Unexpected error: \(error)")
    } catch { fatalError("Unexpected error type") }
}
func makeKey(bits: Int = 2048) -> SecKey {
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey([
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: bits,
        kSecUseDataProtectionKeychain as String: true,
        kSecAttrIsPermanent as String: false
    ] as CFDictionary, &error) else {
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        fatalError("Ephemeral fixture RSA-\(bits) generation failed (\(code))")
    }
    return key
}
final class FakeToken {
    let key = makeKey()
    let publicKey: SecKey
    let identity: PIVPasswordProvider.Identity
    var available: [PIVPasswordProvider.Identity]
    var contexts = [LAContext]()
    var decryptionError: Error?
    var decryptedOverride: Data?
    var enumerationCount = 0
    var disappearAtEnumeration: Int?
    var decryptions = 0
    var onDecrypt: (() -> Void)?

    init() {
        publicKey = SecKeyCopyPublicKey(key)!
        let bytes = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        identity = PIVPasswordProvider.Identity(fingerprint: fingerprint, tokenID: "com.apple.pivtoken:synthetic-fixture",
                                                displayName: "Synthetic encryption identity", publicKey: publicKey)
        available = [identity]
    }
    var operations: PIVPasswordProvider.Operations {
        PIVPasswordProvider.Operations(identities: {
            self.enumerationCount += 1
            if let count = self.disappearAtEnumeration, self.enumerationCount >= count { return [] }
            return self.available
        }, decrypt: { identity, wrapped, context in
            self.decryptions += 1
            expect(identity.fingerprint == self.identity.fingerprint && identity.tokenID == self.identity.tokenID,
                   "Wrong identity reached private operation")
            expect(context.touchIDAuthenticationAllowableReuseDuration == 0, "Reuses an authentication context")
            expect(!self.contexts.contains(where: { $0 === context }), "Same LAContext used twice")
            self.contexts.append(context)
            self.onDecrypt?()
            if let error = self.decryptionError { throw error }
            if let override = self.decryptedOverride { return override }
            var error: Unmanaged<CFError>?
            guard let clear = SecKeyCreateDecryptedData(self.key, .rsaEncryptionOAEPSHA256, wrapped as CFData, &error) else {
                throw error!.takeRetainedValue()
            }
            return clear as Data
        })
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let directory = root.appendingPathComponent("envelope", isDirectory: true)
let token = FakeToken()
let provider = PIVPasswordProvider(directory: directory, operations: token.operations)
let file = directory.appendingPathComponent("piv-password.envelope")
let password = "fixture: e\u{301} / é / 🗝\0embedded-null"
expect(try provider.enrollment() == nil, "Invented enrollment")
expectError(.noEnrollment) { _ = try provider.unlock() }
fails { try provider.enroll(password: "", identity: token.identity) }
fails { try provider.enroll(password: String(repeating: "x", count: 4097), identity: token.identity) }
expect(token.decryptions == 0, "Invalid passwords touched token")

// Production selection checks apply even to injected descriptors.
let unrelated = PIVPasswordProvider.Identity(fingerprint: token.identity.fingerprint, tokenID: "third.party.software:fake",
                                               displayName: "Virtual provider", publicKey: token.publicKey)
let enclave = PIVPasswordProvider.Identity(fingerprint: token.identity.fingerprint, tokenID: kSecAttrTokenIDSecureEnclave as String,
                                           displayName: "Enclave", publicKey: token.publicKey)
let emptyToken = PIVPasswordProvider.Identity(fingerprint: token.identity.fingerprint, tokenID: "com.apple.pivtoken:",
                                              displayName: "No token instance", publicKey: token.publicKey)
let weakKey = makeKey(bits: 1024)
let weak = PIVPasswordProvider.Identity(fingerprint: token.identity.fingerprint, tokenID: token.identity.tokenID,
                                       displayName: "Weak RSA", publicKey: SecKeyCopyPublicKey(weakKey)!)
token.available = [unrelated, enclave, emptyToken, weak, token.identity]
expect(try provider.identities().count == 1, "Accepted software/empty token or weak RSA")
token.available = [token.identity]

try provider.enroll(password: password, identity: token.identity)
expect(token.decryptions == 1, "Enrollment skipped hardware private-key roundtrip")
expect(try provider.unlock().utf8.elementsEqual(password.utf8), "UTF-8 password changed")
let metadata = try provider.enrollment()!
expect(metadata.fingerprint == token.identity.fingerprint && metadata.tokenID == token.identity.tokenID,
       "Identity binding not preserved")
expect(metadata.displayName == token.identity.displayName, "Label not preserved")
var original = try Data(contentsOf: file)
expect(original.range(of: Data(password.utf8)) == nil, "Plaintext password on disk")
let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
expect(directoryMode.intValue == 0o700 && fileMode.intValue == 0o600, "Unsafe envelope permissions")
try provider.enroll(password: password, identity: token.identity)
expect(try Data(contentsOf: file) != original, "Repeated enrollment reused cryptographic randomness")
original = try Data(contentsOf: file)

func replace(_ bytes: Data) throws {
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
func length(_ data: Data, _ offset: Int) -> Int { Int(data[offset]) * 256 + Int(data[offset + 1]) }
let tokenEnd = 52 + length(original, 12)
let labelEnd = tokenEnd + length(original, 14)
let wrappedEnd = labelEnd + length(original, 16)

// Authenticated metadata, nonce, ciphertext and tag; strict version/length handling.
for offset in [0, 8, 9, 10, 11, 12, 14, 16, 18, 20, 52, tokenEnd, labelEnd, wrappedEnd, original.count - 1] {
    var damaged = original
    damaged[offset] ^= 1
    try replace(damaged)
    fails { _ = try provider.unlock() }
    expect(try Data(contentsOf: file) == damaged, "Unlock rewrote a failed envelope")
}
for malformed in [Data(), Data(original.prefix(20)), Data(original.dropLast()), original + Data([0]), Data(repeating: 1, count: 8193)] {
    try replace(malformed)
    fails { _ = try provider.unlock() }
}
try replace(original)

// Missing/different key never attempts a private operation or falls back elsewhere.
let decryptions = token.decryptions
token.available = []
expectError(.tokenUnavailable) { _ = try provider.unlock() }
let differentCertificate = PIVPasswordProvider.Identity(fingerprint: String(repeating: "b", count: 64),
    tokenID: token.identity.tokenID, displayName: token.identity.displayName, publicKey: token.publicKey)
token.available = [differentCertificate]
expectError(.tokenUnavailable) { _ = try provider.unlock() }
let differentToken = PIVPasswordProvider.Identity(fingerprint: token.identity.fingerprint,
    tokenID: "com.apple.pivtoken:other-instance", displayName: token.identity.displayName, publicKey: token.publicKey)
token.available = [differentToken]
expectError(.tokenUnavailable) { _ = try provider.unlock() }
expect(token.decryptions == decryptions, "Wrong identity used private key")
token.available = [token.identity]

// Every cancellation/auth/signing/error path leaves existing enrollment byte-for-byte intact.
for error in [NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled)),
              NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed)),
              NSError(domain: NSOSStatusErrorDomain, code: Int(errSecMissingEntitlement))] {
    token.decryptionError = error
    fails { try provider.enroll(password: "replacement", identity: token.identity) }
    expect(try Data(contentsOf: file) == original, "Failed enrollment replaced working enrollment")
    fails { _ = try provider.unlock() }
}
token.decryptionError = NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue)
expectError(.cancelled) { _ = try provider.unlock() }
token.decryptionError = NSError(domain: TKErrorDomain, code: TKError.Code.canceledByUser.rawValue)
expectError(.cancelled) { _ = try provider.unlock() }
token.decryptionError = NSError(domain: TKErrorDomain, code: TKError.Code.tokenNotFound.rawValue)
expectError(.tokenUnavailable) { _ = try provider.unlock() }
expect(PIVPasswordProvider.isCancellation(PIVPasswordProvider.ProviderError.cancelled), "Cancellation lost")
token.decryptionError = nil
token.decryptedOverride = Data(repeating: 0, count: 32)
fails { try provider.enroll(password: "replacement", identity: token.identity) }
expect(try Data(contentsOf: file) == original, "Failed private roundtrip replaced existing enrollment")
token.decryptedOverride = Data(repeating: 0, count: 31)
fails { _ = try provider.unlock() }
token.decryptedOverride = nil
token.disappearAtEnumeration = token.enumerationCount + 2
fails { try provider.enroll(password: "replacement", identity: token.identity) }
expect(try Data(contentsOf: file) == original, "Token removal during enrollment destroyed old enrollment")
token.disappearAtEnumeration = nil
token.onDecrypt = { provider.cancelPendingOperations() }
expectError(.cancelled) { _ = try provider.unlock() }
expectError(.cancelled) { try provider.enroll(password: "replacement", identity: token.identity) }
expect(try Data(contentsOf: file) == original, "Cancellation during hardware operation replaced enrollment")
token.onDecrypt = nil
expect(try provider.unlock().utf8.elementsEqual(password.utf8), "New attempt after cancellation failed")

// Authenticated but invalid UTF-8 is still rejected; no normalization of passwords.
let wrapped = Data(original[labelEnd..<wrappedEnd])
let aesKey = SecKeyCreateDecryptedData(token.key, .rsaEncryptionOAEPSHA256, wrapped as CFData, nil)! as Data
let badPassword = Data(repeating: 0xff, count: password.utf8.count)
let aad = Data(original[..<wrappedEnd])
let badBox = try AES.GCM.seal(badPassword, using: SymmetricKey(data: aesKey), authenticating: aad).combined!
try replace(aad + badBox)
expectError(.invalidEnvelope) { _ = try provider.unlock() }
try replace(original)

// Unsafe filesystem entries fail closed, including FIFO (must not block on open).
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
fails { _ = try provider.unlock() }
fails { try provider.enroll(password: "replacement", identity: token.identity) }
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
let held = root.appendingPathComponent("held-envelope")
try FileManager.default.moveItem(at: file, to: held)
try FileManager.default.createSymbolicLink(at: file, withDestinationURL: held)
fails { _ = try provider.unlock() }
fails { try provider.removeEnrollment() }
fails { try provider.enroll(password: "replacement", identity: token.identity) }
expect(try Data(contentsOf: held) == original, "Symlink target changed")
try FileManager.default.removeItem(at: file)
try FileManager.default.linkItem(at: held, to: file)
fails { _ = try provider.unlock() }
fails { try provider.removeEnrollment() }
try FileManager.default.removeItem(at: file)
expect(mkfifo(file.path, 0o600) == 0, "Fixture FIFO creation failed")
fails { _ = try provider.unlock() }
fails { try provider.removeEnrollment() }
try FileManager.default.removeItem(at: file)
try FileManager.default.moveItem(at: held, to: file)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
fails { _ = try provider.unlock() }
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
expect(try provider.unlock().utf8.elementsEqual(password.utf8), "Recovery from fixture failures broke enrollment")

// Removing the envelope touches only the file; the same injected key remains usable.
let removals = token.decryptions
try provider.removeEnrollment()
expect(try provider.enrollment() == nil, "Removal left enrollment")
expect(token.decryptions == removals && token.available.count == 1, "Removal touched token")
try provider.removeEnrollment()
let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
expect(remaining.isEmpty, "Temporary enrollment artifacts left behind")

// Corruption does not strand an otherwise safe regular envelope: explicit
// replacement/removal can recover without following links or changing token keys.
try replace(Data())
fails { _ = try provider.unlock() }
try provider.enroll(password: password, identity: token.identity)
expect(try provider.unlock().utf8.elementsEqual(password.utf8), "Cannot replace corrupt safe envelope")
try replace(Data(repeating: 0, count: 8193))
fails { _ = try provider.unlock() }
try provider.removeEnrollment()
expect(try provider.enrollment() == nil, "Cannot remove corrupt safe envelope")

let maximumPassword = String(repeating: "z", count: 4096)
try provider.enroll(password: maximumPassword, identity: token.identity)
expect(try provider.unlock().utf8.elementsEqual(maximumPassword.utf8), "Maximum password bound failed")
try provider.removeEnrollment()
print("PIV password: ephemeral RSA/AES-GCM roundtrip, strict envelopes, tampering, identity binding, cancellation, failed-enrollment preservation and private-file checks passed; no user Keychain/token accessed")
'''

source = ROOT / "FSNotesCore/PIVPasswordProvider.swift"
text = source.read_text()
for forbidden in ("SecItemAdd(", "SecItemUpdate(", "SecItemDelete(", "UserDefaults", "SecKeyCreateRandomKey("):
    assert forbidden not in text, f"Production provider must not provision/persist credentials: {forbidden}"
assert "kSecAttrAccessGroupToken" in text and 'hasPrefix("com.apple.pivtoken:")' in text
assert "kSecUseAuthenticationContext as String: context" in text
with tempfile.TemporaryDirectory(prefix="consolinotes-piv-") as temporary:
    directory = Path(temporary)
    (directory / "main.swift").write_text(FIXTURE)
    subprocess.run([
        "xcrun", "swiftc", str(source), str(directory / "main.swift"),
        "-module-cache-path", str(directory / "module-cache"),
        "-o", str(directory / "check-piv"),
    ], check=True)
    subprocess.run([str(directory / "check-piv"), str(directory)], check=True, timeout=60)
