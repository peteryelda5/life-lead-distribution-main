# Security maintenance

This is a security baseline, not a claim that the portal is vulnerability-free.

## Access model

| Identity | Intended access | Enforcement |
| --- | --- | --- |
| Anonymous | Login, recovery and public training assets; no lead/client records | Auth provider, PostgREST pre-request guard, grants and RLS |
| Password-only session | Own account bootstrap and verification flow | MFA guard; no business data before verification |
| Verified agent | Own assigned leads, own business, permitted agency resources and member conversations | Live session, active profile, onboarding, ownership and agency predicates |
| Verified team leader | Agent access plus scoped team/upload capabilities; direct-agent name edits and disable-only account access | Dedicated database scope checks; no global admin powers |
| Verified agency admin | Authorized agency management plus own assigned work | Database-managed agency grants and action-specific checks |
| Verified super admin | Owner administration and explicitly permitted cross-agency operations | Server-side role/profile checks, never browser flags |
| Leaderboard API consumer | Allowlisted aggregate ranking fields | Hashed, revocable scoped key; per-key rate limit; field-by-field response |
| Provider webhook / cron | Only the callback or maintenance operation | Provider signature or cron secret, replay/idempotency protections |
| NOVA bridge | Separate owner Google identity integration | Separate security boundary; do not assume portal MFA covers it |

## Rules for every change

- Validate identity server-side; check live session, active account, MFA, onboarding and resource scope. A valid JWT alone does not prove a session is still active.
- Never authorize using user-editable metadata, request-supplied user IDs, or client-side role flags.
- New sensitive tables need RLS and explicit ownership/scope policies. Keep MFA and onboarding policies restrictive. Review both USING and WITH CHECK.
- SECURITY DEFINER is exceptional: fixed search_path, explicit grants and authorization checks are required. Keep server-only wrappers unavailable to anonymous/browser roles.
- Privileged credentials stay in server environment variables. Publishable Supabase keys are intentionally public. Never log tokens, passwords, recovery links or customer payloads.
- Validate input type, bounds and allowed actions on the server; use SQL parameters. Escape text at DOM output. Reject unsafe URLs and server-side redirects.
- Price, credit, caller identity and access must be derived/verified server-side. Verify callback signatures and make repeat delivery safe.
- Each new public or expensive endpoint needs a documented rate/abuse limit and fail-safe response. Do not rely on process memory for distributed limits. Preserve call cleanup and legitimate callbacks.
- Storage requires size/MIME limits and ownership policies; use short-lived signed links for private documents and recordings. MIME allowlists do not replace malware scanning.
- Browser static output is built by scripts/build-public.cjs. Never publish lib/, SQL, tests, environment files, config or repository metadata as static files.
- Run the security CI checks and relevant negative tests before deployment. Schema changes also require transaction-isolated SQL tests and live advisors.
- Pin dependencies and commit lockfiles. Review browser CDN and Edge dependencies separately from npm audit.
- Document unverified controls and residual risks. Never describe a source scan or unit suite as a completed penetration test.

## Verification

The security workflow runs on pushes and pull requests. Provider calls in unit tests are mocked; do not use live clients, charge cards, place calls or send notifications as part of automated tests. Run SQL fixtures in a transaction that rolls back. Recheck live deployment routes and permissions after relevant changes.

Report vulnerabilities privately to the repository owner rather than posting credentials, exploit details or customer data in public issues. Rotate confirmed leaked credentials with their dependent integrations; do not rotate production credentials speculatively.
