# Dialer audit — October 27, 2026

## Release scope

Existing dialer fixes are authorized for deployment. The owner explicitly asked to keep the new 20-number shared Vivid Life pool OFF until a later instruction. Its database configuration must retain `enabled=false` and `provision_authorized=false`. No numbers were purchased and no rental charges were started during this work.

## Changes

- Expired, unused single-line call reservations are closed as canceled. Provider-bound calls, Power Dialer legs, recent reservations, and rows with duration evidence are excluded. Production inspection found ten unused reservations dating from October 7–20; these were not evidence of active dropped calls.
- Power Dialer diagnostics and transcripts use the provider account pinned to the call. This also supports the future agency-owned pool without querying an agent's personal provider account by mistake.
- Server error logs distinguish upstream timeouts, network failures, invalid JSON, and handled errors without logging raw upstream payloads.
- Prepared shared caller IDs are allocated per lead, with separate IDs within a batch, area-code preference, repeat-lead rotation, transactional allocation, replay protection, and exact callback mappings. ZIP-code geocoding is not implemented.
- Shared callbacks forward to the agent's existing personal Twilio number, preserving its current availability/voicemail implementation. Unknown or reassigned callbacks go to the configured agency fallback. Forwarding has additional usage costs. The agency provider account bears shared-pool costs.
- Provisioning supports exactly 20 slots per agency, checks the account's US local rental price against $1.15 per number/month, requires a separate service-side authorization flag, and never automatically repeats an uncertain purchase POST.
- Test fixtures now reflect the current MFA and all-agent access behavior. Older SQL tests have explicit outer rollback transactions in addition to their original fixture cleanup.

## Verification

27 JavaScript test files passed, including mocked DOM/browser tests, signatures, permissions, callbacks, voicemail archival, call races, notes, billing, transcripts, monitoring, and provisioning failure cases.

10 recovery-database SQL scripts passed: incoming calls; agent workspace; conversations; legacy parallel pilot; legacy fast-connect compatibility; at-cost access; lead-based power dialer; answer recovery; monitoring; shared pool. All fixtures roll back and none of these tests place provider calls. Legacy fast-connect tests cover compatibility; new lead-based batches still require machine detection.

Read-only production checks found:

- No active Power Dialer batches or active listeners at inspection time.
- No missing follow-up-note markers among secondary/uncertain-answer outcomes in the preceding seven days.
- 30 Power Dialer legs in the seven-day sample; available detection timings had a median of 2,788 ms and a maximum of 5,249 ms.
- Short completed calls do not establish whether a human hung up, screening answered, or audio failed. No new claim of a proven dropped-human root cause was made.
- One earlier generic account endpoint error lacked enough information to identify its cause; improved classification is for subsequent incidents.

## Remaining live acceptance tests

Use consenting controlled phones with an agent signed into the portal. Do not call customer leads as tests.

1. One human answers: two-way audio and the correct lead card appear; other unanswered leads return correctly.
2. Two humans answer close together: exactly one joins the agent; the second receives the configured overflow handling and a single durable follow-up note/task.
3. Voicemail and phone screening: record the actual classification, connection delay, call IDs, and outcome. Do not equate automated mocks with detection accuracy.
4. Admin listen: verify audio is audible to the admin, admin microphone cannot be heard, and Stop listening leaves the customer call connected.
5. Callback while Ready, Busy, Break, and Offline: correct agent/lead; voicemail and missed-call records as appropriate.
6. Stop/reload/network interruption: no orphan provider calls, duplicate batches, or silent loss of pickup evidence.

Admin listening currently supports connected Power Dialer conferences, not ordinary single-line calls. Carrier reputation/spam-label testing and live audio are not established by this audit.

## Future shared-pool activation

Wait for the owner's explicit go-live instruction. Re-check number availability and current rental pricing, provision up to the approved 20 total slots, verify inbound webhooks, and run controlled cross-account callback tests before enabling agency-wide rotation. Keep a clear opt-out/suppression policy across all caller IDs. Turning off outgoing rotation must preserve callbacks to numbers already used; do not release numbers merely to stop rotation.
