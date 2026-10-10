# consolinotes

[简体中文](README_zh_CN.md) · [繁體中文](README_zh_TW.md)

**A terminal-style notes app for macOS, built on FSNotes.**

consolinotes is an independent fork of [FSNotes](https://github.com/glushchenko/fsnotes) by Oleksandr Hlushchenko. It builds on FSNotes' macOS note-taking features and restyles the app after Vim: split windows, a monospace grid, line numbers, statuslines and a command line. Notes stay plain Markdown or text files, so you can open them with any editor.

> consolinotes is not affiliated with, or endorsed by, the FSNotes project. If you want the original app, get [FSNotes](https://fsnot.es) and support its author.

## What's different from FSNotes

- **Vim modal look.** A tabline, a NERDTree-style library, and a statusline under each split whose mode (NORMAL, INSERT, PREVIEW, COMMAND) follows keyboard focus. The editor has line numbers, a cursorline and `~` past the end of the note, with a command line at the bottom.
- **JetBrains Mono everywhere.** Headers stay at body size, so every line sits on one grid.
- **Matching colours.** Markdown colours in the editor and a preview that uses the same palette in light and dark. Code blocks use the consolinotes theme or a terminal favourite: Gruvbox, Solarized, Tokyo Night, Catppuccin, Nord, Dracula or One, identical in the editor and the preview.
- **New name and icon.**
- **Its own identity.** Bundle identifier `io.github.sebiimaks.consolinotes`, and note and tag links use `consolinotes://`. `fsnotes://` links from existing notes still open in consolinotes.
- **Notes in `~/Documents/consolinotes`.** That folder is the default storage, and on first launch notes that earlier builds kept inside the app's sandbox are moved there. There is no built-in iCloud integration. macOS can still sync this folder if Desktop & Documents syncing is enabled, and other backup or sync software may copy it. Choose a folder outside those services for local-only storage.
- **Local-only operation.** Built-in Git sync and SSH/web publishing are removed. The app does not fetch link titles or remote preview resources. The sandbox has no outgoing-network entitlement.

Everything else comes from FSNotes: plain-file storage, folders, tags and `[[wikilinks]]`, AES-256 encrypted notes, optional local Git history, Mermaid and MathJax.

This branch contains the macOS app only. The previous iOS app and share extension are preserved in the [backup before iOS removal](https://github.com/sebiimaks/consolinotes/tree/codex/pre-ios-removal).

## Privacy and security scope

The current hardening pass removes app-managed sync/publishing, Handoff and automatic remote-content requests. Existing notes remain in their current location; this is not a new encrypted-vault format. macOS or another tool may still sync or back up a folder you choose, including `Documents`.

Previews and printing use a nonpersistent WebKit data store, block network resources, reject raw note HTML, and limit local attachments to verified files inside the note's attachment root. Note and tag links navigate or search; URL parameters cannot create notes or append text. User-initiated external links still open in the chosen browser or app, where that app's privacy settings apply.

Encrypted-note writes complete synchronously and replace ciphertext atomically. Failed saves keep the recoverable working copy and prevent locking or quitting from discarding it. Successful locking clears note content, undo state and generated previews; encrypted-note metadata caches omit content, tags and attachment paths. These protections do not make ordinary notes encrypted: plaintext notes, unencrypted attachments, local history and external backups need separate care.

Unlocked encrypted notes still use temporary plaintext working files. Successful locking removes them, while a failed write deliberately retains recovery data; interrupted sessions may leave temporary files. The existing RNCryptor format and password derivation remain unchanged for compatibility, so a stronger vault format and KDF migration are future work. Touch ID remains an optional convenience using the existing Keychain password format; existing master passwords can still be read from the legacy FSNotes Keychain service and copied to this app's service. The legacy item is not deleted, and this pass does not add hardware-bound Keychain access controls.

Local history is optional and records earlier file contents. Encrypting or deleting the current note does not erase plaintext in earlier revisions or external backups. Preferences → Local History explains this and lets you delete local history deliberately; the upgrade preserves existing history.

On launch, the app removes legacy networking preferences and its own imported Git key copies, and rewrites its project-settings archives without saved credentials. Original SSH key files, notes, Git repositories and already-published sites are preserved. Cleanup failures are reported and retried. Copies in external backups are outside this cleanup.

The old native Git stack remains for local history in this first pass. Shout, BlueSocket and the unused swift-git/swift-system wrappers are removed, but the pinned libgit2 binary still requires Libssh2Prebuild (libssh2/OpenSSL) at link time. No app remote transport wrapper remains, and sandbox networking is disabled. Replacing or rebuilding this legacy binary, and migrating plaintext historical revisions into an encrypted vault, remain follow-up work; this build is not a claim of complete security certification.

## Building

Open `FSNotes.xcodeproj` in Xcode and build the `FSNotes` scheme. It produces `consolinotes.app`.

```bash
xcodebuild -project FSNotes.xcodeproj -scheme FSNotes -configuration Debug -derivedDataPath build/DerivedData build
```

For a Release build for local use, run:

```bash
bash scripts/build-local-macos.sh
```

This uses ad-hoc signing and preserves the app sandbox, with one exception that lets the app use `~/Documents/consolinotes`. It needs no Apple signing account and produces `build/DerivedData/Build/Products/Release/consolinotes.app`. The script verifies the signature and bundled licences.

### Privacy regression checks

After building, run these checks on macOS:

```bash
python3 scripts/check-encrypted-storage.py
python3 scripts/check-protected-moves.py
python3 scripts/check-note-attachments.py
python3 scripts/check-offline-core.py
bash scripts/test-offline-migration.sh
python3 scripts/check-preview-security.py
python3 scripts/check-preview-webkit.py
```

The storage and routing fixtures exercise production methods with synthetic files and model doubles; they do not validate the cryptographic algorithms. The preview checks use the pinned Markdown renderer and a real WebKit instance with a local test server. No check reads your notes or Keychain. The release build also verifies the signed app has hardened runtime, the sandbox, and no network or debugging entitlements.

## Licence

consolinotes is released under the MIT licence, the same licence as FSNotes. See [LICENSE](LICENSE), which keeps the original FSNotes copyright notice.

It bundles or links third-party software, including JetBrains Mono and Source Code Pro (SIL Open Font License 1.1), highlight.js, Mermaid, MathJax, cmark-gfm, libgit2, libssh2 and OpenSSL. Their notices and licence texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also ships inside the app.

On macOS, open **About consolinotes → Licences…** to read the project licence and third-party acknowledgements. About, Help and support links identify this independent fork; original FSNotes credits remain in the acknowledgements.

The app also includes the pinned libgit2 source and build material as `libgit2-source.tar.gz`; see [SOURCE_CODE.md](SOURCE_CODE.md). There is no built-in web publishing. Local HTML exports retain the applicable embedded licence notices.

### Maintaining licence files

Edit the original texts and component manifests in `Licenses/`, then regenerate the app and local-preview copies. After resolving the pinned Swift packages, check the source archive and the built app before a release:

```bash
python3 scripts/generate-license-notices.py
python3 scripts/check-license-distribution.py --app build/DerivedData/Build/Products/Debug/consolinotes.app
```

For a release, pass the actual Release app and add `--require-tracked` to verify the licence, source and font inputs are included in Git. When the libgit2 dependency changes, regenerate its source archive using `python3 scripts/package-libgit2-source.py` after reviewing the pinned versions and build provenance. The full workflow is in [Licenses/README.md](Licenses/README.md).

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/), and cryptographic software written by Eric Young (eay@cryptsoft.com).

## Credits

consolinotes is built on the work of Oleksandr Hlushchenko and the [FSNotes contributors](https://github.com/glushchenko/fsnotes/graphs/contributors).
