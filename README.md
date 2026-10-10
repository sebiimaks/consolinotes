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

The app has no managed sync/publishing, Handoff or automatic remote-content requests. Existing notes remain in their current location; ordinary notes are still plaintext files. macOS or another tool may still sync or back up a folder you choose, including `Documents`.

Previews and printing use a nonpersistent WebKit data store, block network resources, reject raw note HTML, and limit local attachments to verified files inside the note's attachment root. Note and tag links navigate or search; URL parameters cannot create notes or append text. User-initiated external links still open in the chosen browser or app, where that app's privacy settings apply.

Encrypted-note writes complete synchronously and replace ciphertext atomically. Failed saves keep the recoverable working copy and prevent locking or quitting from discarding it. Successful locking clears note content, undo state and generated previews; encrypted-note metadata caches omit content, tags and attachment paths. These protections do not make ordinary notes encrypted: plaintext notes, unencrypted attachments, local history and external backups need separate care.

Newly encrypted notes use AES-256-GCM and PBKDF2-HMAC-SHA256 with 600,000 iterations, implemented by CryptoKit and CommonCrypto. A key is derived once per unlock; each save uses a new random nonce. Existing RNCryptor v3 notes remain supported and retain their format when edited, subject to the archive safety limits below. To upgrade one, unlock it and choose **File → Upgrade Encryption…**. The password stays the same. New and upgraded files require consolinotes 1.2 or newer; FSNotes and older consolinotes cannot read them. Upgrading the live file does not upgrade older history or backups.

The new-encryption notice has a **Do not ask again.** checkbox. Its preference is saved only when you confirm **Encrypt**, never when you cancel. It does not suppress the separate confirmation for upgrading an existing note.

Unlocked encrypted notes still use temporary plaintext working files. New working copies are in `ConsolinotesEncryption.noindex` inside the app's temporary directory, with owner-only permissions and Time Machine exclusion. Preview directories use the same indexing/backup precautions; thumbnails render in memory without disk caches. Successful locking removes working copies, while failed writes deliberately retain recovery data. Interrupted sessions and older `Encryption` directories are preserved for recovery. This is not a memory-only vault, and backup exclusion does not control third-party software. Archive members are checked for links/special files, and new saves and extracted content are limited to 512 MiB and fewer than 16,384 child entries. The extraction metadata guard is not a strict hostile-ZIP64 decompression budget.

Optional saved unlock passwords now use the macOS Data Protection Keychain, require OS-enforced user presence, are device-only and do not synchronize. Earlier saved passwords are never fetched automatically. Explicitly re-enter a password in **Preferences → Security → Saved Unlock Password…** to save and verify its protected replacement; only then is consolinotes' older saved copy removed. FSNotes' Keychain item is untouched. Appropriate signing/provisioning is required by macOS, so ad-hoc local builds may support only manual password entry. The app never substitutes an unprotected saved password. Password hints remain plaintext. See Apple's [Mac Keychain guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

Local history is optional and records earlier file contents. Encrypting or deleting the current note does not erase plaintext in earlier revisions or external backups. Preferences → Local History explains this and lets you delete local history deliberately; the upgrade preserves existing history.

Deleting a note saves and locks any encrypted working copy first; a failed save or file removal keeps the note visible. If plaintext cleanup fails after a successful encrypted save, the editor locks and subsequent retries remove only the leftover files; they cannot overwrite ciphertext from a partially removed working folder. Quitting waits for cleanup to succeed. Deleting a flat Markdown note preserves attachments that may be shared with other notes. Deleting a TextBundle removes its enclosed assets. Deletion is not secure erasure of storage, history or backups.

On launch, the app removes legacy networking preferences and its own imported Git key copies, and rewrites its project-settings archives without saved credentials. Original SSH key files, notes, Git repositories and already-published sites are preserved. Cleanup failures are reported and retried. Copies in external backups are outside this cleanup.

Local history uses libgit2 1.9.7 built from pinned source for arm64 and x86_64. All network transport implementations are excluded; the old swift-cgit2, libssh2 and OpenSSL binary dependencies are removed. Complete source, the local patch and build provenance ship with the app. Existing historical plaintext is not rewritten. These measures are not a claim of complete security certification.

### Optional YubiKey unlocking

In **Preferences → Security → Unlock with YubiKey…**, select a dedicated, existing PIV RSA encryption identity and enter the password of an existing encrypted note. Enrollment verifies an actual private-key decryption before saving an encrypted password envelope. It never creates, imports, resets or overwrites any key credential. This initial integration supports RSA 2048/3072/4096 identities exposed by macOS's built-in PIV driver, including appropriately configured YubiKey 5 devices. ECC and FIDO-only keys are not supported by this integration. The driver filter is not Yubico manufacturer attestation.

This saves one password on this Mac. When unlocking an individual encrypted note, choose **Use YubiKey**, **Enter Password…**, or the protected Keychain password if enabled. Removing the enrollment deletes only the app's encrypted envelope. The original note password remains a recovery method, and note files keep their existing encryption. New encryption and folder protection use manual/protected Keychain passwords: an optional public-key envelope must not choose the secret for new ciphertext. This is not the stronger “Require YubiKey” mode. Removal of the key does not automatically lock notes; use Lock All or the existing auto-lock settings.

PIN entry is handled by macOS, and PIN/touch requirements follow the key's configured policy. The app does not infer, alter or override those policies, and macOS may cache PIN authorization. A cancelled/failed hardware request never silently selects another saved password. Lock All, configured sleep/screen-lock/user-switch locking, and quit invalidate pending password results so a late authentication response cannot reopen notes.

**Setup is required before live use.** The local build script produces an ad-hoc signature. Apple's native token access requires an application identifier authorized by a provisioning profile; adding a fabricated entitlement is not sufficient. Configure Xcode's signing for this bundle identifier with an appropriate Apple signing identity and profile, retain the sandbox/hardened runtime and smart-card entitlement, and verify the resulting app on the target Mac. See [Apple's token-access guidance](https://developer.apple.com/forums/thread/725152) and [development provisioning profiles](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile). The app does not need the `com.apple.token` Keychain access-group entitlement on macOS.

For an unconfigured YubiKey, use [Yubico's PIV tools](https://docs.yubico.com/software/yubikey/tools/ykman/PIV_Commands.html) to inspect the key first. Prepare a dedicated unused encryption slot, commonly Key Management (9D), with an RSA 2048-bit key and matching certificate. Do not replace an occupied slot. Set nondefault PIN/PUK/management credentials and choose the desired PIN and touch policies when creating the key; requiring both on every operation means choosing **Always** for both where supported. Policy changes can require replacing a key, so decide before enrolling. Follow [Yubico's policy documentation](https://docs.yubico.com/yesdk/users-manual/application-piv/pin-touch-policies.html). Keep your note password separately; losing/resetting the key does not provide a way to recover it from the envelope.

The envelope lives in the app's Application Support directory at `consolinotes/HardwareUnlock.noindex/piv-password.envelope`, outside note/history folders. It contains certificate/token metadata and a password encrypted with a random AES-256-GCM key; RSA-OAEP-SHA256 wraps that key. Version, identity metadata and wrapped key are authenticated. Directories/files are owner-only, writes replace atomically, and reads reject links and oversized input. Unwrapped keys/passwords exist in memory during use, subject to the existing unlocked-note lifetime. No PIN or unwrapped secret is saved. Enrollment is local and does not automatically migrate to another Mac.

Synthetic tests verify cryptography, failure handling, storage and UI behavior without using real credentials. Live enumeration, PIN/touch prompts, key removal and relaunch must still be verified with a configured key and a provisioned build before relying on this feature.

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

This uses ad-hoc signing and preserves the app sandbox, with one exception that lets the app use `~/Documents/consolinotes`. It needs no Apple signing account and produces `build/DerivedData/Build/Products/Release/consolinotes.app`. The script verifies the signature and bundled licences.

### Privacy regression checks

After building, run these checks on macOS:

```bash
python3 scripts/check-encrypted-storage.py
python3 scripts/check-encrypted-codec.py
python3 scripts/check-protected-keychain.py
python3 scripts/check-password-routing.py
python3 scripts/check-piv-password.py
python3 scripts/check-piv-unlock-ui.py
python3 scripts/check-private-working-storage.py
python3 scripts/check-protected-moves.py
python3 scripts/check-note-attachments.py
python3 scripts/check-offline-core.py
bash scripts/test-offline-migration.sh
python3 scripts/check-preview-security.py
python3 scripts/check-preview-webkit.py
python3 scripts/test-local-history.py
```

The storage and routing fixtures exercise production methods with synthetic files and model doubles. The codec checks test modern and legacy formats against independently generated Node/OpenSSL fixtures; Node is needed only for this test. Protected-Keychain tests inject all Keychain operations and do not access real credentials. The preview checks use the pinned Markdown renderer and a real WebKit instance with a local test server. The history tests use disposable repositories and the built local library. No check reads your notes or Keychain. The release build also verifies the signed app has hardened runtime, the sandbox, and no network or debugging entitlements.

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
