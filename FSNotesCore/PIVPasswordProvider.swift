// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import CryptoKit
import Security
import LocalAuthentication
import CryptoTokenKit
import Darwin

/// Optional password source. Nothing here changes note files or provisions a token.
/// PIN/touch policy and any PIN caching are controlled by the token and macOS.
final class PIVPasswordProvider {
    struct Identity {
        let fingerprint: String
        let tokenID: String
        let displayName: String
        fileprivate let publicKey: SecKey

        // Internal initializer also lets tests inject ephemeral, non-Keychain keys.
        init(fingerprint: String, tokenID: String, displayName: String, publicKey: SecKey) {
            self.fingerprint = fingerprint
            self.tokenID = tokenID
            self.displayName = displayName
            self.publicKey = publicKey
        }
    }

    struct Enrollment {
        let fingerprint: String
        let tokenID: String
        let displayName: String
    }

    enum ProviderError: Error, LocalizedError {
        case noEnrollment, tokenUnavailable, unsupportedIdentity, invalidEnvelope
        case invalidPassword, verificationFailed, cancelled, authenticationFailed
        case signingRequired, storageUnavailable, unsafeStorage, securityFailure

        var errorDescription: String? {
            switch self {
            case .noEnrollment: return "No YubiKey unlock password has been enrolled."
            case .tokenUnavailable: return "The enrolled smart-card identity is unavailable. Insert the same key, or use your note password."
            case .unsupportedIdentity: return "Select an existing PIV RSA encryption identity (2048, 3072 or 4096 bits) that supports RSA-OAEP with SHA-256. No credentials on the key were changed."
            case .invalidEnvelope: return "The saved YubiKey password envelope is invalid or could not be authenticated. Use your note password and enrol again."
            case .invalidPassword: return "Enter a password between 1 and 4096 UTF-8 bytes."
            case .verificationFailed: return "The key could not verify the saved password. The previous enrollment was kept."
            case .cancelled: return "YubiKey authentication was cancelled."
            case .authenticationFailed: return "macOS could not authorize the smart-card operation. Check the key and its PIN policy, or use your note password."
            case .signingRequired: return "This build cannot access macOS smart-card identities. Token access may require an application identifier authorized by a provisioning profile. Your note password still works."
            case .storageUnavailable: return "The YubiKey password envelope could not be stored or read."
            case .unsafeStorage: return "The YubiKey password envelope has unsafe file permissions or links. Use your note password."
            case .securityFailure: return "The smart-card cryptographic operation failed. Use your note password."
            }
        }
    }

    /// Tests replace both operations: no fixture enumerates or accesses a real token.
    struct Operations {
        var identities: () throws -> [Identity]
        var decrypt: (Identity, Data, LAContext) throws -> Data
        static let system = Operations(identities: systemIdentities, decrypt: systemDecrypt)
    }

    static let shared = PIVPasswordProvider()
    private let operations: Operations
    private let directory: URL?
    private let operationLock = NSLock()
    private var operationGeneration: UInt64 = 0
    private var activeContexts = [UUID: LAContext]()
    private static let fileName = "piv-password.envelope"
    private static let magic = Data("CNTPIV01".utf8)
    private static let maximumEnvelopeSize = 8192

    init(directory: URL? = nil, operations: Operations = .system) {
        self.directory = directory
        self.operations = operations
    }

    func identities() throws -> [Identity] {
        try operations.identities().filter { Self.accepts($0) }.sorted {
            ($0.displayName, $0.fingerprint, $0.tokenID) < ($1.displayName, $1.fingerprint, $1.tokenID)
        }
    }

    func enrollment() throws -> Enrollment? {
        guard let data = try readEnvelope() else { return nil }
        return try Self.decode(data).enrollment
    }

    func enroll(password: String, identity: Identity) throws {
        let generation = currentGeneration()
        let passwordBytes = Data(password.utf8)
        guard (1...4096).contains(passwordBytes.count) else { throw ProviderError.invalidPassword }
        // Re-resolve rather than trusting a stale identity selected in the settings UI.
        guard let current = try identities().first(where: { Self.matches($0, identity) }) else {
            throw ProviderError.tokenUnavailable
        }
        var keyBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else {
            throw ProviderError.securityFailure
        }
        defer { _ = keyBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(current.publicKey, .rsaEncryptionOAEPSHA256,
                                                       Data(keyBytes) as CFData, &error) as Data? else {
            throw Self.safeError(error?.takeRetainedValue())
        }
        let metadata = Enrollment(fingerprint: current.fingerprint, tokenID: current.tokenID, displayName: current.displayName)
        let aad = try Self.header(metadata, wrapped: wrapped, boxSize: passwordBytes.count + 28)
        let sealed = try AES.GCM.seal(passwordBytes, using: SymmetricKey(data: keyBytes), authenticating: aad)
        guard let combined = sealed.combined else { throw ProviderError.securityFailure }
        let candidate = aad + combined
        // A successful private-key operation is required BEFORE replacing enrollment.
        let verified = try open(candidate, generation: generation)
        guard verified.utf8.elementsEqual(password.utf8) else { throw ProviderError.verificationFailed }
        try writeEnvelope(candidate, generation: generation)
    }

    func unlock() throws -> String {
        let generation = currentGeneration()
        guard let data = try readEnvelope() else { throw ProviderError.noEnrollment }
        return try open(data, generation: generation)
    }

    /// Invalidates authentication UI and makes pending results unusable. Call when
    /// locking, replacing the unlock UI, or closing its owning window.
    func cancelPendingOperations() {
        operationLock.lock()
        operationGeneration &+= 1
        let contexts = Array(activeContexts.values)
        activeContexts.removeAll()
        operationLock.unlock()
        contexts.forEach { $0.invalidate() }
    }

    /// Removes only this app's encrypted envelope; never a certificate or token key.
    func removeEnrollment() throws {
        cancelPendingOperations()
        let fd = try openDirectory(create: false)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard let file = try openFile(in: fd) else { return }
        close(file)
        guard unlinkat(fd, Self.fileName, 0) == 0 else { throw ProviderError.storageUnavailable }
        _ = fsync(fd)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if case ProviderError.cancelled = error { return true }
        let error = error as NSError
        if error.domain == NSOSStatusErrorDomain, error.code == Int(errSecUserCanceled) { return true }
        if error.domain == LAError.errorDomain {
            return [LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue].contains(error.code)
        }
        if error.domain == TKErrorDomain, error.code == TKError.Code.canceledByUser.rawValue { return true }
        return false
    }

    private func currentGeneration() -> UInt64 {
        operationLock.lock()
        defer { operationLock.unlock() }
        return operationGeneration
    }

    private func open(_ data: Data, generation: UInt64) throws -> String {
        let envelope = try Self.decode(data)
        guard let identity = try identities().first(where: {
            $0.fingerprint == envelope.enrollment.fingerprint && $0.tokenID == envelope.enrollment.tokenID
        }) else { throw ProviderError.tokenUnavailable }
        let context = LAContext()
        context.localizedReason = "Unlock the note password protected by your smart card."
        context.touchIDAuthenticationAllowableReuseDuration = 0
        let contextID = UUID()
        operationLock.lock()
        guard generation == operationGeneration else {
            operationLock.unlock()
            context.invalidate()
            throw ProviderError.cancelled
        }
        activeContexts[contextID] = context
        operationLock.unlock()
        defer {
            operationLock.lock()
            activeContexts.removeValue(forKey: contextID)
            operationLock.unlock()
            context.invalidate()
        }
        var keyData: Data
        do { keyData = try operations.decrypt(identity, envelope.wrapped, context) }
        catch { throw Self.safeError(error) }
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        guard keyData.count == 32 else { throw ProviderError.invalidEnvelope }
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.box)
            var clear = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: envelope.aad)
            defer { clear.resetBytes(in: 0..<clear.count) }
            guard (1...4096).contains(clear.count), let password = String(data: clear, encoding: .utf8) else {
                throw ProviderError.invalidEnvelope
            }
            guard generation == currentGeneration() else { throw ProviderError.cancelled }
            return password
        } catch ProviderError.cancelled { throw ProviderError.cancelled }
        catch { throw ProviderError.invalidEnvelope }
    }

    private struct Envelope {
        let enrollment: Enrollment
        let wrapped: Data
        let box: Data
        let aad: Data
    }

    // Binary v1: magic[8], version[1], algorithm[1], reserved[2], tokenLen[2],
    // labelLen[2], wrappedLen[2], boxLen[2], certSHA256[32], token, label, RSA wrap,
    // AES-GCM combined nonce/ciphertext/tag. All lengths are unsigned big-endian.
    // Everything except the GCM combined payload is authenticated as AAD.
    private static func header(_ metadata: Enrollment, wrapped: Data, boxSize: Int) throws -> Data {
        guard validFingerprint(metadata.fingerprint), (1...1024).contains(metadata.tokenID.utf8.count),
              (1...512).contains(metadata.displayName.utf8.count), [256, 384, 512].contains(wrapped.count),
              (29...4124).contains(boxSize) else { throw ProviderError.invalidEnvelope }
        var result = magic + Data([1, 1, 0, 0])
        for count in [metadata.tokenID.utf8.count, metadata.displayName.utf8.count, wrapped.count, boxSize] {
            result.append(UInt8(count >> 8)); result.append(UInt8(count & 255))
        }
        for offset in stride(from: 0, to: 64, by: 2) {
            let start = metadata.fingerprint.index(metadata.fingerprint.startIndex, offsetBy: offset)
            let end = metadata.fingerprint.index(start, offsetBy: 2)
            result.append(UInt8(metadata.fingerprint[start..<end], radix: 16)!)
        }
        result.append(Data(metadata.tokenID.utf8)); result.append(Data(metadata.displayName.utf8)); result.append(wrapped)
        return result
    }

    private static func decode(_ data: Data) throws -> Envelope {
        guard (339...maximumEnvelopeSize).contains(data.count), data.prefix(8) == magic,
              data[8] == 1, data[9] == 1, data[10] == 0, data[11] == 0 else { throw ProviderError.invalidEnvelope }
        func length(_ offset: Int) -> Int { Int(data[offset]) * 256 + Int(data[offset + 1]) }
        let tokenLength = length(12), labelLength = length(14), wrappedLength = length(16), boxLength = length(18)
        guard (1...1024).contains(tokenLength), (1...512).contains(labelLength),
              [256, 384, 512].contains(wrappedLength), (29...4124).contains(boxLength),
              52 + tokenLength + labelLength + wrappedLength + boxLength == data.count else {
            throw ProviderError.invalidEnvelope
        }
        let tokenEnd = 52 + tokenLength, labelEnd = tokenEnd + labelLength, wrappedEnd = labelEnd + wrappedLength
        guard let token = String(data: data[52..<tokenEnd], encoding: .utf8),
              let label = String(data: data[tokenEnd..<labelEnd], encoding: .utf8),
              !token.contains("\0"), !label.contains("\0") else { throw ProviderError.invalidEnvelope }
        let fingerprint = data[20..<52].map { String(format: "%02x", $0) }.joined()
        let metadata = Enrollment(fingerprint: fingerprint, tokenID: token, displayName: label)
        return Envelope(enrollment: metadata, wrapped: Data(data[labelEnd..<wrappedEnd]),
                        box: Data(data[wrappedEnd...]), aad: Data(data[..<wrappedEnd]))
    }

    private static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func matches(_ lhs: Identity, _ rhs: Identity) -> Bool {
        lhs.fingerprint == rhs.fingerprint && lhs.tokenID == rhs.tokenID
    }

    private static func accepts(_ identity: Identity) -> Bool {
        guard validFingerprint(identity.fingerprint), (1...1024).contains(identity.tokenID.utf8.count),
              identity.tokenID.hasPrefix("com.apple.pivtoken:"), identity.tokenID.count > "com.apple.pivtoken:".count,
              !identity.tokenID.contains("\0"),
              (1...512).contains(identity.displayName.utf8.count), !identity.displayName.contains("\0"),
              let attributes = SecKeyCopyAttributes(identity.publicKey) as? [String: Any],
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int,
              [2048, 3072, 4096].contains(bits) else { return false }
        return SecKeyIsAlgorithmSupported(identity.publicKey, .encrypt, .rsaEncryptionOAEPSHA256)
    }

    private static func tokenIdentities(context: LAContext, tokenID: String) throws -> [SecIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrAccessGroup as String: kSecAttrAccessGroupToken,
            kSecAttrTokenID as String: tokenID,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw safeError(NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
        guard let identities = result as? [SecIdentity] else { throw ProviderError.securityFailure }
        return identities
    }

    private static func describe(_ identity: SecIdentity) -> Identity? {
        var certificate: SecCertificate?, privateKey: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let certificate = certificate, let privateKey = privateKey,
              let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any],
              let token = attributes[kSecAttrTokenID as String] as? String, !token.isEmpty,
              token.hasPrefix("com.apple.pivtoken:"),
              attributes[kSecAttrCanDecrypt as String] as? Bool == true,
              SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionOAEPSHA256),
              let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        let label = SecCertificateCopySubjectSummary(certificate) as String? ?? "PIV encryption identity"
        let result = Identity(fingerprint: fingerprint, tokenID: token, displayName: label, publicKey: publicKey)
        return accepts(result) ? result : nil
    }

    private static func systemIdentities() throws -> [Identity] {
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        // Do not enumerate unrelated virtual/network token providers. Support is
        // deliberately limited to macOS's built-in PIV smart-card driver.
        let tokenIDs = TKTokenWatcher().tokenIDs.filter {
            $0.hasPrefix("com.apple.pivtoken:") && $0.count > "com.apple.pivtoken:".count
        }
        return try tokenIDs.flatMap { try tokenIdentities(context: context, tokenID: $0).compactMap { describe($0) } }
    }

    private static func systemDecrypt(_ selected: Identity, _ wrapped: Data, _ context: LAContext) throws -> Data {
        // The context belongs to this one attempt. macOS/token middleware still controls PIN caching.
        let identities = try tokenIdentities(context: context, tokenID: selected.tokenID)
        guard let identity = identities.first(where: { describe($0).map { matches($0, selected) } ?? false }) else {
            throw ProviderError.tokenUnavailable
        }
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, let key = privateKey else {
            throw ProviderError.tokenUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let clear = SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA256, wrapped as CFData, &error) as Data? else {
            throw safeError(error?.takeRetainedValue())
        }
        return clear
    }

    private static func safeError(_ error: Error?) -> ProviderError {
        guard let error = error else { return .securityFailure }
        if let known = error as? ProviderError { return known }
        if isCancellation(error) { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == TKErrorDomain {
            switch TKError.Code(rawValue: nsError.code) {
            case .authenticationFailed, .authenticationNeeded: return .authenticationFailed
            case .tokenNotFound, .objectNotFound, .communicationError: return .tokenUnavailable
            default: break
            }
        }
        if nsError.domain == NSOSStatusErrorDomain {
            switch OSStatus(nsError.code) {
            case errSecMissingEntitlement: return .signingRequired
            case errSecAuthFailed, errSecInteractionNotAllowed: return .authenticationFailed
            case errSecItemNotFound, errSecNotAvailable: return .tokenUnavailable
            default: break
            }
        }
        return .securityFailure
    }

    private func storageDirectory(create: Bool) throws -> URL {
        if let directory = directory { return directory }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProviderError.storageUnavailable
        }
        let parent = support.appendingPathComponent("consolinotes", isDirectory: true)
        if create {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { throw ProviderError.storageUnavailable }
        }
        return parent.appendingPathComponent("HardwareUnlock.noindex", isDirectory: true)
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        let url = try storageDirectory(create: create)
        if create, mkdir(url.path, 0o700) != 0, errno != EEXIST { throw ProviderError.storageUnavailable }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if !create && errno == ENOENT { return -1 }
            throw ProviderError.unsafeStorage
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o077) == 0 else { close(fd); throw ProviderError.unsafeStorage }
        return fd
    }

    private func openFile(in directory: Int32, requireValidSize: Bool = false) throws -> Int32? {
        let fd = openat(directory, Self.fileName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ProviderError.unsafeStorage
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
            close(fd); throw ProviderError.unsafeStorage
        }
        if requireValidSize && (info.st_size <= 0 || info.st_size > Self.maximumEnvelopeSize) {
            close(fd); throw ProviderError.invalidEnvelope
        }
        return fd
    }

    private func readEnvelope() throws -> Data? {
        let directory = try openDirectory(create: false)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        guard let fd = try openFile(in: directory, requireValidSize: true) else { return nil }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: Self.maximumEnvelopeSize + 1)
        var count = 0
        while count < bytes.count {
            let capacity = bytes.count - count
            let readCount = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), capacity) }
            if readCount == 0 { break }
            if readCount < 0 { if errno == EINTR { continue }; throw ProviderError.storageUnavailable }
            count += readCount
        }
        guard count <= Self.maximumEnvelopeSize else { throw ProviderError.invalidEnvelope }
        return Data(bytes.prefix(count))
    }

    private func writeEnvelope(_ data: Data, generation: UInt64) throws {
        guard data.count <= Self.maximumEnvelopeSize else { throw ProviderError.invalidEnvelope }
        let directory = try openDirectory(create: true)
        defer { close(directory) }
        // Refuse unexpected links, permissions, owners or file types before replacement.
        if let existing = try openFile(in: directory) { close(existing) }
        let temporaryName = ".piv-password-\(UUID().uuidString)"
        let fd = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProviderError.storageUnavailable }
        defer { close(fd); _ = unlinkat(directory, temporaryName, 0) }
        try data.withUnsafeBytes { bytes in
            var count = 0
            while count < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                if written < 0 { if errno == EINTR { continue }; throw ProviderError.storageUnavailable }
                guard written > 0 else { throw ProviderError.storageUnavailable }
                count += written
            }
        }
        guard fsync(fd) == 0 else { throw ProviderError.storageUnavailable }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard generation == operationGeneration else { throw ProviderError.cancelled }
        guard renameat(directory, temporaryName, directory, Self.fileName) == 0 else {
            throw ProviderError.storageUnavailable
        }
        // Rename is the commit point. A post-commit directory fsync failure cannot
        // truthfully be reported as an enrollment failure preserving the old file.
        _ = fsync(directory)
    }
}
