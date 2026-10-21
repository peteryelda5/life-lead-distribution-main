# Face ID verification

This adds an optional WebAuthn second factor in place of the six-digit authenticator code. It does not replace the password at the start of a new sign-in. After a normal verified login, agents open the account menu → Face ID & passkeys → Set up Face ID. At future verification prompts, they can choose Use Face ID or enter the existing authenticator code.

The iPhone chooses Face ID or its device passcode. The website never receives face images or biometric templates. The authenticator code remains the recovery option. Other supported platform authenticators can use the same passkey flow.

## Security design

- Supabase validates the existing user JWT. The server derives the user, session, and assurance level; caller-supplied account IDs are ignored.
- Initial enrollment requires an already verified portal session. Registered public keys, one-time challenges, and session proofs live in private tables with RLS and no direct client or service-role table grants.
- SimpleWebAuthn verifies the signed response, exact production origin, relying-party ID, challenge, and required user verification. The account and current Auth session bind every challenge. Challenges expire after five minutes and are consumed once. The server enforces registration limits and challenge throttling.
- A successful signature creates a separate 12-hour portal proof for that existing Auth session. Supabase JWTs are not minted, edited, or relabelled as AAL2. Password-only sessions remain denied.
- Database policies and server API gates recognize either the existing TOTP verification or the server-held passkey proof. Existing role, agency, and ownership checks still apply.
- Disabled accounts, expired native sessions, expired proofs, and removed credentials lose Face ID authorization. Deleting a native session cascades its proofs and challenges. Removing a credential cascades its proofs. The existing agent MFA reset also removes passkeys before resetting authenticator factors.
- The Book of Business's separate unlock code is unchanged.
- Preview deployments cannot register or verify passkeys against production. No new secret or external authentication provider is required.

## Validation

- `node tests/portal-passkeys.cjs`: real ES256 registration and authentication responses; rejects wrong origins/challenges, missing device verification, tampered signatures, replay and another credential.
- `NODE_PATH=/tmp/lld-dialer-tests/node_modules node tests/portal-passkeys-dom.cjs`: explicit gesture, cancellation/code fallback, account switching, session binding and cleanup.
- `NODE_PATH=/tmp/lld-passkey-tests/node_modules node tests/portal-passkeys-local.cjs`: isolated PGlite/PostgreSQL 0.5.11 test engine with prior-schema fixtures; applies the actual migration and runs `tests/portal-passkeys.sql`. This does not replace testing against the full recovery schema.
- Existing MFA, notifications, navigation, dialer authentication and document API tests; syntax checks and dependency audit.

## Release gate

The owner explicitly approved applying the security changes to recovery and production and deploying them on October 21, 2026. Both recovery and production migrations and full-schema fixtures passed. The updated MFA reset function is deployed to both projects. Release order:

1. Apply `20261021165857_portal_face_id_verification.sql` to recovery; run the rolled-back `tests/portal-passkeys.sql` fixtures and security advisors against the full schema.
2. Apply the same migration to MAIN and rerun the fixtures. No existing credentials or users are migrated or enrolled automatically.
3. Deploy the updated `reset-agent-mfa` Edge Function, then publish the exact tested portal/server tree to Vercel Production.
4. Verify existing password + TOTP sign-in, Face ID enrollment, returning sign-in, cancellation, removal and permission scope on a real iPhone. The native Face ID prompt cannot be certified by DOM tests.

References: https://simplewebauthn.dev/docs/packages/server · https://supabase.com/docs/guides/auth/passkeys · https://support.apple.com/guide/iphone/iphf538ea8d0/ios
