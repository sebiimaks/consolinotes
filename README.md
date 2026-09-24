# consolinotes

[简体中文](README_zh_CN.md) · [繁體中文](README_zh_TW.md)

**A terminal-style notes app for macOS, built on FSNotes.**

consolinotes is an independent fork of [FSNotes](https://github.com/glushchenko/fsnotes) by Oleksandr Hlushchenko. It keeps every FSNotes feature and restyles the macOS app as a console: box-drawn panes, a monospace grid, key hints and a status line. Notes stay plain Markdown or text files, so you can open them with any editor.

> consolinotes is not affiliated with, or endorsed by, the FSNotes project. If you want the original app, get [FSNotes](https://fsnot.es) and support its author.

## What's different from FSNotes

- **Modern TUI look.** Boxed library, note list and editor panes with focus highlighting, a title strip, and a key-hint and status bar.
- **JetBrains Mono everywhere.** Headers stay at body size, so every line sits on one grid.
- **Matching colours.** A "consolinotes" code theme, Markdown colours in the editor, and a preview that uses the same palette in light and dark.
- **New name and icon.**

Everything else comes from FSNotes: plain-file storage, folders, tags and `[[wikilinks]]`, AES-256 encrypted notes, Git versioning, web publishing, Mermaid and MathJax.

The iOS app retains the original interface, with updated project information and licence distribution. The terminal-style redesign is specific to macOS.

## Building

Open `FSNotes.xcodeproj` in Xcode and build the `FSNotes` scheme. It produces `consolinotes.app`.

```bash
xcodebuild -project FSNotes.xcodeproj -scheme FSNotes -configuration Debug -derivedDataPath build/DerivedData build
```

For a Release build for local use, run:

```bash
bash scripts/build-local-macos.sh
```

This uses ad-hoc signing, preserves the app sandbox, and uses the separate bundle identifier `io.github.sebiimaks.consolinotes`. It needs no Apple signing account and produces `build/DerivedData/Build/Products/Release/consolinotes.app`. The script verifies the signature and bundled licences. This local build does not enable the original developer's iCloud capabilities.

## Licence

consolinotes is released under the MIT licence, the same licence as FSNotes. See [LICENSE](LICENSE), which keeps the original FSNotes copyright notice.

It bundles or links third-party software, including JetBrains Mono and Source Code Pro (SIL Open Font License 1.1), highlight.js, Mermaid, MathJax, cmark-gfm, libgit2, libssh2 and OpenSSL. Their notices and licence texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also ships inside the app.

On macOS, open **About consolinotes → Licences…** to read the project licence and third-party acknowledgements. About, Help and support links identify this independent fork; original FSNotes credits remain in the acknowledgements.

Native apps also include the pinned libgit2 source and build material as `libgit2-source.tar.gz`; see [SOURCE_CODE.md](SOURCE_CODE.md). Web publishing sends the applicable licence files with the preview assets and refreshes them when publishing notes.

### Maintaining licence files

Edit the original texts and component manifests in `Licenses/`, then regenerate the app and web copies. After resolving the pinned Swift packages, check the source archive and the built app before a release:

```bash
python3 scripts/generate-license-notices.py
python3 scripts/check-license-distribution.py --app build/DerivedData/Build/Products/Debug/consolinotes.app
```

For a release, pass the actual Release app (or the `.app` inside an iOS archive) and add `--require-tracked` to verify the licence, source and font inputs are included in Git. When the libgit2 dependency changes, regenerate its source archive using `python3 scripts/package-libgit2-source.py` after reviewing the pinned versions and build provenance. The full workflow is in [Licenses/README.md](Licenses/README.md).

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/), and cryptographic software written by Eric Young (eay@cryptsoft.com).

## Credits

consolinotes is built on the work of Oleksandr Hlushchenko and the [FSNotes contributors](https://github.com/glushchenko/fsnotes/graphs/contributors).
