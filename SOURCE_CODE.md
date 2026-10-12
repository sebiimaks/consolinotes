# libgit2 source delivery

The app ships `libgit2-source.tar.gz` beside its licence notices. Choose **About → Licence Notices** to locate the notices, or find the archive in the app's `Contents/Resources` directory. The repository copy is `Resources/libgit2-source.tar.gz`.

This contains the complete source tree of [libgit2 v1.9.7](https://github.com/libgit2/libgit2/releases/tag/v1.9.7), the consolinotes local-only patch, a standalone build recipe, the Swift package bridge, and a record of the locally built library. libgit2 remains GPL-2.0 with its linking exception; the patch is under those same terms. The app and bridge retain their own licences. The original `COPYING` and all third-party source notices are retained.

## Source and build identity

- Upstream commit: `49e408b3208bc3093757a1c2db938d3590f3f412`.
- Official upstream source archive: `https://github.com/libgit2/libgit2/archive/refs/tags/v1.9.7.tar.gz`.
- SHA-256: `1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7`.
- Local recipe: `scripts/build-local-git.py`; local changes: `Vendor/LocalGit2/local-only.patch`.
- Output: `Vendor/LocalGit2/libgit2.xcframework`, built for arm64 and x86_64, minimum macOS 12.4.
- Exact pre-patch production source hash, selected compiler, Xcode, SDK, CMake, options and every output hash: `Vendor/LocalGit2/build-provenance.json` (also inside the source archive).

The build disables HTTPS, SSH, GSSAPI and NTLM. The source patch removes all socket streams, HTTP/Git/SSH transport implementations and the HTTP parser from compilation and registers only the filesystem transport. It uses libgit2's bundled SHA-1 collision-detection implementation and SHA-256 implementation, Apple's system regex, zlib and iconv. No OpenSSL, libssh2, downloaded library binary, user Git executable or runtime dependency download is used.

## Rebuild

Install Xcode and CMake **3.31.10**. The build script never downloads software. Set `CMAKE` if its executable is not on PATH. To reproduce from the repository source archive into a new output directory:

```sh
python3 scripts/build-local-git.py --output build/rebuilt-libgit2.xcframework --manifest build/rebuilt-libgit2.json
```

To rebuild from the source archive delivered with an app:

```sh
tar -xzf libgit2-source.tar.gz
cd libgit2-source
python3 build-local-git.py --source-dir libgit2 --patch local-only.patch --output rebuilt-libgit2.xcframework --manifest rebuilt-libgit2.json
```

The recipe normalizes archive timestamps and temporary source paths. With the recorded toolchain, rebuilding can be checked against the recorded output hashes. Different compiler or SDK versions can produce different bytes; no cross-toolchain binary identity is claimed.

## Updating the dependency

Review the upstream release, pin its exact source archive checksum and commit, and review/reapply the local-only patch. Build the library, run `scripts/test-local-history.py` and the full macOS build, then regenerate the source-delivery archive with:

```sh
python3 scripts/package-libgit2-source.py --upstream-archive path/to/reviewed-upstream.tar.gz
python3 scripts/package-libgit2-source.py --check
python3 scripts/generate-license-notices.py
python3 scripts/check-license-distribution.py
```

Commit the source archive, manifest, local patch, build recipe, library, updated notices and provenance together. Distribute the source archive alongside every build containing this library. Existing note repositories and historical revisions are not rewritten by this dependency replacement; local history is not an encrypted vault.
