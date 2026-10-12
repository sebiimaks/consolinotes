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
        let protection: Protection?
        init(version: Int, credential: Data, publicKey: Data, salt: Data, ciphertext: Data, protection: Protection? = nil) {
            self.version = version; self.credential = credential; self.publicKey = publicKey
            self.salt = salt; self.ciphertext = ciphertext; self.protection = protection
        }
        var aad: Data {
            let base = Data("consolinotes.fido2.envelope.v\(version)\0".utf8) + credential + publicKey + salt
            guard let protection = protection else { return base }
            return base + Data((protection.group + "\0" + protection.mode.rawValue).utf8)
        }
        func validate() throws {
            guard (version == 1 && protection == nil) || (version == 2 && protection != nil),
                  (1...1024).contains(credential.count), publicKey.count == 64,
                  salt.count == 32, (29...8192).contains(ciphertext.count) else { throw Failure("Invalid YubiKey enrollment. Enter your note password instead.") }
            try protection?.validate()
        }
    }
    struct Protection: Codable, Equatable {
        enum Mode: String, Codable { case password, hardwareWithRecovery }
        let group: String
        let mode: Mode
        func validate() throws {
            guard UUID(uuidString: group)?.uuidString == group else { throw Failure("Invalid password-group identifier.") }
        }
    }
    /// A short-lived witness that the candidate was checked before USB access.
    /// It contains no reusable password hash and is never serialized.
    struct PasswordProof {
        fileprivate let nonce: Data
        fileprivate let digest: Data
        fileprivate let protection: Protection
        fileprivate func matches(_ password: String) -> Bool {
            Data(SHA256.hash(data: nonce + Data(password.utf8))) == digest
        }
    }
    static func verifyPassword(_ password: String, group: String? = nil,
                               using verify: (String) -> Bool) throws -> PasswordProof {
        guard !password.isEmpty, password.utf8.count <= 4096, verify(password) else {
            throw Failure("That password did not unlock the selected encrypted note. No YubiKey enrollment was created.")
        }
        return try proof(password, protection: Protection(group: group ?? UUID().uuidString, mode: .password))
    }
    static func verifyBackupPassword(_ password: String, of enrollment: Enrollment,
                                     using verify: (String) -> Bool) throws -> PasswordProof {
        _ = try verifyPassword(password, using: verify)
        return try proof(password, protection: enrollment.envelope.protection
            ?? Protection(group: UUID().uuidString, mode: .password))
    }
    private static func proof(_ password: String, protection: Protection) throws -> PasswordProof {
        try protection.validate()
        let nonce = try random(32)
        return PasswordProof(nonce: nonce, digest: Data(SHA256.hash(data: nonce + Data(password.utf8))), protection: protection)
    }
    /// The random note secret is also the offline recovery password. It is only
    /// exposed during setup and must be read back before a hardware enrollment
    /// can qualify for an encryption-secret change.
    final class StrongProtectionPlan {
        private let lock = NSLock()
        private var secret: String
        var recoverySecret: String { lock.lock(); defer { lock.unlock() }; return secret }
        private let protection = Protection(group: UUID().uuidString, mode: .hardwareWithRecovery)
        private var verificationBox: Data
        private var challenge: Data
        init() throws {
            var random = try FIDO2PasswordProvider.random(32)
            defer { random.resetBytes(in: 0..<random.count) }
            secret = "CN1-" + stride(from: 0, to: random.count, by: 4).map { offset in
                random[offset..<offset + 4].map { String(format: "%02X", $0) }.joined()
            }.joined(separator: "-")
            challenge = try FIDO2PasswordProvider.random(32)
            verificationBox = try AES.GCM.seal(challenge, using: SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))).combined!
        }
        func verifyRecovery(_ entered: String) throws -> PasswordProof {
            lock.lock(); defer { lock.unlock() }
            guard !secret.isEmpty, entered.utf8.count <= 4096,
                  let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: verificationBox), using: SymmetricKey(data: SHA256.hash(data: Data(entered.utf8)))),
                  opened == challenge else { throw Failure("The recovery password did not match. Re-enter the copy you saved offline before changing this note.") }
            return try FIDO2PasswordProvider.proof(entered, protection: protection)
        }
        func clear() {
            lock.lock(); defer { lock.unlock() }
            secret = ""
            challenge.resetBytes(in: 0..<challenge.count)
            verificationBox.resetBytes(in: 0..<verificationBox.count)
        }
        deinit { clear() }
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
    static func seal(password: String, credential: Data, publicKey: Data, salt: Data, secret: Data, protection: Protection? = nil) throws -> Envelope {
        guard !password.isEmpty, password.utf8.count <= 4096, secret.count == 32 else { throw Failure("Invalid password or hardware secret.") }
        let metadata = Envelope(version: protection == nil ? 1 : 2, credential: credential, publicKey: publicKey, salt: salt, ciphertext: Data(), protection: protection)
        let box = try AES.GCM.seal(Data(password.utf8), using: key(secret: secret, salt: salt), authenticating: metadata.aad)
        let envelope = Envelope(version: metadata.version, credential: credential, publicKey: publicKey, salt: salt, ciphertext: box.combined!, protection: protection)
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
    @discardableResult
    func enroll(name: String, password: String, proof: PasswordProof, pin: String, ticket: UInt64,
                beforeActivation: @escaping (Int) -> Bool) throws -> Enrollment {
        guard proof.matches(password) else { throw Failure("The verified password changed. Verify it against the selected note again.") }
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
        let envelope = try Self.seal(password: password, credential: metadata.credential, publicKey: metadata.publicKey, salt: metadata.salt, secret: secret, protection: proof.protection)
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
        let record = Enrollment(id: Enrollment.identifier(for: envelope.credential), name: name, envelope: envelope)
        records.append(record)
        try save(records)
        return record
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

    private struct PortableCollection: Codable {
        let format: String
        let version: Int
        let enrollments: [Enrollment]
        func validate() throws {
            guard format == "consolinotes-yubikey-enrollments", version == 1 else {
                throw Failure("This is not a supported consolinotes YubiKey backup.")
            }
            try Collection(version: 2, enrollments: enrollments).validate()
        }
    }
    struct ImportSummary {
        let added: Int
        let alreadyPresent: Int
    }
    func exportData() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let document = PortableCollection(format: "consolinotes-yubikey-enrollments", version: 1, enrollments: try readEnrollments())
        try document.validate()
        let data = try JSONEncoder().encode(document)
        guard data.count <= 262144 else { throw Failure("The YubiKey backup is too large.") }
        return data
    }
    func mergeImport(_ data: Data, ticket: UInt64) throws -> ImportSummary {
        guard !data.isEmpty, data.count <= 262144 else { throw Failure("This YubiKey backup is empty or exceeds the 256 KB limit.") }
        let document: PortableCollection
        do { document = try JSONDecoder().decode(PortableCollection.self, from: data); try document.validate() }
        catch { throw Failure("The YubiKey backup is invalid. No enrollments were changed.") }
        lock.lock(); defer { lock.unlock() }
        guard ticket == generation else { throw Failure("Canceled.") }
        var records = try readEnrollments()
        var skipped = 0, added = 0
        for incoming in document.enrollments {
            if let existing = records.first(where: { $0.id == incoming.id }) {
                // A backup may predate a local rename. Keep the local name, but
                // never silently replace a credential's encrypted password.
                guard existing.envelope.version == incoming.envelope.version,
                      existing.envelope.credential == incoming.envelope.credential,
                      existing.envelope.publicKey == incoming.envelope.publicKey,
                      existing.envelope.salt == incoming.envelope.salt,
                      existing.envelope.ciphertext == incoming.envelope.ciphertext,
                      existing.envelope.protection == incoming.envelope.protection else {
                    throw Failure("This backup conflicts with an existing enrollment. Nothing was replaced. Keep both backups and test the current enrollment before deciding which record to retain.")
                }
                skipped += 1
                continue
            }
            guard !records.contains(where: { Self.nameKey($0.name) == Self.nameKey(incoming.name) }) else {
                throw Failure("An imported key name is already in use. Rename the local enrollment first, then import again. Nothing was changed.")
            }
            records.append(incoming); added += 1
        }
        try Collection(version: 2, enrollments: records).validate()
        if added > 0 { try save(records) }
        return ImportSummary(added: added, alreadyPresent: skipped)
    }
    func importFile(_ url: URL, ticket: UInt64) throws -> ImportSummary {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot open this YubiKey backup.") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0, status.st_size <= 262144 else { throw Failure("This is not a regular YubiKey backup within the 256 KB limit.") }
        var bytes = Data(count: Int(status.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw Failure("The YubiKey backup could not be read completely.") }
                offset += amount
            }
        }
        var extra: UInt8 = 0
        guard read(fd, &extra, 1) == 0 else { throw Failure("The YubiKey backup changed while being read.") }
        return try mergeImport(bytes, ticket: ticket)
    }
    func exportFile(_ url: URL, ticket: UInt64) throws {
        let data = try exportData()
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure("Cannot access the chosen backup folder.") }
        defer { close(parent) }
        let temporary = ".consolinotes-yubikey-" + UUID().uuidString + ".tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot create the YubiKey backup.") }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw Failure("The YubiKey backup could not be written.") }
                offset += amount
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard ticket == generation, fsync(fd) == 0 else { throw Failure("The YubiKey backup was cancelled or could not be saved.") }
        // The Save panel authorizes replacement of an ordinary chosen file.
        // Reject links, special files and multiply linked destinations.
        var existing = stat()
        let result = fstatat(parent, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW)
        guard (result != 0 && errno == ENOENT) || (result == 0 && existing.st_mode & S_IFMT == S_IFREG && existing.st_nlink == 1 && existing.st_uid == getuid()) else {
            throw Failure("The chosen backup destination is not a safe ordinary file.")
        }
        guard renameat(parent, temporary, parent, url.lastPathComponent) == 0 else { throw Failure("The YubiKey backup could not be saved.") }
        _ = fsync(parent)
    }
}
