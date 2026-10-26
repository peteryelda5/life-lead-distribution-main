# Lead encryption: development foundation, not active protection

Status: experimental, not imported by the application. No production keys generated,
no database migration applied, no live records encrypted. Sidebar release is independent.

## Threat boundary

Browser-side AES-256-GCM encrypts a JSON payload before upload. Each record receives a
random 256-bit data key and 96-bit IV. RSA-OAEP (SHA-256, minimum 3072 bits) encrypts the
data key separately for each recipient. Project, division, record ID and schema version
are authenticated context; wrapped keys also bind recipient ID. This uses Web Crypto
primitives, not a custom cryptographic algorithm. Independent security review remains
required before production use.

A database dump without private keys should expose ciphertext plus deliberately retained
operational metadata. Existing Supabase row-level security remains necessary. Encryption
is not authorization: the caller must authorize every recipient and every lead operation.
The library requires Master as a recipient but does not verify role or division itself.

Vercel controls JavaScript sent to users. An attacker controlling deployment can replace
that code and steal plaintext when users unlock leads, even with non-extractable keys.
A website alone cannot promise confidentiality against its own malicious code distributor.
Protection from that threat requires an independently distributed, signed client with a
separate trusted update channel, plus hardened GitHub, Vercel and Supabase accounts.
This is a product/deployment decision, not a database encryption switch.

## Required integration work

1. Enroll device keys on user devices. The server must never receive plaintext private
   keys. Design encrypted recovery exports, offline Master recovery and replacement-device
   recovery; perform a recovery drill before touching production data. The current test
   uses ephemeral, non-extractable keys only and is NOT a recovery implementation.
2. Build a Master-approved key directory with an independently trusted signature root.
   The primitive checks supplied public-key fingerprints; loading both keys and trusted
   fingerprints from the same compromised database provides no protection. Do not do it.
3. Enforce recipients: Peter is always a recipient; scoped admins only their division;
   agents only assigned records; team leaders their permitted uploads. Preserve Peter's
   insertion restriction to Master/Vivid. Handle assignment, take-back, transfer, uploader
   access, key rotation and revocation transactionally. Prior recipients cannot be made
   to forget previously decrypted data. Add replay/version and writer-authenticity controls:
   GCM integrity alone does not identify which authorized writer created a record.
4. Encrypt ALL duplicated sensitive content: mapped names, phones, email, notes, call notes,
   raw CSV values/headers, sensitive source/filename fields, profiles, policy numbers and
   closed-business notes. Inventory audit records, logs, exports, jobs and local caches.
   Decide what operational metadata remains visible (IDs, divisions, status, assignment,
   timestamps, type/state counts); record residual exposure explicitly.
5. Replace plaintext SQL text search. Do not silently keep searchable plaintext copies.
   Blind indexes leak equality/frequency; client-side scanning 500,000 leads is unsuitable.
   Resolve search requirements and benchmark realistic encrypted imports/pagination before
   choosing an index scheme. RSA wrapping per lead has storage and throughput costs; no
   500,000-lead performance claim has been established.
6. Add staged schema and authenticated API support with strict RLS. Dual read during
   migration must fail closed on damaged ciphertext; do not hide failures with plaintext
   fallbacks. Import and migration jobs need resumable checkpoints and idempotent writes.
7. Dry-run synthetic and staging data, verify Master recovery, agent/division isolation,
   reassignment and closed-business flows. Compare decrypted hashes/counts before removing
   plaintext. Retain a controlled rollback window and account for plaintext in old backups,
   replicas, browser caches and exports until deleted or retention expires.
8. Require administrator MFA, review platform access and deployment protections, pin frontend
   dependencies, harden session handling, audit privileged functions and rate-limit reads.
   These complement encryption; none is implemented by this module.

## Verification

`node tests/lead-envelope.mjs` exercises synthetic round trips for Master and agent,
Unicode/CSV fields, randomized ciphertext, tampering, wrong keys, context substitution,
wrapped-key substitution, missing Master and untrusted recipient keys. No production data
or real user key material is used. Browser integration, recovery, throughput, authorization,
malicious-client resistance and migration have not been validated by these unit checks.

References:
- https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/encrypt
- https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Key_Management_Cheat_Sheet.html
