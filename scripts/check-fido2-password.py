#!/usr/bin/env python3
"""Test production envelope crypto/storage using synthetic secrets; never touch hardware."""
from pathlib import Path
import subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
fixture=r'''
import Foundation
import CryptoKit
func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
func fails(_ body: () throws -> Void) { do { try body(); fatalError("Expected failure") } catch {} }
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func writePrivate(_ data: Data, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
func collectionData(_ records: [FIDO2PasswordProvider.Enrollment], version: Int = 2) throws -> Data {
    struct Document: Encodable { let version: Int; let enrollments: [FIDO2PasswordProvider.Enrollment] }
    return try JSONEncoder().encode(Document(version: version, enrollments: records))
}
let store = FIDO2PasswordProvider(directory: base.appendingPathComponent("private"))
let id = Data(repeating: 1, count: 64), pk = Data(repeating: 2, count: 64), salt = Data(repeating: 3, count: 32), secret = Data(repeating: 4, count: 32)
let password = "Test only — not a real password"
let envelope = try FIDO2PasswordProvider.seal(password: password, credential: id, publicKey: pk, salt: salt, secret: secret)
let legacyID = FIDO2PasswordProvider.Enrollment.identifier(for: id)
expect(try FIDO2PasswordProvider.open(envelope, secret: secret) == password, "roundtrip")
let another = try FIDO2PasswordProvider.seal(password: password, credential: id, publicKey: pk, salt: salt, secret: secret)
expect(envelope.ciphertext != another.ciphertext, "nonce reused")
fails { _ = try FIDO2PasswordProvider.open(envelope, secret: Data(repeating: 5, count: 32)) }
for index in [0, envelope.ciphertext.count - 1] {
    var tampered = envelope.ciphertext; tampered[index] ^= 1
    let e = FIDO2PasswordProvider.Envelope(version: 1, credential: id, publicKey: pk, salt: salt, ciphertext: tampered)
    fails { _ = try FIDO2PasswordProvider.open(e, secret: secret) }
}
for changed in ["credential", "publicKey", "salt", "version"] {
    let e = FIDO2PasswordProvider.Envelope(version: changed == "version" ? 2 : 1,
        credential: changed == "credential" ? Data(repeating: 7, count: 64) : id,
        publicKey: changed == "publicKey" ? Data(repeating: 7, count: 64) : pk,
        salt: changed == "salt" ? Data(repeating: 7, count: 32) : salt, ciphertext: envelope.ciphertext)
    fails { _ = try FIDO2PasswordProvider.open(e, secret: secret) }
}
let file = base.appendingPathComponent("private/password.envelope")
let legacyBytes = try JSONEncoder().encode(envelope)
try writePrivate(legacyBytes, to: file)
let legacy = try store.enrollments()
expect(legacy.count == 1 && legacy[0].name == "Original YubiKey" && legacy[0].id == legacyID, "legacy migration metadata")
expect(try Data(contentsOf: file) == legacyBytes, "read mutated legacy storage")
expect(try store.load()?.ciphertext == envelope.ciphertext, "compatibility load")
var unlockPrompts = 0
expect(try store.unlock(id: legacyID, pin: "correct-pin", ticket: store.ticket(), beforeActivation: { unlockPrompts += 1; return true }) == password, "legacy unlock")
expect(unlockPrompts == 1, "unlock prompt count")
var steps = [Int]()
try store.enroll(name: "  Backup YubiKey  ", password: "backup-password", pin: "correct-pin", ticket: store.ticket(), beforeActivation: { steps.append($0); return true })
expect(steps == [1, 2, 3], "three explicit enrollment activations")
let added = try store.enrollments()
expect(added.count == 2 && added[0].name == "Original YubiKey" && added[1].name == "Backup YubiKey", "addition replaced legacy or failed name normalization")
expect(added[0].envelope.ciphertext == envelope.ciphertext && added[0].id == legacyID, "addition altered legacy envelope")
let backupID = added[1].id
expect(backupID != legacyID, "credentials not distinct")
func unlock(_ provider: FIDO2PasswordProvider, _ id: String, pin: String = "correct-pin") throws -> String {
    try provider.unlock(id: id, pin: pin, ticket: provider.ticket(), beforeActivation: { true })
}
expect(try unlock(store, legacyID) == password, "first record lost its password")
expect(try unlock(store, backupID) == "backup-password", "selected record unlock failed")
fails { _ = try FIDO2PasswordProvider.open(added[1].envelope, secret: secret) }
let savedText = String(data: try Data(contentsOf: file), encoding: .utf8)!
expect(!savedText.contains(password) && !savedText.contains("backup-password") && !savedText.contains("correct-pin"), "plaintext persisted")
try store.rename(id: backupID, name: "Spare key")
let renamed = try store.enrollments()
expect(renamed[1].name == "Spare key" && renamed[1].envelope.ciphertext == added[1].envelope.ciphertext, "rename changed encrypted envelope")
expect(renamed[0].name == "Original YubiKey", "rename affected other key")
let stable = try Data(contentsOf: file)
// Names identify picker choices, so a case-only duplicate must fail before USB access.
cn_test_reset_counts()
fails { try store.enroll(name: "  ORIGINAL yubikey  ", password: "new", pin: "correct-pin", ticket: store.ticket(), beforeActivation: { _ in fatalError("duplicate name activated hardware") }) }
fails { try store.rename(id: backupID, name: "original YUBIKEY") }
expect(cn_test_create_calls() == 0 && cn_test_secret_calls() == 0, "duplicate name accessed hardware")
expect(try Data(contentsOf: file) == stable, "duplicate name changed store")
for name in ["", "   ", String(repeating: "x", count: 81), "key\nname", "key\0name", "x" + String(repeating: "\u{301}", count: 200)] {
    fails { try store.rename(id: backupID, name: name) }
    fails { try store.enroll(name: name, password: "new", pin: "correct-pin", ticket: store.ticket(), beforeActivation: { _ in fatalError("invalid name touched hardware") }) }
    expect(try Data(contentsOf: file) == stable, "invalid name changed store")
}
// Wrong IDs, malformed PINs, and stale tickets never invoke a hardware activation.
fails { _ = try store.unlock(id: "missing", pin: "correct-pin", ticket: store.ticket(), beforeActivation: { fatalError("unknown record activated") }) }
for pin in ["", String(repeating: "x", count: 64), "correct-pin\0suffix"] {
    fails { try store.enroll(name: "Test", password: "new", pin: pin, ticket: store.ticket(), beforeActivation: { _ in fatalError("invalid PIN activated") }) }
    fails { _ = try store.unlock(id: legacyID, pin: pin, ticket: store.ticket(), beforeActivation: { fatalError("invalid PIN activated") }) }
}
let stale = store.ticket(); store.cancel()
fails { try store.enroll(name: "Test", password: "new", pin: "correct-pin", ticket: stale, beforeActivation: { _ in fatalError("stale transaction activated") }) }
// Cancellation before each activation stops the next native operation and never commits.
for step in 1...3 {
    for invalidateTicket in [false, true] {
        cn_test_reset_counts()
        var observed = [Int]()
        fails {
            try store.enroll(name: "Canceled", password: "new", pin: "correct-pin", ticket: store.ticket(), beforeActivation: {
                observed.append($0)
                if $0 == step {
                    if invalidateTicket { store.cancel(); return true }
                    return false
                }
                return true
            })
        }
        expect(observed == Array(1...step), "activation ordering")
        expect(cn_test_create_calls() == (step > 1 ? 1 : 0), "credential operation after cancellation")
        expect(cn_test_secret_calls() == (step > 2 ? 1 : 0), "private operation after cancellation")
        expect(try Data(contentsOf: file) == stable, "cancellation changed existing collection")
    }
}
for pin in ["create-fails", "derive-fails", "verification-fails", "duplicate-legacy"] {
    fails { try store.enroll(name: "Failed", password: "new", pin: pin, ticket: store.ticket(), beforeActivation: { _ in true }) }
    expect(try Data(contentsOf: file) == stable, "failed enrollment changed existing collection")
}
// Cancel during the final native call, exercising the commit lock's ticket check.
let cancelStore = store
cn_test_set_cancel_callback({ cancelStore.cancel() })
fails { try store.enroll(name: "Late cancellation", password: "new", pin: "cancel-during-verification", ticket: store.ticket(), beforeActivation: { _ in true }) }
expect(try Data(contentsOf: file) == stable, "late cancellation committed enrollment")
cn_test_reset_counts()
fails { _ = try store.unlock(id: legacyID, pin: "correct-pin", ticket: store.ticket(), beforeActivation: { false }) }
expect(cn_test_secret_calls() == 0, "canceled unlock invoked hardware")
fails { _ = try unlock(store, legacyID, pin: "incorrect") }
// A rename completed while the new key is being verified survives its later commit.
try store.enroll(name: "Third key", password: "third-password", pin: "correct-pin", ticket: store.ticket(), beforeActivation: { step in
    if step == 3 { try! store.rename(id: backupID, name: "Renamed while adding") }
    return true
})
let three = try store.enrollments()
expect(three.count == 3 && three[1].name == "Renamed while adding", "commit overwrote concurrent rename")
let removalTicket = store.ticket()
try store.remove(id: backupID)
expect(!store.current(removalTicket), "removal did not cancel pending operations")
let two = try store.enrollments()
expect(two.count == 2 && two[0].id == legacyID && two[1].id == three[2].id, "remove deleted wrong record")
expect(try unlock(store, two[1].id) == "third-password", "remove corrupted surviving envelope")
fails { _ = try unlock(store, backupID) }
try store.remove(id: two[1].id)
try store.remove(id: legacyID)
expect(try store.enrollments().isEmpty && store.load() == nil, "last removal failed")
// Malformed stores fail closed without changing the existing bytes.
let goodRecord = FIDO2PasswordProvider.Enrollment(id: legacyID, name: "Valid key", envelope: envelope)
var invalidRecords = [Data]()
invalidRecords.append(try collectionData([goodRecord], version: 3))
invalidRecords.append(try collectionData([goodRecord, goodRecord]))
invalidRecords.append(try collectionData([goodRecord, .init(id: added[1].id, name: "VALID KEY", envelope: added[1].envelope)]))
invalidRecords.append(try collectionData(Array(repeating: goodRecord, count: 17)))
invalidRecords.append(try collectionData([.init(id: "wrong", name: "Valid key", envelope: envelope)]))
invalidRecords.append(try collectionData([.init(id: legacyID, name: "", envelope: envelope)]))
invalidRecords.append(try collectionData([.init(id: legacyID, name: String(repeating: "x", count: 81), envelope: envelope)]))
invalidRecords.append(Data("{invalid".utf8))
invalidRecords.append(Data(repeating: 0, count: 262145))
for bytes in invalidRecords {
    try writePrivate(bytes, to: file)
    fails { _ = try store.enrollments() }
    fails { try store.enroll(name: "Addition", password: "new", pin: "correct-pin", ticket: store.ticket(), beforeActivation: { _ in fatalError("malformed store activated hardware") }) }
    expect(try Data(contentsOf: file) == bytes, "malformed storage mutated")
}
// Full valid stores are readable but cannot add a seventeenth key.
let full = try (1...16).map { value -> FIDO2PasswordProvider.Enrollment in
    let credential = Data(repeating: UInt8(value), count: 64)
    let wrapped = try FIDO2PasswordProvider.seal(password: password, credential: credential, publicKey: pk, salt: salt, secret: secret)
    return .init(id: FIDO2PasswordProvider.Enrollment.identifier(for: credential), name: "Key \(value)", envelope: wrapped)
}
try writePrivate(collectionData(full), to: file)
expect(try store.enrollments().count == 16, "full valid collection unreadable")
fails { try store.enroll(name: "Seventeenth", password: "new", pin: "correct-pin", ticket: store.ticket(), beforeActivation: { _ in fatalError("full store activated hardware") }) }
try FileManager.default.removeItem(at: file)
try FileManager.default.createSymbolicLink(at: file, withDestinationURL: base.appendingPathComponent("missing"))
fails { _ = try store.enrollments() }
try FileManager.default.removeItem(at: file)
try writePrivate(legacyBytes, to: file)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
fails { _ = try store.enrollments() }
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
let hardlink = base.appendingPathComponent("hardlink")
try FileManager.default.linkItem(at: file, to: hardlink)
fails { _ = try store.enrollments() }
try FileManager.default.removeItem(at: hardlink)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.deletingLastPathComponent().path)
fails { _ = try store.enrollments() }
print("PASS: legacy read-only migration, independent multi-key envelopes, named selection/rename/removal, concurrent rename preservation, three explicit activation gates, cancellation at every gate and final commit, native failures, duplicate credential/name rejection before hardware access, PIN NUL rejection, authenticated metadata, private storage and malformed/oversized/overfull/symlink/hardlink/permission rejection")
'''
# No real device code is linked; every synthetic credential has a distinct secret.
stub=r'''
#include "FIDO2Bridge.h"
#include <stdlib.h>
#include <string.h>
static unsigned char next_id=1;
static int creates=0, secrets=0, transaction_secrets=0;
static void (*cancel_callback)(void)=NULL;
void cn_test_reset_counts(void){creates=0;secrets=0;}
int cn_test_create_calls(void){return creates;}
int cn_test_secret_calls(void){return secrets;}
void cn_test_set_cancel_callback(void (*callback)(void)){cancel_callback=callback;}
int cn_fido_path(char *p,size_t c){strcpy(p,"ioreg://fixture");return 0;}
int cn_fido_create(const char*a,const char*b,uint8_t*c,size_t*d,uint8_t*e){
 creates++;transaction_secrets=0;
 if(!strcmp(b,"create-fails"))return 1;
 unsigned char credential=!strcmp(b,"duplicate-legacy")?1:++next_id;
 memset(c,credential,64);*d=64;memset(e,2,64);return 0;
}
int cn_fido_secret(const char*a,const char*b,const uint8_t*c,size_t d,const uint8_t*e,const uint8_t*f,uint8_t*g){
 secrets++;transaction_secrets++;
 if(!strcmp(b,"incorrect") || !strcmp(b,"derive-fails"))return 49;
 memset(g,(!strcmp(b,"verification-fails") && transaction_secrets==2)?255:c[0]+3,32);
 if(!strcmp(b,"cancel-during-verification") && transaction_secrets==2 && cancel_callback)cancel_callback();
 return 0;
}
const char *cn_fido_error(int s){return "test error";}
void cn_fido_wipe(void *p,size_t n){volatile unsigned char *b=p;while(n--)*b++=0;}
'''
with tempfile.TemporaryDirectory(prefix='consolinotes-fido-test-') as tmp:
 d=Path(tmp)
 (d/'main.swift').write_text(fixture)
 (d/'test-bridge.h').write_text('#include \"' + str(ROOT/'FSNotesCore/FIDO2/FIDO2Bridge.h') + '\"\nvoid cn_test_reset_counts(void);\nint cn_test_create_calls(void);\nint cn_test_secret_calls(void);\nvoid cn_test_set_cancel_callback(void (*callback)(void));\n')
 (d/'stub.c').write_text(stub)
 subprocess.run(['xcrun','clang','-I'+str(ROOT/'FSNotesCore/FIDO2'),'-c',str(d/'stub.c'),'-o',str(d/'stub.o')],check=True)
 subprocess.run(['xcrun','swiftc','-module-cache-path',str(d/'modules'),'-import-objc-header',str(d/'test-bridge.h'),str(ROOT/'FSNotesCore/FIDO2/FIDO2PasswordProvider.swift'),str(d/'main.swift'),str(d/'stub.o'),'-o',str(d/'test')],check=True)
 subprocess.run([str(d/'test'),str(d)],check=True)
