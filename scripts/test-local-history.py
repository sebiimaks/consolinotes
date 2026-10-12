#!/usr/bin/env python3
"""Exercise actual Swift Git wrappers and the local-only native library with synthetic repositories."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, help='Also reject legacy native crypto/network symbols in a built app')
args = parser.parse_args()

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORK = ROOT / 'Vendor/LocalGit2/libgit2.xcframework/macos-arm64_x86_64'
LIBRARY = FRAMEWORK / 'libgit2.a'
HEADERS = FRAMEWORK / 'Headers'

FIXTURE = r'''
import Foundation
import Cgit2
import CgitTestConfig

// UI-only collaborators are replaced; all repository/index/history code is real.
public class Project {
    var commitsCache = [String: [String]]()
    var gitStatus = ""
    func loadCommitsCache() {}
}
class AppDelegate { static var gitProgress: GitProgress? }
extension Date {
    func string(format: String) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = format
        return formatter.string(from: self)
    }
}
extension String { func startsWith(string: String) -> Bool { hasPrefix(string) } }
func expect(_ success: Bool, _ message: String) {
    if !success { fatalError(message) }
}

func exercise() throws {
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manager = RepositoryManager()
expect(history_test_isolate_config(root.path) == 0, "could not isolate library configuration")
var major: Int32 = 0, minor: Int32 = 0, patch: Int32 = 0
git_libgit2_version(&major, &minor, &patch)
expect([major, minor, patch] == [1, 9, 7], "wrong libgit2 version")
expect(git_libgit2_features() & Int32(GIT_FEATURE_HTTPS.rawValue | GIT_FEATURE_SSH.rawValue | GIT_FEATURE_HTTP_PARSER.rawValue) == 0, "network feature unexpectedly enabled")
for address in ["https://example.invalid/repo", "http://example.invalid/repo", "git://example.invalid/repo", "ssh://example.invalid/repo", "git@example.invalid:repo"] {
    var transport: UnsafeMutablePointer<git_transport>?
    expect(git_transport_new(&transport, nil, address) < 0 && transport == nil, "remote transport unexpectedly available")
}

let existing = try manager.openRepository(at: root.appendingPathComponent("existing"))
let existingCommit = try existing.head().targetCommit()
let existingEntry = try existingCommit.tree().entry(byPath: "prior.md")!
let existingBlobID = OID(withGitOid: git_tree_entry_id(existingEntry.pointer.pointee).pointee)
expect(try existing.blobLookup(oid: existingBlobID).rawContent == Data("existing packed history\n".utf8), "existing packed repo unreadable")

let folder = root.appendingPathComponent("new")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let signature = Signature(name: "Synthetic Test", email: "test@invalid.example")
let repo = try manager.initRepository(at: folder, signature: signature)
let name = "private # Ω.md"
let first = Data("first local revision\n".utf8), second = Data("second local revision\n".utf8)
let file = folder.appendingPathComponent(name)
try first.write(to: file)
try repo.add(path: name).get()
let firstCommit = try repo.head().index().createCommit(msg: "First", signature: signature)
try second.write(to: file)
let liveIndex = try repo.head().index()
expect(try liveIndex.add(path: "."), "app all-files staging failed")
try liveIndex.save()
let secondCommit = try liveIndex.createCommit(msg: "Second", signature: signature)
expect(firstCommit.oid.sha() != secondCommit.oid.sha(), "distinct changes need distinct commits")
let lockFile = folder.appendingPathComponent(".git/index.lock")
try Data("synthetic competing writer".utf8).write(to: lockFile)
var rejectedWrite = false
do { _ = try liveIndex.add(path: ".") } catch { rejectedWrite = true }
expect(rejectedWrite, "index write failure was silently ignored")
try FileManager.default.removeItem(at: lockFile)
try liveIndex.save()

let history = try FileHistoryIterator(repository: repo, path: name)
let revisions = history.walk()
expect(revisions.count >= 2, "file history lost revisions")
let firstEntry = try firstCommit.tree().entry(byPath: name)!
let firstBlobID = OID(withGitOid: git_tree_entry_id(firstEntry.pointer.pointee).pointee)
expect(try repo.blobLookup(oid: firstBlobID).rawContent == first, "previous content changed")
try repo.checkout(commit: firstCommit, path: name)
expect(try Data(contentsOf: file) == first, "restoring a revision failed")
// App repositories store encrypted note bytes as opaque files.
let encrypted = Data([0x43, 0x4e, 0x45, 0x54, 0, 0xff, 0xfe, 0x10])
try encrypted.write(to: folder.appendingPathComponent("locked.etp"))
try repo.add(path: "locked.etp").get()
_ = try repo.head().index().createCommit(msg: "Opaque encrypted file", signature: signature)
let reopened = try manager.openRepository(at: folder)
let entry = try reopened.head().targetCommit().tree().entry(byPath: "locked.etp")!
let blobID = OID(withGitOid: git_tree_entry_id(entry.pointer.pointee).pointee)
expect(try reopened.blobLookup(oid: blobID).rawContent == encrypted, "encrypted bytes changed")
print("PASS: current library, remote rejection, packed repo, commit/history/restore/reopen, index write failure and encrypted bytes")
}
try exercise()
'''


def run(args, **kwargs):
    subprocess.run([str(value) for value in args], check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='consolinotes-history-tests-') as tmp:
    work = Path(tmp)
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
    repo = work / 'existing'
    run(['git', 'init', '-q', repo], env=env)
    (repo / 'prior.md').write_text('existing packed history\n')
    run(['git', '-C', repo, 'add', 'prior.md'], env=env)
    run(['git', '-C', repo, '-c', 'user.name=Synthetic Test', '-c', 'user.email=test@invalid.example', 'commit', '-q', '-m', 'Prior revision'], env=env)
    run(['git', '-C', repo, 'gc', '--quiet'], env=env)
    module = work / 'module'
    module.mkdir()
    (module / 'isolate.h').write_text('int history_test_isolate_config(const char *path);\n')
    (work / 'isolate.c').write_text(r'''
#include <git2.h>
int history_test_isolate_config(const char *path) {
    if (git_libgit2_opts(GIT_OPT_SET_HOMEDIR, path) < 0) return -1;
    if (git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, GIT_CONFIG_LEVEL_SYSTEM, path) < 0) return -1;
    if (git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, GIT_CONFIG_LEVEL_GLOBAL, path) < 0) return -1;
    return git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, GIT_CONFIG_LEVEL_XDG, path);
}
''')
    for arch in ('arm64', 'x86_64'):
        run(['xcrun', 'clang', '-arch', arch, '-mmacosx-version-min=12.4', '-I', HEADERS, '-c', work / 'isolate.c', '-o', work / ('isolate-' + arch + '.o')])
    run(['xcrun', 'lipo', '-create', work / 'isolate-arm64.o', work / 'isolate-x86_64.o', '-output', work / 'isolate.o'])
    (module / 'module.modulemap').write_text('module CgitTestConfig { header "isolate.h" export * }\n' + 'module Cgit2 { header "' + str(HEADERS / 'git2.h') + '"\nheader "' + str(HEADERS / 'git2/sys/transport.h') + '"\nexport * }\n')
    (work / 'main.swift').write_text(FIXTURE)
    sources = sorted((ROOT / 'FSNotesCore/Git').rglob('*.swift'))
    compile_args = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', platform.machine() + '-apple-macosx12.4', '-I', module, '-I', HEADERS, '-module-cache-path', work / 'cache', *sources, work / 'main.swift', work / 'isolate.o', '-Xlinker', '-force_load', '-Xlinker', LIBRARY, '-lz', '-liconv', '-o', work / 'history-tests']
    run(compile_args)
    run([work / 'history-tests', work], env=env)
    other = 'x86_64' if platform.machine() == 'arm64' else 'arm64'
    cross_args = list(compile_args)
    cross_args[cross_args.index('-target') + 1] = other + '-apple-macosx12.4'
    cross_args[-1] = work / ('history-tests-' + other)
    run(cross_args)
    print('PASS: Swift Git wrappers link against every native symbol for both architectures')
    symbols = subprocess.check_output(['xcrun', 'nm', '-u', LIBRARY], text=True)
    assert not re.search(r'(?m)^_(?:libssh2_|SSL_|OPENSSL_|EVP_|socket$|connect$|getaddrinfo$|send$|recv$)', symbols), 'network/legacy crypto symbols remain'
    arches = subprocess.check_output(['xcrun', 'lipo', '-archs', LIBRARY], text=True).split()
    assert set(arches) == {'arm64', 'x86_64'}
    print('PASS: universal macOS library has no socket or legacy SSH/OpenSSL dependency')

if args.app:
    executable = args.app / 'Contents/MacOS/consolinotes'
    symbols = subprocess.check_output(['xcrun', 'nm', '-j', executable], text=True)
    # libcrypto includes SSL_str_reasons (an error-string table), not libssl/TLS.
    assert not re.search(r'(?m)^_(?:libssh2_|SSL_(?!str_reasons$)|git_socket_stream_|git_smart_subtransport_|git_transport_smart)', symbols), 'legacy crypto or remote transport symbols in app'
    libraries = subprocess.check_output(['xcrun', 'otool', '-L', executable], text=True)
    assert not re.search(r'(?i)(libssh2|openssl|libssl[.]|libcrypto[.])', libraries), 'legacy dynamic crypto dependency in app'
    strings = subprocess.check_output(['/usr/bin/strings', '-a', executable], text=True)
    assert not re.search(r'OpenSSL 1[.]1[.]1|libssh2_(?:session|init|version)', strings), 'legacy crypto identity in app'
    print('PASS: built app has no legacy SSH/OpenSSL or compiled Git network transport symbols')
