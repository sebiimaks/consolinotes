# consolinotes privacy and security audit

Audited on 12 October 2026 against production version 1.5.1, commit `3fed2d8d6b26d390633af7fba59bf1acb104a0f2`.

The next security work should focus on secret lifetime, locking, untrusted input and plaintext outside encrypted note files. The reviewed YubiKey flow retains PIN verification, touch, signed assertions and authenticated password envelopes. The tested paths did not reveal a bypass of those controls. Several surrounding application paths need improvement before adding stronger hardware requirements.

This plan preserves local-only operation, multiple named YubiKeys, manual password fallback and the ability to build locally without an Apple developer account. It does not propose sync, publishing, native PIV or Touch ID. Findings below describe the audited version. Subsequent implementation status is recorded at the end.

## Scope and evidence

The audit covered note encryption and attachments, temporary files, locking and password prompts, paste and drag input, search and clipboard behavior, previews and their dependencies, sandbox permissions, and FIDO2 enrollment and recovery.

Targeted encrypted-storage, private-working-storage, attachment, FIDO2 provider and bridge checks passed, including 24 bridge scenarios. Native library pinning and architecture checks passed. The installed application has an ad hoc signature, sandbox and hardened runtime, without a network entitlement. Synthetic probes additionally reproduced retained password fields, unrestricted object decoding before type validation, and incorrect encrypted attachment references. Existing passing checks do not cover all these cases.

No real notes or PINs were used by these probes. Multiple physical YubiKeys still require an end-to-end recovery exercise. Runtime traffic attribution remains unresolved for the previously observed `configuration.apple.com` connection; the absence of an app network entitlement does not establish that system services never make requests on its behalf.

The priorities below are implementation order, not CVSS ratings. Confirmed defects are distinguished from architectural limits and proposed privacy defaults. No critical exploit or remote code execution was demonstrated.

## Findings for the next patch

### Password prompt fields survive successful completion

The encryption dialog's password fields and completion closure remain strongly referenced after success. Canceling password requests during Lock All advances the cancellation generation but does not clear these fields. Clearing the password on the note therefore does not clear every application-owned copy. A synthetic probe using the production confirmation and cancellation methods reproduced this behavior.

Implement one prompt teardown path that clears fields, releases callbacks and closes sheets on success, cancellation, window closure and locking. Retain cancellation guards so a late callback cannot unlock a note. This reduces secret lifetime; Swift and AppKit cannot promise perfect erasure of every temporary memory copy.

Evidence: [password dialog completion](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/EditorViewController.swift#L1187).

### User switching locks on return

The user-switch observer uses `sessionDidBecomeActiveNotification`. It should lock when the session resigns activity, before another user takes over. Separate screen-lock and sleep handlers may also lock notes, so the present behavior is not proof that every user switch leaves notes exposed.

Route session departure, screen lock and sleep through a common lock operation. Include detached note windows and pending password or hardware dialogs.

Evidence: [session observer](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/ViewController.swift#L339).

### Paste and drag decode objects before validating their types

Custom attributed-text pasteboard data uses unrestricted `NSKeyedUnarchiver` decoding followed by an `NSAttributedString` cast. Another application can supply this pasteboard type. A benign synthetic object confirmed that its decoding initializer runs before the final cast rejects it. This establishes an unsafe decoding boundary, not a demonstrated code-execution exploit. Paste as Plain Text also takes this path. The drag handler can delete the current selection before validating the payload.

Read the string representation directly for plain-text paste. Use secure decoding with a minimal class and attribute allowlist and size limits for rich paste. Validate a drop fully before changing the document.

Evidence: [paste handling](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/View/EditTextView.swift#L613) and [drag handling](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/View/EditTextView+DragOperation.swift#L23).

### Some encrypted attachments still reference plaintext originals

Packaging rewrites attachment paths after the Markdown serializer has percent-encoded them. Names containing spaces, percent signs or non-ASCII characters can consequently retain an external `i/` reference despite the asset being copied into the encrypted package. The production packaging probe reproduced all three cases. Legacy attachment resolution can mask the error while the plaintext original remains available; moving only the encrypted note reveals broken images.

Use a single structured attachment mapping throughout serialization and packaging. Require every newly packaged attachment reference to resolve inside the encrypted bundle. Do not automatically delete shared originals, which may belong to other notes.

Evidence: [attachment packaging](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/Business/Note.swift#L1775).

### Preview dependencies miss published security fixes

The bundled Mermaid version is 11.12.2. It falls within the affected range of a published Gantt-rendering infinite-loop vulnerability. The app invokes diagram rendering, making the affected operation relevant. Strict Mermaid configuration and a network-blocking content policy do not stop this CPU denial of service. See the [Mermaid advisory](https://github.com/mermaid-js/mermaid/security/advisories/GHSA-6m6c-36f7-fhxh).

The native Markdown parser is cmark-gfm 0.29.0.gfm.4. Later releases contain multiple parser denial-of-service fixes and an autolink out-of-bounds-read fix. The app enables autolinks. The maintainers consider that particular read harmless in practice; it should not be presented as demonstrated data disclosure or code execution. See the [upstream changelog](https://github.com/github/cmark-gfm/blob/master/changelog.txt) and [autolink advisory](https://github.com/github/cmark-gfm/security/advisories/GHSA-c944-cv5f-hpvr).

Refresh the complete preview dependency set, including bundled DOMPurify and js-yaml, against current advisories. Assess whether affected configurations are reachable rather than treating every advisory as exploitable. Regenerate version pins, hashes, notices and provenance. Add bounded hostile-input regression fixtures and a recoverable rendering timeout or isolation boundary. Extend advisory inventory to native dependencies as part of release maintenance; this audit is not a complete vulnerability clearance for every bundled component.

## Plaintext and privacy boundaries

### Interrupted sessions can leave plaintext working copies indefinitely

Unlocked encrypted notes use temporary plaintext directories. Their restrictive permissions, indexing exclusion and backup exclusion are useful, but startup intentionally preserves abandoned directories to avoid losing unsaved work. Per-note cleanup tracks the current working copy; reopening and locking a note does not resolve every older crash copy. Another process with sufficient access under the same user can read these files.

First add a durable inventory of interrupted sessions and a recovery flow that offers restore or discard, with cleanup after resolution. Never blindly delete the only copy of unsaved edits. The longer-term design should edit encrypted notes in memory and use encrypted recovery journals instead of plaintext working bundles. Filesystem deletion cannot promise secure erasure of snapshots or SSD remnants.

Evidence: [preserved working directories](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/Business/Storage.swift#L182).

### Resource limits are applied too late

Unlock reads the whole encrypted file before a size budget is enforced. Archive extraction checks metadata through 32-bit size fields and validates actual output after extraction. ZIP64 sizes can be truncated by the pinned compatibility layer, so the documented expanded-size limit is not a strict streaming limit. A very large ciphertext can exhaust memory; a crafted archive that successfully authenticates can consume disk before rejection. This is not a bypass of encryption authentication.

Check file size on the opened descriptor before allocation, use bounded reads, and count actual decompressed bytes with 64-bit counters while extracting. Bound entry count and nesting depth, support cancellation, and clean partial output. Verify with deliberately small test budgets rather than exhausting the host.

Evidence: [encrypted file loading](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/Business/Note.swift#L1661) and [archive policy](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/PrivateNoteArchive.swift#L21).

### Failed saves preserve data but can leave it visible after locking

Locking deliberately refuses to discard unsaved edits when encryption or storage fails. However, Lock All only refreshes windows for notes that successfully lock. A failed note can remain visible after a privacy-triggered lock request.

Separate the privacy shield from successful persistence. Immediately hide sensitive content and disable editing across all windows, retain recoverable edits, and show a neutral recovery state. Require an explicit authenticated action before revealing retained content again.

Evidence: [Lock All](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/ViewController.swift#L1163).

### Search and clipboard behavior expose more than necessary

Search strings are copied to the system Find pasteboard and stored in recent-search preferences. General clipboard writes have no expiry or cleanup when notes lock. Search and clipboard data can therefore outlive the note's unlocked session.

Keep Find state inside the app and disable persistent search history by default. For sensitive copies, use current-host-only behavior, best-effort concealed/transient markers, and a configurable expiry. Clear only clipboard contents still owned by the app, using the pasteboard change count so subsequent user copies are preserved. Clipboard markers cannot prevent every other application from observing copied content.

Evidence: [Find pasteboard and recent search](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/View/SearchTextField.swift#L303).

### Logs and default storage retain identifying metadata

Diagnostics print note names and filesystem paths. The default library is the real `~/Documents/consolinotes` folder, which macOS Desktop and Documents sync or another sync tool may copy. Removing built-in sync does not prevent that behavior. Ordinary notes remain plaintext by design; local history and external backups can retain earlier plaintext after a live note is encrypted.

Replace content-identifying logs with redacted event codes and provide an opt-in, reviewable diagnostics export. Default new libraries to private Application Support storage with explicit backup behavior. Offer existing users an intentional migration, preserve their files, and remove the temporary Documents entitlement once access is covered by user-selected bookmarks. Explain historical copies during encryption rather than implying that encrypting the live file removes them.

Evidence: [bookmark logging](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/Helpers/SandboxBookmark.swift#L102) and [default library selection](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/UserDefaultsManagement.swift#L209).

### System services and folder access need explicit lifetimes

The editor leaves Writing Tools behavior at the system default. Toolbar sharing can hand plaintext to a user-selected system sharing service. Neither observation proves an automatic upload. A privacy-first default should explicitly disable Writing Tools and inline prediction for sensitive text, and require a clear action before plaintext sharing or export.

Security-scoped bookmarks are restored broadly at startup, while removing a folder does not balance the corresponding access scope. Track active access with leases or reference counts, release it when a folder is detached, and refresh stale bookmarks deliberately. Measure runtime traffic under deny-all networking and distinguish application requests from framework or system-service requests before making stronger offline claims.

Evidence: [editor text services](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/EditorViewController.swift#L55), [sharing](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/EditorViewController+Sharing.swift#L12) and [bookmark removal](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotes/Helpers/SandboxBookmark.swift#L112).

## YubiKey recovery improvements

### Enrollment verifies the envelope but not the intended note

The third activation correctly checks that the hardware can recover the password entered during enrollment. It does not check that the entered password unlocks any intended note. A typo can therefore produce a successfully verified envelope that is useless for the user's notes.

Enroll from an already authenticated note, or select an encrypted note and validate its password before committing the enrollment. Add a Test Enrollment action and a guided Add Backup Key flow that verifies the same password group without replacing existing keys. Keep names descriptive without storing note contents or unnecessarily identifying paths.

Evidence: [enrollment verification](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/FIDO2/FIDO2PasswordProvider.swift#L128).

### A spare key does not replace the local enrollment file

All enrollments depend on a single local envelope collection, which is excluded from backup. The credentials are non-discoverable. Losing the Mac or the collection can make every enrolled key unusable for this feature, even when the keys themselves are intact. The original manual note password still works.

Provide explicit export and import of the encrypted enrollment collection, validate imports, and rehearse recovery with each physical key. Explain the distinction between replacing a lost key and recovering after loss of the Mac. Removing a local enrollment does not revoke a copied envelope or change a note password; a lost-key response should offer deliberate note-secret rotation.

Evidence: [backup exclusion and atomic storage](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/FIDO2/FIDO2PasswordProvider.swift#L233) and [credential creation](https://github.com/sebiimaks/consolinotes/blob/3fed2d8d6b26d390633af7fba59bf1acb104a0f2/FSNotesCore/FIDO2/FIDO2Bridge.c#L85).

## Implementation sequence and acceptance criteria

| Stage | Deliverable | Required evidence before release |
| --- | --- | --- |
| 1 | Clear password prompts; lock on session departure; secure paste and drag; correct attachment references; refresh preview dependencies | Exercise actual AppKit completion and cancellation paths; reject unexpected archive classes before initialization; preserve selection on rejected drops; move encrypted notes with spaces, percent signs and Unicode attachments into a clean library; run bounded malicious-preview fixtures |
| 2 | Hide content on every lock request; inventory crash recovery; enforce file and streaming archive budgets; remove unnecessary search, clipboard and logging persistence | Inject save failures, disk exhaustion and termination at controlled points; keep unsaved edits recoverable while every window is shielded; surface abandoned working files; stop extraction at the configured budget and remove partial output; preserve unrelated clipboard contents |
| 3 | Private defaults and least folder access; explicit system-service policy; verified YubiKey enrollment and portable recovery | Verify existing-library migration and bookmark release; inspect runtime traffic; test two different physical keys, wrong-key selection without a PIN retry, cancellation, corrupt imports and recovery into a fresh app profile |
| 4 | Eliminate routine plaintext working bundles; add optional encrypted-by-default notes and stronger hardware mode | Show that normal unlock, edit and lock create no plaintext note or attachment files; recover encrypted journals after interruption; test atomic migration and recovery before enabling stronger hardware requirements |

The following implementation sections record completed stages; this table remains the original acceptance plan. Dependency updates can run alongside the application fixes. Regression tests should exercise the production serializers and UI teardown paths, since simplified model doubles missed defects found in this audit.

For Stage 4, a hardware-required mode should use a random high-entropy note secret, protected by at least two verified keys or a tested offline recovery secret. The existing optional mode should remain explicit: wrapping the original password with a YubiKey does not improve that password's resistance to guessing against a copied note file. Introduce idle locking, last-window-close locking and optional key-removal locking through the same lifecycle controller, after its failure and cancellation behavior is reliable.

Each release should retain sandbox and hardened-runtime checks, forbid network and provisioning-dependent unlock entitlements, rebuild third-party notices and provenance after dependency changes, and rerun the relevant privacy regressions. A local encrypted vault improves protection of stored files and residual data; it cannot guarantee secrecy from a compromised logged-in operating system.


## Implementation of stages 1 and 2

The 1.6 implementation clears password and PIN dialogs, shields all encrypted note windows before persistence, requires authentication to reveal retained edits after a failed save, and locks on session departure. Rich clipboard input now uses a bounded structured text and attachment format instead of object archives. New encryption maps attachment paths before serializing Markdown. Preview dependencies and their provenance are refreshed, with bounded hostile-input checks and a preview watchdog.

Working copies now have a durable private inventory and interrupted-session recovery, including explicit discard and restoration to a separate encrypted note. Descriptor-based file reads and streaming ZIP64 extraction enforce byte limits before allocation or output. Search state stays in memory, clipboard copies expire without clearing newer copies, and diagnostics use bounded static event labels with an explicit review/export action.

At the completion of stages 1 and 2, plaintext working bundles and the Documents default remained. Stages 3 and 4 below replace those paths. External clipboard observers may still ignore privacy markers, and malformed legacy attachment references are not silently repaired.


## Implementation of stages 3 and 4

Version 1.7 uses private Application Support libraries for new profiles, with system backups excluded by default and an explicit backup control. Existing libraries require a deliberate folder grant or a verified copy into private storage; originals are never deleted by migration. Migration compares SHA-256 manifests, rejects links and special files, applies private permissions and synchronizes before publishing. The broad Documents exception is removed. Configured bookmark roles have balanced access scopes, stale refresh, detach rollback and quit cleanup.

Version 1.7.1 fixes first-launch migration ordering: storyboard objects defer library access until setup finishes, and cached sidebar paths are limited to the selected library and attached folders. File-event startup failure is nonfatal and reported, with balanced stream cleanup and callbacks that tolerate a closed window. Synthetic regressions cover both backup choices, old cached roots, stream failure, and live changes after copying. The full sandboxed app was also exercised through copy, backup exclusion and live sidebar updates using a separate test profile.

Writing Tools, inline prediction and automatic text completion are disabled for the note editor and active field editors. Sharing, printing and exporting decrypted attachments require deliberate confirmation. New Note can require encryption before any file is created. Imports and duplicates preserve source formats and require explicit consent to create an unencrypted copy when that default is enabled. Idle locking, last-note-window locking and optional YubiKey removal use the common shield/save/lock lifecycle, including when only a password or hardware prompt is pending. Unavailable USB monitoring is reported instead of silently enabling the setting.

YubiKey enrollment authenticates the selected note before touching hardware. Test Enrollment checks the intended ciphertext; Add Backup Key verifies the same password group. Portable encrypted collections use strict bounds and atomic conflict-rejecting merge. Stronger protection and secret rotation generate a random 256-bit note secret, verify a separately re-entered offline recovery password and hardware envelope, and only then atomically replace verified ciphertext. Recovery cancellation or failed activation leaves the existing note unchanged. Removing local enrollments cannot revoke older exported envelopes or note copies.

Encrypted note ZIP contents now stay in a bounded in-memory workspace. Editing, attachments, preview, thumbnail generation and encryption operate without plaintext working bundles or ZIP staging. ZIP compatibility is retained; the in-memory writer uses stored entries, so files can be larger than earlier compressed files. Each save first publishes an authenticated encrypted journal snapshot. Recovery validates it with the password used at the time and restores a separate file. Older plaintext recovery copies remain visible for explicit resolution.

Synthetic tests exercise actual note lifecycle and archive/crypto code, injected write failure and cancellation, encrypted crash recovery, legacy archive compatibility, migration integrity, bookmark leases, automatic-lock triggers, and AppKit enrollment/recovery dialogs. Real WebKit tests cover file and memory documents, local rendering and blocked synthetic network attempts. Preview capabilities are limited to one document per view and revoked on close/lock. Release validation retains the sandbox, hardened runtime, USB access and no network entitlement.

Physical two-key enrollment, wrong-key behavior and recovery into a fresh installed profile still need a user hardware rehearsal. The test doubles are not evidence that a particular key’s policy works. OS-level traffic attribution under the user’s deny-all firewall has not been independently completed; network entitlements and WebKit tests do not prove that system services never attempt connections. Stronger protection is gated by recovery verification inside the app rather than silently migrating existing notes.

Remaining limits: ordinary notes, explicitly exported/shared/printed content, earlier history and backups can remain plaintext. Memory-only working storage is not a guarantee against swap, crash dumps, memory copies or a compromised logged-in OS. Synchronous note encryption and archive processing can delay UI event delivery during large operations; moving these to cancellable isolated background state remains follow-up work.
