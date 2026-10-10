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
The existing libgit2 binary still links libssh2 initialization symbols, so
Libssh2Prebuild and the corresponding libssh2/OpenSSL notices remain. Their
presence documents a residual native dependency, not an app networking feature.
The full source archive remains available for the linked libgit2 and its build
material. Replacing this old binary requires a separate provenance review.

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
