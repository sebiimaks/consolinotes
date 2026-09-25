# libgit2 source delivery

The app includes `libgit2-source.tar.gz` alongside its licence notices. Choose
**Show Package Contents** on the macOS app and open `Contents/Resources`. The repository copy is
`Resources/libgit2-source.tar.gz`. Extract it with:

```sh
tar -xzf libgit2-source.tar.gz
```

The archive includes the complete committed libgit2 source tree, its bundled
dependencies, tests, `COPYING`, CMake files, and the upstream Apple-platform build
and archive scripts. It also contains the swift-cgit2 wrapper and its iSSH2 build
helper. Source and build material are delivered with the app; this document is
not a promise to supply source on request.

The upstream platform sources and build scripts remain complete in this archive,
even though consolinotes itself builds only for macOS.

## Versions and provenance

The current Swift package is swift-cgit2 **1.2.2**, commit
`ab1a18d82002b185c1c73b0daaa4174bb6b4f29c`. Its `Package.swift` selects the
[1.2.0 binary release](https://github.com/glushchenko/swift-cgit2/releases/tag/1.2.0)
with ZIP SHA-256
`cbf67a82594267aecc5cc4d021059cf0165f38566df0dcf0c52e065f1d6f1358`.

That release's tag and the resolved package pin the same source and build trees:

| Component | Commit | Archive path |
|---|---|---|
| libgit2 | `6c78fd06e3cedec818122ecc7f90e6c81e497354` | `swift-cgit2/libgit2` |
| iSSH2 build helper | `f9b8f8b913614ed5d5875d7b734b8aad8a2c13d3` | `swift-cgit2/iSSH2` |
| swift-cgit2 wrapper and scripts | `ab1a18d82002b185c1c73b0daaa4174bb6b4f29c` | `swift-cgit2` |

libgit2's version header says 1.1.0, but this commit is **405 commits after the
v1.1.0 tag**. An ordinary libgit2 1.1.0 release tarball is therefore not an adequate
substitute for this source archive. All 87 public headers in each of the three
resolved XCFramework slices match the included source bytes.

`SOURCE_MANIFEST.json` inside the archive records the pins and verification scope.
`Licenses/libgit2-source.json` in the repository additionally records the archive's
SHA-256 and the local binary hashes. The archive preserves each component's own
licence; see especially `swift-cgit2/libgit2/COPYING` for GPLv2 and its linking
exception.

## Building and verification scope

The upstream build entry point is `swift-cgit2/bin/build`, with platform options
`--macosx`, `--iphoneos`, and `--iphonesimulator`. Run it from `swift-cgit2` on a
Mac with Xcode, its platform SDKs, CMake, and the usual command-line build tools.
The script builds libgit2 with static libraries, builtin PCRE, and the platform
settings recorded in that script. `bin/archive` packages the resulting
XCFrameworks. libgit2's own `README.md` and CMake configuration
provide the underlying source-build instructions.

The historical helper also downloads and builds external OpenSSL and libssh2
sources, choosing their versions dynamically unless given explicit version
arguments. Those are separate libraries, not nested libgit2 Git submodules;
their source is not included in this archive. When rebuilding, pin those inputs
and retain the configuration and build log for reproducibility. Standard system
libraries and Apple SDKs are also not included.

The matching headers, release tag, source pins, and scripts are the provenance
evidence used to select this source. Upstream's release has no build attestation
or complete build log, and this check has not independently reproduced the
prebuilt XCFramework byte for byte. The original build scripts are preserved
for inspection; successful reproduction with current Xcode has not been tested.
These are limits of the verification performed, not additional licence terms.

## Maintaining the archive

From this repository, after Xcode has resolved the current packages:

```sh
python3 scripts/package-libgit2-source.py
python3 scripts/package-libgit2-source.py --check
```

The tool uses committed Git objects, not uncommitted package checkout files,
and makes no network requests. It recursively incorporates the two pinned
submodules, normalizes archive timestamps and ownership, checks the package pin
and binary public headers, and records SHA-256 hashes. `--checkout` and
`--artifacts` accept alternate Xcode package directories. Any dependency update
requires reviewing and updating the pins, provenance notes, archive and manifest
together. Keep the source archive and this document in every distributed app
that contains this libgit2 binary.
