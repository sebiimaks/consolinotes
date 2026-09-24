# Web asset license sources

`components.json` inventories license texts for dependencies compiled into the
vendored Mermaid bundle, plus the modified github-markdown-css stylesheet.
These are distribution notices, not new application dependencies.

The Mermaid JavaScript was verified byte for byte against the npm archive for
`mermaid@11.12.2`. Its SHA-256 is
`d0830a6c05546e9edb8fe20a8f545f3e0dc7c4c3134d584bad9c13a99d7a71e0`.

The published `dist/mermaid.min.js.map` identifies 68 dependency/package version
pairs with generated-code mappings. The inventory preserves those versions,
including both versions where separate copies are embedded. It also covers:

- `@mermaid-js/parser@0.6.3`: its published chunks match the source map exactly.
- `vscode-uri@3.0.8`: flattened source-map content matches the published package;
  `path-browserify@1.0.1` is also an exact source-content match.
- Rough.js's prebundled `hachure-fill`, `path-data-parser`, `points-on-curve`, and
  `points-on-path` code, with versions pinned by Mermaid's release lockfile.
- The github-markdown-css derivative explicitly identified in `main.css`.
  Its exact original revision is unidentified; the unchanged MIT notice was
  obtained from upstream npm release 2.10.0.

Each `.txt` file contains the original package license. Additional distinct
copyright/license comments from the corresponding source-map inputs are retained
where the package license alone does not contain them. In particular,
`layout-base@2.0.1` includes an Apache-2.0-licensed JamaJS-derived SVD implementation
and its original modification notice. DOMPurify is used under its Apache-2.0
option; its complete upstream dual-license file is preserved.

`provenance.json` records the bundle, source-map, lockfile, npm archive and original
license-file hashes, along with the package paths found in the source map. No
network fetch is required at build time or runtime. Root notice generation reads
`components.json` and these local license files.

When Mermaid is replaced, verify the new bundle against its published archive,
inspect the generated-code mappings and nested prebundles, and refresh the
inventory and original notices together. Do not infer bundled dependencies from
all package.json development dependencies or include unshipped font packages.
