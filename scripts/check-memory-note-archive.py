#!/usr/bin/env python3
"""Exercise native in-memory ZIP decoding, bounded expansion and atomic publication."""
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile
ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / 'build/DerivedData/Build/Products/Release'
MODULES = ROOT / 'build/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps'
SOURCE = r'''
import Foundation
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
func fails(_ message: String, _ block: () throws -> Void) { do { try block(); fatalError(message) } catch {} }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func archive(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name + ".zip")) }
let expected = ["info.json": Data(#"{"version":2,"type":"net.daringfireball.markdown"}"#.utf8), "text.md": Data("secret marker".utf8), "assets/空 image%.png": Data([0,1,2,3])]
let encoded = try MemoryNoteArchive.encode(expected)
expect(try! MemoryNoteArchive.decode(encoded) == expected, "Stored memory archive did not roundtrip")
for name in ["compressed", "valid64"] {
 expect(try! MemoryNoteArchive.decode(archive(name)) == expected, "Existing compressed/ZIP64 compatibility failed")
}
for name in ["symlink", "special", "traversal", "absolute", "backslash", "collision", "duplicate", "badcrc", "badlength", "nul", "invalidutf8"] {
 fails("Malformed archive accepted: " + name) { _ = try MemoryNoteArchive.decode(archive(name)) }
}
for name in ["oversize", "zip64", "deep", "implicit"] {
 fails("Budget bypass: " + name) { _ = try MemoryNoteArchive.decode(archive(name), limits: .init(bytes: 32, entries: 4, depth: 3)) }
}
var checks = 0
fails("Mid-stream cancellation ignored") {
 _ = try MemoryNoteArchive.decode(archive("cancel"), isCancelled: { checks += 1; return checks >= 5 })
}
expect(checks >= 5, "Cancellation fixture missed streaming path")
fails("Writer accepted traversal") { _ = try MemoryNoteArchive.encode(["../secret": Data()]) }
fails("Writer accepted directory/file collision") { _ = try MemoryNoteArchive.encode(["a": Data(), "a/b": Data()]) }
fails("Writer ignored cancellation") { _ = try MemoryNoteArchive.encode(expected, isCancelled: { true }) }
let workspace = try MemoryNoteWorkspace(entries: expected)
expect(workspace.path(for: URL(string: "consolinotes-memory://other/assets/x")!) == nil, "Foreign opaque URL accepted")
let destination = root.appendingPathComponent("published.etp")
let original = Data("original ciphertext".utf8)
try original.write(to: destination)
enum Failure: Error { case injected }
fails("Failed readback published ciphertext") {
 try EncryptedNoteJournal.atomicWrite(Data("candidate ciphertext".utf8), to: destination, replacing: true, verify: { _ in throw Failure.injected })
}
expect(try! Data(contentsOf: destination) == original, "Readback failure changed original")
var cancelled = false
fails("Late cancellation published ciphertext") {
 try EncryptedNoteJournal.atomicWrite(Data("candidate ciphertext".utf8), to: destination, replacing: true, isCancelled: { cancelled }) { _ in cancelled = true }
}
expect(try! Data(contentsOf: destination) == original, "Late cancellation changed original")
fails("Exclusive write overwrote original") { try EncryptedNoteJournal.atomicWrite(Data(), to: destination, replacing: false) }
let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".") }
expect(leftovers.isEmpty, "Failed publication left staging file")
print("PASS: memory stored/compressed/ZIP64 roundtrips, corruption/link/path/CRC/actual-byte/depth/entry limits, streaming cancellation, atomic readback failure/late-cancellation preservation and cleanup")
'''
with tempfile.TemporaryDirectory(prefix='consolinotes-memory-archive-') as temporary:
    work = Path(temporary)
    expected = {'info.json': b'{"version":2,"type":"net.daringfireball.markdown"}', 'text.md': b'secret marker', 'assets/空 image%.png': bytes([0,1,2,3])}
    with zipfile.ZipFile(work/'compressed.zip', 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, body in expected.items(): archive.writestr(name, body)
    with zipfile.ZipFile(work/'valid64.zip', 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, body in expected.items():
            with archive.open(name, 'w', force_zip64=True) as member: member.write(body)
    cases = {
        'traversal': [('../secret', b'x')], 'absolute': [('/secret', b'x')], 'backslash': [('a\\b', b'x')],
        'collision': [('a/b', b'x'), ('a', b'x')], 'duplicate': [('a', b'x'), ('a', b'y')],
        'oversize': [('a', b'x'*64)], 'deep': [('a/b/c/d/e', b'x')],
        'implicit': [('a/b/c', b'x'), ('d/e/f', b'x')],
        'badcrc': [('a', b'first')], 'badlength': [('a', b'first')],
        'nul': [('abc', b'x')], 'invalidutf8': [('abc', b'x')], 'cancel': [('large', b'x'*200_000)],
    }
    for name, entries in cases.items():
        with zipfile.ZipFile(work/(name+'.zip'), 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path, payload in entries: archive.writestr(path, payload)
    for name, mode in [('symlink',0o120777),('special',0o010600)]:
        with zipfile.ZipFile(work/(name+'.zip'), 'w') as archive:
            info = zipfile.ZipInfo('entry'); info.create_system=3; info.external_attr=mode<<16
            archive.writestr(info,b'target')
    for name in ['badcrc','badlength','nul','invalidutf8']:
        data=bytearray((work/(name+'.zip')).read_bytes()); central=data.index(b'PK\x01\x02')
        if name=='badcrc': data[central+16]^=255
        if name=='badlength': data[central+24:central+28]=struct.pack('<I',1)
        if name=='nul': data[central+46+1]=0
        if name=='invalidutf8': data[central+46+1]=255
        (work/(name+'.zip')).write_bytes(data)
    with zipfile.ZipFile(work/'zip64.zip', 'w') as archive:
        info=zipfile.ZipInfo('large'); info.extra=struct.pack('<HHQQ',1,16,0x100000000,1)
        archive.writestr(info,b'x')
    data=bytearray((work/'zip64.zip').read_bytes()); central=data.index(b'PK\x01\x02')
    data[central+24:central+28]=struct.pack('<I',0xffffffff); (work/'zip64.zip').write_bytes(data)
    source=work/'main.swift'; source.write_text(SOURCE); executable=work/'test'
    subprocess.run(['swiftc','-module-cache-path',str(work/'modules'),'-I',str(PRODUCTS),
        '-Xcc','-fmodule-map-file='+str(MODULES/'ZipArchive.modulemap'),
        '-import-objc-header',str(ROOT/'FSNotesCore/PrivateNoteArchiveBridge.h'),
        *[str(ROOT/'FSNotesCore'/f) for f in ['PrivateWorkingDirectory.swift','PrivateNoteArchive.swift','MemoryNoteArchive.swift','MemoryNoteWorkspace.swift','EncryptedNoteCodec.swift','EncryptedNoteJournal.swift']],
        str(source),str(PRODUCTS/'ZipArchive.o'),str(PRODUCTS/'RNCryptor.o'),'-lz','-liconv','-framework','Security','-o',str(executable)],check=True)
    subprocess.run([str(executable),str(work)],check=True)
