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
- **Private library by default.** New libraries live in the app’s private Application Support storage with owner-only permissions and system backup exclusion. Existing users explicitly choose to keep their selected folder or copy it into private storage. Copies are verified and originals are kept. Preferences → General → Storage controls library selection and the private library’s system-backup setting. Third-party tools and existing backups are outside this setting.
- **Local-only operation.** Built-in Git sync and SSH/web publishing are removed. The app does not fetch link titles or remote preview resources. The sandbox has no outgoing-network entitlement.

Everything else comes from FSNotes: plain-file storage, folders, tags and `[[wikilinks]]`, AES-256 encrypted notes, optional local Git history, Mermaid and MathJax.

This branch contains the macOS app only. The previous iOS app and share extension are preserved in the [tagged backup before iOS removal](https://github.com/sebiimaks/consolinotes/tree/pre-ios-removal).

## Privacy and security scope

The app has no managed sync/publishing, Handoff or automatic remote-content requests. Existing notes remain in their current location; ordinary notes are still plaintext files. macOS or another tool may still sync or back up a folder you choose, including `Documents`.

Previews and printing use a nonpersistent WebKit data store, block network resources, reject raw note HTML, and limit local attachments to verified files inside the note's attachment root. Note and tag links navigate or search; URL parameters cannot create notes or append text. User-initiated external links still open in the chosen browser or app, where that app's privacy settings apply.

Encrypted-note writes complete synchronously and replace ciphertext atomically. Failed saves keep recoverable edits in memory and an encrypted journal snapshot and prevent locking or quitting from discarding it. Every lock request immediately hides content across all windows, including when saving fails; revealing retained edits requires the existing password again. Locking on fast user switching happens when the session becomes inactive. Password and PIN dialogs clear their fields on completion, cancellation, window closure and lock. Successful locking clears note content, undo state and generated previews; encrypted-note metadata caches omit content, tags and attachment paths. These protections do not make ordinary notes encrypted: plaintext notes, unencrypted attachments, local history and external backups need separate care.

Newly encrypted notes use AES-256-GCM and PBKDF2-HMAC-SHA256 with 600,000 iterations, implemented by CryptoKit and CommonCrypto. A key is derived once per unlock; each save uses a new random nonce. Existing RNCryptor v3 notes remain supported and retain their format when edited, subject to the archive safety limits below. To upgrade one, unlock it and choose **File → Upgrade Encryption…**. The password stays the same. New and upgraded files require consolinotes 1.2 or newer; FSNotes and older consolinotes cannot read them. Upgrading the live file does not upgrade older history or backups.

The new-encryption notice has a **Do not ask again.** checkbox. Its preference is saved only when you confirm **Encrypt**, never when you cancel. It does not suppress the separate confirmation for upgrading an existing note.

Since 1.7, encrypted notes and attachments are decrypted into memory. Normal unlock, editing, save, lock, sidebar thumbnails, and encrypted preview do not create plaintext working files. Preview and print rendering use a private in-memory WebKit document with a revocable per-document capability; bundled scripts, styles and fonts stay local. Opening an encrypted attachment in another app requires an explicit plaintext export. Printing and sharing require confirmation and can give an external destination its own plaintext copy.

Encrypted saves first write an authenticated encrypted recovery snapshot in private Application Support storage. **File → Recover Interrupted Notes…** restores a separate `.etp` file using its original password or recovery secret, without overwriting current notes. Interrupted plaintext working copies from older versions still have explicit restore/discard options; incomplete old copies can be deliberately exported for manual recovery. Routine working content stays in memory, but this cannot exclude OS swap, crash dumps, compromised processes or copies already sent outside the app.

Archive extraction rejects unsafe paths, links and special files, and counts actual decompressed bytes before writing each chunk. New saves and extracted content are limited to 512 MiB, 16,384 entries and 32 path components; ciphertext is size-checked before reading and bounded throughout the read. Cancellation removes partial extraction. New encryption maps attachment references before serialization, so spaces, percent signs and Unicode filenames work when the encrypted note is moved away from its original assets. Older encrypted notes with already-broken attachment references are not automatically rewritten.

Unlock still runs synchronously: large notes can delay the interface and delivery of a lock or cancellation event. Once cancellation is observed, an interrupted operation cannot publish its decrypted content. Moving this work off the interface thread remains a follow-up.

Find and recent searches stay in this app's memory and are cleared when notes lock. Older persisted recent-search preferences are removed. Note clipboard copies are marked local to this Mac, concealed and transient, then cleared after one minute by default or when notes lock. **Preferences → Security → Clipboard Privacy…** changes the expiry to 30 seconds, one, two or five minutes. Cleanup preserves newer clipboard content from other applications. Clipboard managers may ignore these markers. Rich paste and drag use a bounded structured format containing text and embedded attachment bytes; legacy object archives are not decoded, and Paste as Plain Text only reads text.

Diagnostics retain only a bounded set of static event labels in memory, without note contents, names, paths or raw error details. **Preferences → Security → Review Diagnostics…** lets you review and deliberately save that report; it is never sent automatically.

Unlocking supports manual password entry and optional direct-USB FIDO2 YubiKey unlocking. Touch ID, saved Keychain passwords and native PIV unlocking have been removed so no unlock feature requires Apple provisioning. Existing encrypted notes and passwords are unchanged. Previously saved Keychain items and PIV envelopes are not read or deleted by this build; retain your original note passwords.

Local history is optional and records earlier file contents. Encrypting or deleting the current note does not erase plaintext in earlier revisions or external backups. Preferences → Local History explains this and lets you delete local history deliberately; the upgrade preserves existing history.

Deleting a note saves and locks any encrypted working copy first; a failed save or file removal keeps the note visible. Failed encrypted saves retain memory and encrypted recovery data while the editor is shielded. Quitting waits for persistence to succeed. Deleting a flat Markdown note preserves attachments that may be shared with other notes. Deleting a TextBundle removes its enclosed assets. Deletion is not secure erasure of storage, history or backups.

On launch, the app removes legacy networking preferences and its own imported Git key copies, and rewrites its project-settings archives without saved credentials. Original SSH key files, notes, Git repositories and already-published sites are preserved. Cleanup failures are reported and retried. Copies in external backups are outside this cleanup.

Local history uses libgit2 1.9.7 built from pinned source for arm64 and x86_64. All network transport implementations are excluded; the old swift-cgit2, libssh2 and OpenSSL binary dependencies are removed. Complete source, the local patch and build provenance ship with the app. Existing historical plaintext is not rewritten. These measures are not a claim of complete security certification.

Preferences → Security → Note Protection also offers encryption for newly created notes, idle locking (five minutes by default), locking when the last note window closes, and optional locking when any YubiKey is unplugged. Imports and duplicates preserve their existing format and require an explicit unencrypted-copy choice when new-note encryption is enabled. Writing Tools and inline prediction are disabled in the note editor and active text fields. Folder access is restored only for configured roots, refreshed when stale, and released on detach or quit.

### Direct-USB YubiKey unlocking

Since version 1.4, consolinotes uses libfido2 over USB HID, not Apple's PIV identity service. The local app remains ad-hoc signed, sandboxed and hardened, with USB access and no network access. A sandboxed capability probe has verified this path on the development Mac with a connected YubiKey. No Apple developer account, provisioning profile or developer fee is required for this local integration.

Open **Preferences → Security → YubiKey Unlock…** to manage up to 16 named enrollments. Add a YubiKey without replacing existing enrollments; rename or remove only the selected entry. Connect one key at a time. To create an independent backup, physically swap to a different YubiKey; multiple enrollments of the same physical key do not provide redundancy. Each enrollment can protect the same existing note password or a different one.

Select the intended encrypted note before enrollment. Enrollment checks its existing password against the actual ciphertext before any hardware operation, then asks for a name and the key’s FIDO2 PIN. The app guides each activation separately: **1. Create the credential → 2. Protect the saved password → 3. Verify unlocking**. Before each operation it waits for **Continue**, then explicitly prompts **Touch your YubiKey now**. No reliance on noticing flashing lights. Existing enrollments are saved unchanged unless all three stages succeed. A non-discoverable ES256 credential is created under `consolinotes.local-unlock`; PINs, OTP/PIV slots, existing credentials and note passwords are not replaced or reset.

For individual encrypted notes, choose **Use YubiKey…**, select the named enrollment and enter its FIDO2 PIN. A signed, PIN-free credential check on the same opened USB device rejects a mismatched enrollment before sending the PIN. This check omits the built-in `uv` option, which ordinary non-biometric YubiKeys do not support even when set to false; version 1.5.1 corrects that compatibility error. Keys configured to require user verification even for this check fail closed with guidance to use a manual password. Each secret-producing assertion still requires PIN verification and touch, and the app verifies its signature and flags. PIN errors are never automatically retried; manual password fallback is explicit. The app does not attest the manufacturer's identity; USB vendor filtering is a convenience, not a security attestation.

Ordinary YubiKey unlocking wraps the existing note password; keep that password for recovery. It does not strengthen resistance to guessing that password against a copied note. Preferences → Security → Note Protection adds a separate stronger setup and deliberate secret-rotation flow for the selected encrypted note. Setup generates a 256-bit random secret, requires a separately re-entered offline recovery password and a verified hardware enrollment, then atomically replaces the note ciphertext. The recovery password also unlocks the note manually. Keep it offline and export your enrollment collection. Losing both means losing access. Removing an enrollment does not revoke an exported copy or previously copied ciphertext.

Use **Test Enrollment** to check a selected key against the selected encrypted note, and **Add Backup Key** to protect that same password with another key. **Export Enrollments** saves a portable encrypted collection; **Import Enrollments** validates and atomically merges it without replacing conflicting records. Test the import and each physical key before relying on the backup. The collection is necessary for recovery on another Mac because credentials are non-discoverable.

Each enrollment uses a separately generated hardware secret and salt. The hardware's 32-byte `hmac-secret` output feeds HKDF-SHA256 with an app-specific purpose string, then AES-256-GCM protects the saved password. Credential ID, public key, salt, and (for new records) a random password-group identifier and purpose are authenticated; enrollment names are descriptive plaintext labels. No note path or password hash is stored. The owner-only, backup-excluded store remains at `consolinotes/FIDO2Unlock.noindex/password.envelope` under Application Support. Existing 1.4 single-enrollment files appear as **Original YubiKey** without any write; the first successful add, rename or removal atomically migrates to a version-2 collection. Older builds cannot read that collection, but manual note passwords and note files are unchanged.

The FIDO2 PIN and derived secret are never persisted or passed through a subprocess. Library diagnostics are suppressed even if `FIDO_DEBUG` is inherited. Swift/OS memory handling does not guarantee perfect erasure of every temporary copy.

The two-architecture libraries are statically linked so hardened-runtime library validation stays enabled. OpenSSL 4.0.3 is used only for libfido2 cryptography; local Git remains free of OpenSSL and network transports. Rebuild with `python3 scripts/fetch-fido2-sources.py` and `bash scripts/build-fido2-libraries.sh`; verify artifacts with `python3 scripts/check-fido2-libraries.py`. The user verified enrollment and unlocking in 1.4 and confirmed guided enrollment works in 1.5.1. Multiple physical keys still need live verification; automated tests never read real PINs or create credentials on a real key.

### Encrypted note format

Modern `.etp` files wrap the existing TextPack ZIP payload. All multi-byte integers below are unsigned big-endian. The whole 48-byte header is authenticated as GCM additional data.

| Bytes | Meaning |
| --- | --- |
| 0–7 | ASCII `CNOTEENC` |
| 8–11 | Version `1`, AES-256-GCM identifier `1`, PBKDF2-SHA256 identifier `1`, reserved `0` |
| 12–15 | Iteration count, exactly `600000` for version 1 |
| 16–47 | Random 32-byte salt |
| 48–59 | Random 12-byte GCM nonce |
| 60 onward | Ciphertext followed by the 16-byte authentication tag |

Password bytes are UTF-8 without Unicode normalization; new-format passwords must contain 1–4096 UTF-8 bytes. The derived key is 32 bytes. Unknown versions/algorithms, altered authentication data and unsupported iteration counts fail closed. Legacy detection accepts RNCryptor v3 password envelopes only. This is a file-format wrapper around standard library primitives, not a custom cipher. The derivation cost follows the [OWASP PBKDF2 guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#pbkdf2).

## Building

Open `FSNotes.xcodeproj` in Xcode and build the `FSNotes` scheme. It produces `consolinotes.app`.

```bash
xcodebuild -project FSNotes.xcodeproj -scheme FSNotes -configuration Debug -derivedDataPath build/DerivedData build
```

For a Release build for local use, run:

```bash
bash scripts/build-local-macos.sh
```

This uses ad-hoc signing and preserves the app sandbox. Libraries outside private app storage require an explicit folder selection; there is no automatic Documents access. It needs no Apple signing account and produces `build/DerivedData/Build/Products/Release/consolinotes.app`. The script verifies the signature and bundled licences.

### Privacy regression checks

After building, run these checks on macOS:

```bash
python3 scripts/check-encrypted-storage.py
python3 scripts/check-encrypted-codec.py
python3 scripts/check-password-routing.py
python3 scripts/check-password-lifecycle.py
python3 scripts/check-lock-privacy.py
python3 scripts/check-private-clipboard.py
python3 scripts/check-private-editor.py
python3 scripts/check-private-preview-find.py
python3 scripts/check-editor-clipboard.py
python3 scripts/check-privacy-defaults.py
python3 scripts/check-watcher-privacy.py
python3 scripts/check-file-watcher.py
python3 scripts/check-launch-storage.py
python3 scripts/check-private-library.py
python3 scripts/check-encrypted-attachments.py
python3 scripts/check-encrypted-recovery.py
python3 scripts/check-fido2-password.py
python3 scripts/check-fido2-bridge.py
python3 scripts/check-fido2-ui.py
python3 scripts/check-fido2-libraries.py
python3 scripts/check-private-working-storage.py
python3 scripts/check-protected-moves.py
python3 scripts/check-note-attachments.py
python3 scripts/check-offline-core.py
bash scripts/test-offline-migration.sh
python3 scripts/check-preview-security.py
python3 scripts/check-preview-webkit.py
python3 scripts/check-preview-watchdog.py
python3 scripts/check-print-preview.py
python3 scripts/check-preview-dependencies.py
python3 scripts/test-local-history.py
```

The storage and routing fixtures exercise production methods with synthetic files and model doubles. The codec checks test modern and legacy formats against independently generated Node/OpenSSL fixtures; Node is needed only for this test. The preview checks use the pinned Markdown renderer and a real WebKit instance with a local test server. The history tests use disposable repositories and the built local library. No check reads your notes or Keychain. The release build also verifies the signed app has hardened runtime, the sandbox, and no network or debugging entitlements.

## Licence

consolinotes is released under the MIT licence, the same licence as FSNotes. See [LICENSE](LICENSE), which keeps the original FSNotes copyright notice.

It bundles or links third-party software, including JetBrains Mono and Source Code Pro (SIL Open Font License 1.1), highlight.js, Mermaid, MathJax, cmark-gfm and libgit2. Their notices and licence texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also ships inside the app.

On macOS, open **About consolinotes → Licences…** to read the project licence and third-party acknowledgements. About, Help and support links identify this independent fork; original FSNotes credits remain in the acknowledgements.

The app also includes the pinned libgit2 source and build material as `libgit2-source.tar.gz`; see [SOURCE_CODE.md](SOURCE_CODE.md). There is no built-in web publishing. Local HTML exports retain the applicable embedded licence notices.

### Maintaining licence files

Edit the original texts and component manifests in `Licenses/`, then regenerate the app and local-preview copies. After resolving the pinned Swift packages, check the source archive and the built app before a release:

```bash
python3 scripts/generate-license-notices.py
python3 scripts/check-license-distribution.py --app build/DerivedData/Build/Products/Debug/consolinotes.app
```

For a release, pass the actual Release app and add `--require-tracked` to verify the licence, source and font inputs are included in Git. When the libgit2 dependency changes, regenerate its source archive using `python3 scripts/package-libgit2-source.py` after reviewing the pinned versions and build provenance. The full workflow is in [Licenses/README.md](Licenses/README.md).

## Credits

consolinotes is built on the work of Oleksandr Hlushchenko and the [FSNotes contributors](https://github.com/glushchenko/fsnotes/graphs/contributors).
