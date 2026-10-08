# Focused onboarding and DocuSign

The portal uses layout C: local checklist navigation and a focused task panel. Existing first-login letter receipts and onboarding acknowledgements are unchanged. Course/study/exam progress is self-reported.

## Setup

- Production Vercel variables `DOCUSIGN_CLIENT_ID` and `DOCUSIGN_CLIENT_SECRET` remain server-only.
- `DOCUSIGN_ENVIRONMENT` defaults to `demo`. Developer account consent uses `account-d.docusign.com` and demo API accounts only.
- Registered callback: `https://www.lldportal.com/api/docusign/callback`.
- Master opens Onboarding → Compliance agreement → Master DocuSign setup → Connect DocuSign. Authenticate using the developer account, not the live account.
- Import/copy the reviewed agreement into that developer account. Live and demo template IDs are different.
- Remove internal drafting notes, correct section numbering, and do not ask new agents to sign the termination-only Exhibit A. Review the effective-date field before use.
- Configure exactly two signer roles: blank Agent (order 1) and fixed Agency name/email (order 2). Add signature tabs to both roles. Load templates in the portal, review, confirm and select the exact template.
- Sandbox signing is restricted to Master. Starting a test envelope is an explicit Sign with DocuSign button action; no envelopes are sent by deploying the code.

## Completion and storage

Completion is taken only from DocuSign's authenticated envelope API, never from the return URL. Refresh signing status archives both the combined signed PDF and Certificate of Completion in the private `onboarding-agreements` bucket. The daily 07:00 UTC reconciliation job processes up to 20 oldest unchecked agreements, in batches of four, and retries incomplete downloads. For a large rollout, increase reconciliation capacity or add a verified DocuSign Connect webhook; do not promise instant background updates.

Tokens are AES-256-GCM encrypted using a key derived from the server client secret. Secret rotation requires reconnection. OAuth uses one-use database state, an HttpOnly Secure SameSite=Lax cookie, PKCE, and a 10-minute expiry. Refresh uses a database lease. All new tables are service-only with RLS enabled and client privileges revoked; only authenticated AAL2 active portal users with a valid session can call the API. Agents can only access their own agreement. Master archive access is separately checked. Download links expire in 60 seconds.

The unique user/environment agreement constraint prevents duplicate sends. An uncertain envelope-creation failure remains `creating` and requires administrator reconciliation using its DocuSign transaction ID (the agreement UUID); do not remove it or resend without checking DocuSign first.

## Live release gate

Do not enable live signing until a complete sandbox test covers Agent signature, Agency countersignature, completion verification, PDF/certificate downloads and agent isolation. Confirm DocuSign API plan eligibility and promote the integration key through DocuSign go-live. Configure the production client secret and callback, set `DOCUSIGN_ENVIRONMENT=live`, reconnect to the correct live account, and choose/review the live template. Only then set `DOCUSIGN_LIVE_SIGNING_ENABLED=true`. Demo completion never counts as a live record.

## Verification

`node --test tests/docusign.test.js` covers crypto, sandbox default, account URL checks, CSRF, request gating, Master access and focused step rendering. End-to-end signing requires interactive account consent and a reviewed sandbox template and is not verified by these unit tests.
