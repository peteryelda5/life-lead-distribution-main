# Master key preparation, version 0.2.0

This build adds Encryption > Master key preparation (Ctrl+Shift+E) to the Windows
trial. The portal UI and backend remain unchanged. It prepares an encryption key
locally; it does NOT register a trusted Master, change database grants or encrypt leads.

## User ceremony

1. Open the app, then Encryption > Master key preparation.
2. Choose a unique recovery password of at least 20 characters and confirm it.
3. Create the key. RSA-3072 generation takes place on the user's device.
4. Save the password-encrypted `.lldkey` backup to offline storage. Keep the password
   separately in a password manager. Do not send it or the backup through chat.
5. Enter the password again, choose Reopen file and test recovery, and select the file
   actually saved. The app decrypts it, verifies it matches the device fingerprint and
   tests RSA-OAEP wrapping/unwrapping of a fresh synthetic data key.
6. A passed recovery check means LOCAL PREPARATION ONLY. Production enrollment and
   migration remain blocked pending owner authentication, independent trust, signed
   distribution and verified agent/division handling.

Use a new filename for backup exports. Existing files and existing device keys are
never silently overwritten. Recovery on a new device preserves the key fingerprint.

## Security boundary

The isolated setup renderer uses a separate nonpersistent session and custom protocol.
It has no network access, no Node integration, and only a narrowly defined preload API.
Each IPC action checks the exact window, main frame and local URL. Native file dialogs
select backup files; paths and private keys are not exposed to the renderer. Portal
scripts have no key API. Inputs and expensive KDF parameters are bounded. Operations
are serialized to prevent concurrent enrollment/overwrite races.

Recovery uses AES-256-GCM with a random 96-bit nonce, 256-bit salt and scrypt
(N=131072, r=8, p=1, 256 MiB maxmem). Format, project and intended Peter account UUID
are authenticated as AAD. The UUID label is NOT proof of ownership or authorization.
A trusted signing directory and authenticated enrollment are not implemented here.

The password-encrypted bundle is additionally protected by Windows DPAPI through
Electron's async safeStorage APIs. The OS boundary is Windows-only for this build and
fails closed when unavailable; there is no plaintext fallback. DPAPI does not defend
against malicious processes running as the same Windows user. Passphrases and unlocked
keys necessarily enter process memory; JavaScript garbage collection cannot guarantee
complete erasure. Lock drops the live key reference and clears timers; it does not
claim to wipe all memory or revoke data already seen.

The key locks on window close, Windows lock/suspend, app exit or five minutes since the
last key operation. A lock during asynchronous derivation must prevail over that operation.
This is independent of existing portal sessions, which still use the prior localStorage
behavior. The unsigned trial is not an approved production trust anchor. Do not activate
real lead encryption with it until signing and the remaining enrollment review are done.
No key, backup or password is sent to Supabase, Vercel or chat by this implementation.

## Validation and remaining gates

Synthetic tests cover correct recovery, wrong passwords, ciphertext/IV/tag corruption,
wrong project/owner, KDF tampering, size limits, weak-length passwords, vault create,
lock/unlock, cross-key backups, fresh-device recovery, no replacement, lock races and
IPC sender isolation. The OS encryption API is mocked in unit tests; actual Windows DPAPI
and native dialog behavior must be verified on the user's device. No real owner key was
generated in the build environment. No live database access or migration occurred.

Remaining production work: signed distribution and protected updates, Peter enrollment
with verified identity, authenticated public-key directory, agent/device enrollment,
key rotation and revocation, encrypted leads and duplicate CSV/notes/policy fields,
search and bulk-import performance, row-level authorization, staging migration,
backup retention and rollback. Mac/mobile require their own native storage integration.
