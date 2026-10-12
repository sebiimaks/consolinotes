# Licence inputs and distribution

`BASE_NOTICES.md` holds the existing top-level component notices. The component
manifests in `native/` and `web/` select complete original licence texts for
incorporated dependencies. Matching component names replace legacy base entries.
Each manifest records the source URL and version; web provenance records identify
the actual bundled Mermaid file and its dependency versions.

Run `python3 scripts/generate-license-notices.py` from the repository to produce:

- `THIRD_PARTY_NOTICES.md` for the macOS application;
- `Resources/MPreview.bundle/THIRD_PARTY_NOTICES.md` for bundled local preview assets;
- `Resources/MPreview.bundle/LICENSE`, a copy of the root FSNotes/fork MIT licence.

The generator also maintains licence comments for FSNotes and the injected theme
CSS in the preview HTML template. This preserves their notices in standalone local HTML exports. Other template edits remain intact.

Commit both the input files and the generated copies. Do not edit a generated
copy directly. `--check` verifies all outputs without rewriting them.

The macOS application target carries the root licence, third-party notices,
`SOURCE_CODE.md` and `libgit2-source.tar.gz`. The preview bundle carries font OFLs
as well as the aggregate notices.

Shout, BlueSocket and the unused swift-git/swift-system wrappers have been removed.
Local history now uses a locally compiled libgit2 1.9.7 with only filesystem
transport. The legacy swift-cgit2, libssh2 and OpenSSL binaries are removed.
`Vendor/LocalGit2/build-provenance.json` records the compiler, SDK, flags and all
output hashes; `libgit2-source.json` pins the official source and local patch.
The bundled archive contains complete upstream source, the patch and standalone
build recipe. See `SOURCE_CODE.md` for rebuilding and dependency updates.

## Release verification

After resolving the pinned Swift packages and building the intended configuration:

```sh
python3 scripts/check-license-distribution.py --app /path/to/consolinotes.app --require-tracked
```

Repeat `--app` to check multiple macOS artifacts. The check validates generated copies, the libgit2
source archive, Xcode resource membership, font notices, and exact licence/source
bytes in the built app. `--require-tracked` also rejects untracked release inputs.
It does not publish a release or certify trademark rights.

Dependency updates must update their original licences, version inventory and
generated files together. libgit2 updates also require regenerating its bundled
source archive and reviewing the source/binary provenance recorded in
`SOURCE_CODE.md` and `libgit2-source.json`.

The preview JavaScript build is pinned by `Vendor/Preview/package-lock.json`.
Run `npm ci --ignore-scripts` and `npm run build` in that directory, then regenerate
the aggregate notices. The build produces the offline Mermaid and highlight.js
bundles, copies MathJax's local runtime and fonts, and records package integrity,
output hashes and original licences. `npm audit --omit=dev` checks current
published advisories; it does not replace reviewing reachable configurations.
The build also inspects Mermaid source maps for embedded dependencies. Its
published core contains js-yaml 4.3.0, so a hash-verified build alias replaces
that entire standalone module with patched js-yaml 4.3.2. Embedded fastdom
1.0.12 keeps its original licence. Unknown embedded versions fail the build.
MathJax remains on the compatible patched 3.2.2 release, with its established TeX
font family. Its SIL OFL notices and Reserved Font Names are extracted directly
from the original WOFF files and shipped with the complete OFL text.

`Vendor/CMark` is a local Swift package containing unmodified C sources from the
official cmark-gfm revision recorded in `provenance.json`. The package includes
upstream fixes newer than the 0.29.0.gfm.13 tag. Its five generated public build
headers are recorded separately from upstream source hashes. The source archive
hash, per-file mappings, original COPYING notice and static build definitions
make that input reviewable without a moving remote branch.

Run `python3 scripts/check-preview-dependencies.py` to verify these pins and
generated outputs. The preview security and WebKit checks exercise pathological
parser and diagram inputs using synthetic notes; the watchdog check confirms
that a stalled WebKit page cannot prevent the app from returning to the editor.
