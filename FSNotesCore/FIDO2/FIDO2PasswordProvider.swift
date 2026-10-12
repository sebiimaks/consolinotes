import Foundation
import CryptoKit
import Security
import Darwin

/// Direct USB only. Does not call Keychain, CryptoTokenKit or LocalAuthentication.
final class FIDO2PasswordProvider {
    static let shared = FIDO2PasswordProvider()
    static let worker = DispatchQueue(label: "consolinotes.fido2", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("consolinotes/FIDO2Unlock.noindex", isDirectory: true)
    }
    struct Envelope: Codable {
        let version: Int
        let credential: Data
        let publicKey: Data
        let salt: Data
        let ciphertext: Data
        var aad: Data { Data("consolinotes.fido2.envelope.v1\0".utf8) + credential + publicKey + salt }
        func validate() throws {
            guard version == 1, (1...1024).contains(credential.count), publicKey.count == 64,
                  salt.count == 32, (29...8192).contains(ciphertext.count) else { throw Failure("Invalid YubiKey enrollment. Enter your note password instead.") }
        }
    }
    struct Enrollment: Codable {
        let id: String
        let name: String
        let envelope: Envelope
        static func identifier(for credential: Data) -> String {
            SHA256.hash(data: credential).map { String(format: "%02x", $0) }.joined()
        }
        func validate() throws {
            try envelope.validate()
            guard id == Self.identifier(for: envelope.credential),
                  try FIDO2PasswordProvider.validName(name) == name else {
                throw Failure("Invalid YubiKey enrollment metadata. Enter your note password instead.")
            }
        }
    }
    private struct Collection: Codable {
        let version: Int
        let enrollments: [Enrollment]
        func validate() throws {
            guard version == 2, enrollments.count <= 16 else {
                throw Failure("Invalid YubiKey enrollment collection. Enter your note password instead.")
            }
            var ids = Set<String>(), credentials = Set<Data>(), names = Set<String>()
            for enrollment in enrollments {
                try enrollment.validate()
                guard ids.insert(enrollment.id).inserted,
                      credentials.insert(enrollment.envelope.credential).inserted else {
                    throw Failure("Duplicate YubiKey enrollment. Enter your note password instead.")
                }
                guard names.insert(FIDO2PasswordProvider.nameKey(enrollment.name)).inserted else {
                    throw Failure("Use a different name for each YubiKey enrollment.")
                }
            }
        }
    }
    private static func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(value.count), value.utf8.count <= 320,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw Failure("Give this YubiKey a name of 1–80 characters without control characters.")
        }
        return value
    }
    private static func nameKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    func ticket() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func cancel() { lock.lock(); generation &+= 1; lock.unlock() }
    func current(_ ticket: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return ticket == generation }
    private func check(_ code: Int32) throws { if code != 0 { throw Failure(String(cString: cn_fido_error(code))) } }
    private func device() throws -> String {
        var path = [CChar](repeating: 0, count: 1024)
        try check(cn_fido_path(&path, path.count))
        return String(cString: path)
    }
    static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }) == errSecSuccess else { throw Failure("Secure random generation failed.") }
        return bytes
    }
    static func key(secret: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
            info: Data("consolinotes.fido2.password.aes256gcm.v1".utf8), outputByteCount: 32)
    }
    static func seal(password: String, credential: Data, publicKey: Data, salt: Data, secret: Data) throws -> Envelope {
        guard !password.isEmpty, password.utf8.count <= 4096, secret.count == 32 else { throw Failure("Invalid password or hardware secret.") }
        let metadata = Envelope(version: 1, credential: credential, publicKey: publicKey, salt: salt, ciphertext: Data())
        let box = try AES.GCM.seal(Data(password.utf8), using: key(secret: secret, salt: salt), authenticating: metadata.aad)
        let envelope = Envelope(version: 1, credential: credential, publicKey: publicKey, salt: salt, ciphertext: box.combined!)
        try envelope.validate(); return envelope
    }
    static func open(_ envelope: Envelope, secret: Data) throws -> String {
        try envelope.validate()
        guard secret.count == 32 else { throw Failure("Invalid hardware secret.") }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key(secret: secret, salt: envelope.salt), authenticating: envelope.aad)
        guard let value = String(data: plaintext, encoding: .utf8), !value.isEmpty, value.utf8.count <= 4096 else { throw Failure("Invalid saved password.") }
        return value
    }
    private func derive(path: String, pin: String, envelope: Envelope) throws -> Data {
        var secret = [UInt8](repeating: 0, count: 32)
        defer { secret.withUnsafeMutableBytes { cn_fido_wipe($0.baseAddress!, $0.count) } }
        let code = envelope.credential.withUnsafeBytes { id in
            envelope.publicKey.withUnsafeBytes { pk in
                envelope.salt.withUnsafeBytes { salt in
                    cn_fido_secret(path, pin, id.bindMemory(to: UInt8.self).baseAddress!, id.count,
                        pk.bindMemory(to: UInt8.self).baseAddress!, salt.bindMemory(to: UInt8.self).baseAddress!, &secret)
                }
            }
        }
        try check(code); return Data(secret)
    }
    /// The callback runs on the worker immediately before each hardware activation.
    /// It may wait for explicit UI confirmation; returning false cancels the transaction.
    func enroll(name: String, password: String, pin: String, ticket: UInt64,
                beforeActivation: @escaping (Int) -> Bool) throws {
        guard !password.isEmpty, password.utf8.count <= 4096, !pin.isEmpty, pin.utf8.count <= 63, !pin.utf8.contains(0) else { throw Failure("Enter your note password and the key's FIDO2 PIN.") }
        let name = try Self.validName(name)
        guard current(ticket) else { throw Failure("Canceled.") }
        let existing = try enrollments()
        guard existing.count < 16 else { throw Failure("You can enroll up to 16 YubiKeys. Remove one before adding another.") }
        guard !existing.contains(where: { Self.nameKey($0.name) == Self.nameKey(name) }) else {
            throw Failure("Use a different name for each YubiKey enrollment.")
        }
        func activate(_ step: Int) throws {
            guard current(ticket), beforeActivation(step), current(ticket) else { throw Failure("Canceled.") }
        }
        var id = [UInt8](repeating: 0, count: 1024), pk = [UInt8](repeating: 0, count: 64), count = 1024
        try activate(1)
        let path = try device()
        guard current(ticket) else { throw Failure("Canceled.") }
        try check(cn_fido_create(path, pin, &id, &count, &pk))
        guard current(ticket) else { throw Failure("Canceled.") }
        guard (1...id.count).contains(count) else { throw Failure("Invalid hardware credential.") }
        let metadata = Envelope(version: 1, credential: Data(id.prefix(count)), publicKey: Data(pk), salt: try Self.random(32), ciphertext: Data())
        try activate(2)
        var secret = try derive(path: path, pin: pin, envelope: metadata)
        defer { secret.resetBytes(in: 0..<secret.count) }
        let envelope = try Self.seal(password: password, credential: metadata.credential, publicKey: metadata.publicKey, salt: metadata.salt, secret: secret)
        // A second private operation verifies reproducibility before committing enrollment.
        try activate(3)
        var verification = try derive(path: path, pin: pin, envelope: envelope)
        defer { verification.resetBytes(in: 0..<verification.count) }
        guard try Self.open(envelope, secret: verification).utf8.elementsEqual(password.utf8) else { throw Failure("Hardware verification failed. Previous enrollment was kept.") }
        lock.lock(); defer { lock.unlock() }
        guard ticket == generation else { throw Failure("Canceled.") }
        // Read again under the commit lock so another addition or rename is preserved.
        var records = try readEnrollments()
        guard records.count < 16 else { throw Failure("You can enroll up to 16 YubiKeys. Remove one before adding another.") }
        records.append(Enrollment(id: Enrollment.identifier(for: envelope.credential), name: name, envelope: envelope))
        try save(records)
    }
    func unlock(id: String, pin: String, ticket: UInt64, beforeActivation: () -> Bool) throws -> String {
        guard !pin.isEmpty, pin.utf8.count <= 63, !pin.utf8.contains(0) else { throw Failure("Enter the key's FIDO2 PIN.") }
        guard current(ticket) else { throw Failure("Canceled.") }
        guard let enrollment = try enrollments().first(where: { $0.id == id }) else { throw Failure("This YubiKey enrollment is no longer available. Enter your note password.") }
        guard current(ticket), beforeActivation(), current(ticket) else { throw Failure("Canceled.") }
        let path = try device()
        guard current(ticket) else { throw Failure("Canceled.") }
        var secret = try derive(path: path, pin: pin, envelope: enrollment.envelope)
        defer { secret.resetBytes(in: 0..<secret.count) }
        guard current(ticket) else { throw Failure("Canceled.") }
        return try Self.open(enrollment.envelope, secret: secret)
    }
    // Directory-relative, no-follow I/O prevents symlink substitution of envelope files.
    private func directoryFD(create: Bool) throws -> Int32 {
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot access local YubiKey enrollment storage.") }
        var statbuf = stat()
        guard fstat(fd, &statbuf) == 0, statbuf.st_uid == getuid(), statbuf.st_mode & 0o077 == 0 else {
            close(fd); throw Failure("YubiKey enrollment directory has unsafe permissions.")
        }
        return fd
    }
    func load() throws -> Envelope? {
        try enrollments().first?.envelope
    }
    func enrollments() throws -> [Enrollment] {
        lock.lock(); defer { lock.unlock() }
        return try readEnrollments()
    }
    // Caller holds lock. Reading legacy storage never writes or changes its bytes.
    private func readEnrollments() throws -> [Enrollment] {
        if !FileManager.default.fileExists(atPath: directory.path) { return [] }
        let dir = try directoryFD(create: false); defer { close(dir) }
        let fd = openat(dir, "password.envelope", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw Failure("Cannot read the YubiKey enrollment.") }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0, st.st_nlink == 1, st.st_size > 0, st.st_size <= 262144 else { throw Failure("Unsafe or oversized YubiKey enrollment.") }
        var data = Data(count: Int(st.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Incomplete YubiKey enrollment.") }
                offset += count
            }
        }
        struct Version: Decodable { let version: Int }
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).version
            if version == 1 {
                let envelope = try decoder.decode(Envelope.self, from: data)
                try envelope.validate()
                return [Enrollment(id: Enrollment.identifier(for: envelope.credential), name: "Original YubiKey", envelope: envelope)]
            }
            let collection = try decoder.decode(Collection.self, from: data)
            try collection.validate()
            return collection.enrollments
        } catch {
            throw Failure("Invalid local YubiKey enrollment storage. Enter your note password instead.")
        }
    }
    // Caller holds lock throughout atomic replacement, including its cancellation check.
    private func save(_ records: [Enrollment]) throws {
        let collection = Collection(version: 2, enrollments: records)
        try collection.validate()
        let data = try JSONEncoder().encode(collection)
        guard data.count <= 262144 else { throw Failure("YubiKey enrollment storage is too large.") }
        let dir = try directoryFD(create: true); defer { close(dir) }
        var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let name = UUID().uuidString + ".tmp"
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot save YubiKey enrollment.") }
        defer { close(fd); unlinkat(dir, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Saving YubiKey enrollment failed. Previous enrollments were kept.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(dir, name, dir, "password.envelope") == 0 else { throw Failure("Saving YubiKey enrollment failed. Previous enrollments were kept.") }
        _ = fsync(dir)
    }
    func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        let records = try readEnrollments()
        guard records.contains(where: { $0.id == id }) else { throw Failure("This YubiKey enrollment is no longer available.") }
        try save(records.filter { $0.id != id })
    }
    func rename(id: String, name: String) throws {
        let name = try Self.validName(name)
        lock.lock(); defer { lock.unlock() }
        var records = try readEnrollments()
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure("This YubiKey enrollment is no longer available.") }
        let record = records[index]
        records[index] = Enrollment(id: record.id, name: name, envelope: record.envelope)
        try save(records)
    }
}
