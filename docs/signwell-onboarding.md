# SignWell onboarding

Production secrets: SIGNWELL_API_KEY and SIGNWELL_TEMPLATE_ID. Signing defaults to test mode and only the verified Master can send tests. Set SIGNWELL_LIVE_SIGNING_ENABLED=true only after both test signatures, fields, PDF/audit download and portal status have been checked. Test documents are not live agreements.

The existing authenticated, same-origin onboarding endpoint selects SignWell when both variables exist. Existing DocuSign configuration and records remain intact; Master Agreement records combines both providers and routes historical refresh/download requests to the original provider.

Template must have exactly Agent (order 1) and Agency (order 2), sending order enabled, and unsigned required signature fields for each. Every creation revalidates the template. Agency signer is fetched from the active Master profile server-side. Client inputs cannot select other signers.

Records are in portal_signwell_agreements, RLS enabled with no public/client grants. One current record per user/environment prevents parallel duplicate sends. A creation timeout or failed database save leaves a creating record requiring administrator review, rather than retrying a potentially delivered agreement. No automatic resends.

Status refresh reads the authoritative provider document; completed records require both recipients signed and matching test/live mode. Completed PDFs include audit_page=true and are saved to the existing private onboarding-agreements bucket. Downloads use 60-second signed URLs. There is no separate SignWell certificate file; audit trail is in the signed PDF.

User refresh and daily authenticated reconciliation update status and retry archival. No unauthenticated signing webhook is exposed. Overview shows stored status; Master Refresh status checks provider status.

Run node tests/signwell.test.cjs for mocked validation, signing and duplicate guards. Real provider/template validation and a full two-signer test are still required before live enablement.

## Controlled live verification

Set `SIGNWELL_MASTER_LIVE_TEST_ENABLED=true` in Production while leaving `SIGNWELL_LIVE_SIGNING_ENABLED` unset/false. This uses real SignWell email delivery (`test_mode=false`) but only the authenticated Master can create an agreement. Agent/admin signing stays disabled in both the UI and server. The Master enters a separate Agent email they control, then countersigns at their agency email. Live records are separate from sandbox records. Review the completed PDF and audit before setting the full rollout flag.
