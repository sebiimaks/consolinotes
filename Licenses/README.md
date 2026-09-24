# Licence inputs and distribution

`BASE_NOTICES.md` holds the existing top-level component notices. The component
manifests in `native/` and `web/` select complete original licence texts for
incorporated dependencies. Matching component names replace legacy base entries.
Each manifest records the source URL and version; web provenance records identify
the actual bundled Mermaid file and its dependency versions.

Run `python3 scripts/generate-license-notices.py` from the repository to produce:

- `THIRD_PARTY_NOTICES.md` for native applications;
- `Resources/MPreview.bundle/THIRD_PARTY_NOTICES.md` for bundled and published web assets;
- `Resources/MPreview.bundle/LICENSE`, a copy of the root FSNotes/fork MIT licence.

The generator also maintains licence comments for FSNotes and the injected theme
CSS in the preview HTML template. This preserves their notices when hosted/API
publishing sends only a standalone HTML page. Other template edits remain intact.

Commit both the input files and the generated copies. Do not edit a generated
copy directly. `--check` verifies all outputs without rewriting them.

All four Xcode targets carry the root licence and third-party notices. The three
application targets also carry `SOURCE_CODE.md` and `libgit2-source.tar.gz`; the
iOS extension's native source is supplied by its containing application. The
preview bundle carries font OFLs as well as the aggregate notices. Published web
pages use only the relevant web components, not the native libraries also listed
in the aggregate document.

Custom-server setup uploads notices before copying JavaScript and CSS. Subsequent
macOS and iOS note uploads refresh the notices at the configured asset root,
including on servers configured before licence delivery was added. Missing or
failed notice transfers stop that upload. No server credentials are needed to
generate or validate the licence files locally.

## Release verification

After resolving the pinned Swift packages and building the intended configuration:

```sh
python3 scripts/check-license-distribution.py --app /path/to/consolinotes.app --require-tracked
```

For an iOS archive, supply the app under `Products/Applications`. Repeat `--app`
to check multiple artifacts. The check validates generated copies, the libgit2
source archive, Xcode resource membership, font notices, and exact licence/source
bytes in the built app. `--require-tracked` also rejects untracked release inputs.
It does not publish a release or certify trademark rights.

Dependency updates must update their original licences, version inventory and
generated files together. libgit2 updates also require regenerating its bundled
source archive and reviewing the source/binary provenance recorded in
`SOURCE_CODE.md` and `libgit2-source.json`.
