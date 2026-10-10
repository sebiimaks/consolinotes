// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.

import Foundation
import CommonCrypto
import CryptoKit
import Security
import RNCryptor

/// Versioned note-file envelope. CryptoKit provides authenticated encryption;
/// CommonCrypto provides password derivation. See the format section in README.md.
enum EncryptedNoteCodec {
    enum Format { case legacy, modern }

    enum CodecError: LocalizedError {
        case invalidFormat, unsupportedFormat, invalidPassword, randomFailure, derivationFailure

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "The encrypted note is incomplete or damaged."
            case .unsupportedFormat: return "This encrypted note requires a different encryption format or app version."
            case .invalidPassword: return "Use a nonempty password of at most 4096 UTF-8 bytes."
            case .randomFailure, .derivationFailure: return "The encryption key could not be created."
            }
        }
    }

    /// A modern key is derived once per unlock and released on lock. Every save
    /// still gets a fresh random GCM nonce from CryptoKit. Legacy sessions retain
    /// their original format until an explicit upgrade is requested.
    struct Session {
        let format: Format
        fileprivate let header: Data
        fileprivate let key: SymmetricKey?
        fileprivate let legacyPassword: String?

        fileprivate init(header: Data, key: SymmetricKey) {
            format = .modern
            self.header = header
            self.key = key
            legacyPassword = nil
        }

        fileprivate init(legacyPassword: String) {
            format = .legacy
            header = Data()
            key = nil
            self.legacyPassword = legacyPassword
        }
    }

    static let iterations: UInt32 = 600_000
    private static let magic = Data("CNOTEENC".utf8)
    private static let headerLength = 48
    private static let saltLength = 32

    static func makeSession(password: String) throws -> Session {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CodecError.randomFailure }
        var header = magic
        // Envelope version, cipher (AES-256-GCM), KDF (PBKDF2-SHA256), reserved.
        header.append(contentsOf: [1, 1, 1, 0])
        header.append(contentsOf: [UInt8((iterations >> 24) & 255), UInt8((iterations >> 16) & 255),
                                   UInt8((iterations >> 8) & 255), UInt8(iterations & 255)])
        header.append(salt)
        return Session(header: header, key: try deriveKey(password: password, salt: salt))
    }

    /// Only a recognized RNCryptor v3 password header can take the legacy path.
    /// A corrupt/unknown modern header cannot trigger a cryptographic downgrade.
    static func format(of encrypted: Data) throws -> Format {
        if encrypted.starts(with: magic) {
            _ = try modernHeader(encrypted)
            return .modern
        }
        // RNCryptor v3: version, password option, salts, IV, at least one
        // AES-CBC block, and HMAC-SHA256 (minimum 82 bytes).
        if encrypted.count >= 82 && encrypted.prefix(2) == Data([3, 1]) {
            return .legacy
        }
        throw CodecError.invalidFormat
    }

    static func open(_ encrypted: Data, password: String) throws -> (data: Data, session: Session) {
        switch try format(of: encrypted) {
        case .legacy:
            let plaintext = try RNCryptor.decrypt(data: encrypted, withPassword: password)
            return (plaintext, Session(legacyPassword: password))
        case .modern:
            let header = try modernHeader(encrypted)
            let salt = Data(header.suffix(saltLength))
            let key = try deriveKey(password: password, salt: salt)
            let box = try AES.GCM.SealedBox(combined: encrypted.dropFirst(headerLength))
            let plaintext = try AES.GCM.open(box, using: key, authenticating: header)
            return (plaintext, Session(header: header, key: key))
        }
    }

    static func seal(_ plaintext: Data, session: Session) throws -> Data {
        switch session.format {
        case .legacy:
            guard let password = session.legacyPassword else { throw CodecError.invalidFormat }
            return RNCryptor.encrypt(data: plaintext, withPassword: password)
        case .modern:
            guard let key = session.key, session.header.count == headerLength else { throw CodecError.invalidFormat }
            // Omitting nonce asks CryptoKit to generate a new 96-bit nonce.
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: session.header)
            guard let combined = box.combined else { throw CodecError.invalidFormat }
            return session.header + combined
        }
    }

    private static func modernHeader(_ encrypted: Data) throws -> Data {
        guard encrypted.count >= headerLength + 12 + 16 else { throw CodecError.invalidFormat }
        let header = Data(encrypted.prefix(headerLength))
        guard header.prefix(8) == magic,
              header[8] == 1, header[9] == 1, header[10] == 1, header[11] == 0 else {
            throw CodecError.unsupportedFormat
        }
        let rounds = header[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // Bound work before deriving a key. Version 1 has exactly one supported
        // cost, so damaged input cannot request billions of KDF iterations.
        guard rounds == iterations else { throw CodecError.unsupportedFormat }
        return header
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        guard !password.isEmpty, password.utf8.count <= 4096 else { throw CodecError.invalidPassword }
        var passwordBytes = Array(password.utf8)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        defer {
            _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = keyBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                keyBytes.withUnsafeMutableBytes { keyBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBuffer.count,
                        saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        keyBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), keyBuffer.count)
                }
            }
        }
        guard status == kCCSuccess else { throw CodecError.derivationFailure }
        return SymmetricKey(data: keyBytes)
    }
}
