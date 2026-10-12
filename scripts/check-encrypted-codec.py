#!/usr/bin/env python3
"""Check the production codec against independent Node/OpenSSL fixtures.

Uses synthetic bytes only. Requires a local app build for pinned RNCryptor.
Node is a development/test dependency, never an application dependency.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / "build/DerivedData/Build/Products/Release"
NODE = shutil.which("node")
if not NODE:
    raise SystemExit("Node.js is required for independent OpenSSL interoperability tests.")

REFERENCE = r'''
const c = require('node:crypto');
const password = 'Synthetic 🔐 password\u0000suffix';
const plain = Buffer.from('synthetic archive bytes\u0000with unicode: λ');
const salt = Buffer.from(Array.from({length: 32}, (_, i) => i));
const header = Buffer.concat([Buffer.from('CNOTEENC'), Buffer.from([1,1,1,0]), Buffer.from([0,9,39,192]), salt]);
const key = c.pbkdf2Sync(password, salt, 600000, 32, 'sha256');
const nonce = Buffer.alloc(12, 17);
const cipher = c.createCipheriv('aes-256-gcm', key, nonce);
cipher.setAAD(header);
const ciphertext = Buffer.concat([cipher.update(plain), cipher.final()]);
const modern = Buffer.concat([header, nonce, ciphertext, cipher.getAuthTag()]);
const encSalt = salt.subarray(0,8), macSalt = salt.subarray(8,16), iv = salt.subarray(0,16);
const legacyHeader = Buffer.concat([Buffer.from([3,1]), encSalt, macSalt, iv]);
const legacyCipher = c.createCipheriv('aes-256-cbc', c.pbkdf2Sync(password, encSalt, 10000, 32, 'sha1'), iv);
const legacyBody = Buffer.concat([legacyCipher.update(plain), legacyCipher.final()]);
const authenticated = Buffer.concat([legacyHeader, legacyBody]);
const legacy = Buffer.concat([authenticated, c.createHmac('sha256', c.pbkdf2Sync(password, macSalt, 10000, 32, 'sha1')).update(authenticated).digest()]);
process.stdout.write(JSON.stringify({password, plain:plain.toString('base64'), modern:modern.toString('base64'), legacy:legacy.toString('base64')}));
'''

VERIFY = r'''
const c = require('node:crypto'), fs = require('node:fs'), assert = require('node:assert/strict');
const fixture = JSON.parse(fs.readFileSync(process.argv[1]));
const encrypted = fs.readFileSync(process.argv[2]);
const header = encrypted.subarray(0,48);
assert.equal(header.subarray(0,8).toString(), 'CNOTEENC');
assert.equal(header.readUInt32BE(12), 600000);
const key = c.pbkdf2Sync(fixture.password, header.subarray(16,48), 600000, 32, 'sha256');
const decipher = c.createDecipheriv('aes-256-gcm', key, encrypted.subarray(48,60));
decipher.setAAD(header);
decipher.setAuthTag(encrypted.subarray(encrypted.length-16));
const plain = Buffer.concat([decipher.update(encrypted.subarray(60,-16)), decipher.final()]);
assert.deepEqual(plain, Buffer.from(fixture.plain, 'base64'));
console.log('PASS: independent OpenSSL decrypts the production Swift envelope');
'''

SWIFT = r'''
import Foundation
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError(message) }
}
func reject(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError(message) } catch {}
}
let values = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
let password = values["password"]!
let plain = Data(base64Encoded: values["plain"]!)!
let reference = Data(base64Encoded: values["modern"]!)!
let legacy = Data(base64Encoded: values["legacy"]!)!
let opened = try EncryptedNoteCodec.open(reference, password: password)
try expect(opened.data == plain && opened.session.format == .modern, "Independent AES-GCM/PBKDF2 vector did not open")
let old = try EncryptedNoteCodec.open(legacy, password: password)
try expect(old.data == plain && old.session.format == .legacy, "Independent legacy RNCryptor vector did not open")
let oldResaved = try EncryptedNoteCodec.seal(plain, session: old.session)
try expect(try EncryptedNoteCodec.format(of: oldResaved) == .legacy, "Legacy save silently migrated")
try expect(try EncryptedNoteCodec.open(oldResaved, password: password).data == plain, "Legacy save not readable")
let session = try EncryptedNoteCodec.makeSession(password: password)
let first = try EncryptedNoteCodec.seal(plain, session: session)
let second = try EncryptedNoteCodec.seal(plain, session: session)
try expect(first.prefix(48) == second.prefix(48), "Session unexpectedly changed key/salt")
try expect(first[48..<60] != second[48..<60], "A save reused its GCM nonce")
try expect(try EncryptedNoteCodec.open(first, password: password).data == plain, "New note round trip failed")
let nextSession = try EncryptedNoteCodec.makeSession(password: password)
let next = try EncryptedNoteCodec.seal(plain, session: nextSession)
try expect(first[16..<48] != next[16..<48], "Two new notes reused their salt")
try expect(try EncryptedNoteCodec.open(EncryptedNoteCodec.seal(Data(), session: session), password: password).data.isEmpty, "Empty payload not readable")
for offset in [0, 8, 9, 10, 11, 12, 15, 16, 47, 48, 59, 60, reference.count-1] {
    var altered = reference; altered[offset] ^= 1
    reject("Tampering accepted at byte \(offset)") { _ = try EncryptedNoteCodec.open(altered, password: password) }
}
for length in [0, 7, 8, 15, 47, 60, 75, reference.count-1] {
    reject("Truncated note accepted") { _ = try EncryptedNoteCodec.open(Data(reference.prefix(length)), password: password) }
}
reject("Wrong password accepted") { _ = try EncryptedNoteCodec.open(reference, password: "wrong") }
reject("Legacy wrong password accepted") { _ = try EncryptedNoteCodec.open(legacy, password: "wrong") }
reject("Empty password accepted") { _ = try EncryptedNoteCodec.makeSession(password: "") }
reject("Oversized password accepted") { _ = try EncryptedNoteCodec.makeSession(password: String(repeating: "x", count: 4097)) }
var excessive = reference; excessive.replaceSubrange(12..<16, with: [255,255,255,255])
reject("Unbounded KDF parameters accepted") { _ = try EncryptedNoteCodec.format(of: excessive) }
try first.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("PASS: independent modern/legacy vectors, no silent upgrade, fresh salts/nonces, tamper/truncation/password rejection, bounded parameters")
'''

with tempfile.TemporaryDirectory(prefix="consolinotes-codec-check-") as temporary:
    work = Path(temporary)
    fixture = work / "fixture.json"
    fixture.write_bytes(subprocess.check_output([NODE, "-e", REFERENCE]))
    main = work / "main.swift"
    main.write_text(SWIFT)
    executable = work / "codec-check"
    subprocess.run(["swiftc", "-module-cache-path", str(work / "modules"), "-I", str(PRODUCTS),
                    str(ROOT / "FSNotesCore/EncryptedNoteCodec.swift"), str(main), str(PRODUCTS / "RNCryptor.o"),
                    "-o", str(executable)], check=True)
    output = work / "encrypted.etp"
    subprocess.run([str(executable), str(fixture), str(output)], check=True)
    subprocess.run([NODE, "-e", VERIFY, str(fixture), str(output)], check=True)
