# Power dialer

## Parallel pilot for Master and existing $0 accounts (October 13, 2026)

The **3-line pilot** tab is visible to Master and the five existing enabled actual-cost exemptions, subject to current profile role and account access. It calls one to three distinct,
consenting test phones; it is not yet a lead-list campaign mode. The browser joins
a two-participant conference first. A signed provider join event must confirm the
agent's audio connection before the UI can launch the outbound calls. Each call
uses synchronous Twilio AMD. A database row lock chooses exactly one human winner;
voicemail/fax/unknown end the test leg, and a second detected human receives an
explicit test-complete message. Live lead campaigns and automatic pacing require
an overflow/abandonment design and measured audio/detection results before rollout.

The server checks MFA, active session and eligible account identity, active caller-ID ownership,
distinct destinations, and current Twilio Voice Pricing for standard-rate US
destinations at no more than $0.014/minute. Test consent and provider-charge
acknowledgements are required. No call, number purchase, subscription change or
automatic repeat occurs merely by opening the tab. Provider calls are created only
after **Start test** and a verified conference join.

Each batch reserves $0.50 of a conservative $5 rolling 24-hour allowance, with a
maximum of ten tests. Reservations are not refunded or collected as charges. Phone
legs have a 20-second ringing timeout and a 90-second time limit; the browser Dial
has a 120-second time limit. The allowance is a test-volume control, not a guaranteed
tax-inclusive provider bill cap. Every call leg is tracked separately, and the UI
labels its duration-based cost as an estimate. The $0 accounts still pay no monthly subscription fee. Their browser tokens,
pricing checks, outbound calls, conferences and cleanup use their own existing
Twilio subaccount. Existing actual-cost monthly invoices collect that subaccount's
total provider usage, including pilot usage, without markup. Payment and provider
setup must be complete before starting; opening the tab does not perform setup.
Cleanup remains pinned to the account that started the call even after access is
revoked. Standard subscription accounts are not included.

`dialer_parallel_sessions` and `dialer_parallel_legs` are service-only, with RLS and
no anon/authenticated table or RPC privileges. Both existing incoming/outgoing busy
guards share the pilot's per-user lock. Call creation is claimed once per leg; an
ambiguous provider failure stops the batch without retrying call creation. Provider
webhooks validate the full signed URL, account, call identifier and destination.
The browser refreshes its lease, and the minute-based CRON_SECRET-protected
`parallel-maintenance` job stops expired/disconnected sessions. Stop-all also stops
the browser leg. Completed provider callbacks preserve terminal status across late
events. Supabase migrations: `add_owner_parallel_dialer_pilot` and `extend_parallel_pilot_to_actual_cost_accounts`.

Checks: `tests/dialer-parallel.cjs`, `tests/dialer-parallel-dom.cjs`, and the recovery
rollback fixtures `tests/dialer-parallel.sql` and `tests/dialer-parallel-at-cost.sql`. Run DOM tests with the same JSDOM
runtime used by the other portal tests. No automated test makes a real phone call.

Controlled acceptance test: refresh the portal as Master, open **Power Dialer →
3-line pilot**, select an active caller ID, enter three phones whose owners expect
the test, and check both acknowledgements. Test one human plus two voicemails,
two simultaneous human answers, Stop all calls while ringing, browser closure,
audio both ways and displayed results. Actual provider AMD latency, classifications,
webhook delivery, pricing API access and audio remain unverified until this test.

The portal navigation mounts the Power Dialer inside the portal for the actual signed-in account. Support agent view never impersonates that agent's subscription or phone account. Agents see only their assigned leads and can select up to 1,000 across folders/pages of 500. Saving an outcome uses the existing atomic lead update and leaves assignment and folder unchanged.

## Plan and access

- $250 USD each month, three US local numbers, 5,000 shared connected minutes.
- Each completed call rounds up to a whole minute; unanswered calls count zero. Extra minutes cost $0.03, billed on the next invoice, or a final invoice after cancellation.
- Spending limit defaults to $50 and supports $0/$25/$50/$100. The database reserves the maximum call duration before issuing a single-use grant.
- Billing periods come from Stripe, rather than calendar months. Payment failures disable new calling. Cancellation lasts through the paid period, then releases only numbers created by this system.
- Test Stripe subscriptions cannot authorize real agent number purchases or calls. The Master account may explicitly acknowledge real Twilio charges for a test pilot.

## Configuration

Existing Supabase server key, Stripe secret/webhook keys and Twilio keys are server-only. `CRON_SECRET` authenticates the daily `/api/dialer/maintenance` job. Use the existing voice app URL `/api/dialer/voice`; it supports both the prior pilot and the new signed agent grants. Completed Number-leg callbacks use `/api/dialer/status-v2`. Incoming numbers keep `/dialer-inbound.xml`, now a signed GET/POST rewrite to `/api/dialer/incoming`. Live conversations are not recorded. The voicemail flow records only after its greeting and beep.

Checkout automatically verifies and updates the existing Stripe webhook's event list, without replacing its signing secret. The live endpoint and matching live webhook secret must be configured when changing Stripe accounts/modes. Live subscriptions additionally require `DIALER_LIVE_BILLING_ENABLED=true`; leave unset for sandbox testing.

Apply `database/dialer-full-system.sql` once on a fresh database. On this project, migrations `agent_dialer_accounts_numbers_usage_billing` and `dialer_final_period_usage_aggregate` have already applied it. New tables expose no direct client permissions; server RPCs validate ownership/session and maintain call and invoice ledgers. Original pilot data is unchanged.

## Verification

Run `node tests/dialer-full.cjs` for mocked provider retry, pricing, ownership, grant signature and syntax checks. Database transactions verify isolation, minute rounding, callback replay and payment failure and roll back their fixtures.

Before live rollout, sign in as Master and an agent, complete two-step verification, run sandbox checkout, update payment method, cancel at period end and verify account status. Make a separately authorized real pilot call to a controlled phone and verify audio, callback duration and saved lead color. No verification script places calls or purchases numbers. Browser microphone and actual Stripe/Twilio deliveries require this live-user test.

Maintenance retries unfinished call durations, draft invoice fees and number release. Provider timeouts block duplicate number purchases and recover by the stored provider tag. A definitive failed purchase that did not create a provider number needs administrator review; retrying does not purchase twice. Renewal invoices pause finalization while usage is unresolved. A finalized invoice missing a usage quote returns an error for administrator review instead of silently adding a duplicate or guessing a charge.

## Incoming callbacks and voicemail (October 13, 2026)

Agents click **Go online** in Power Dialer and allow microphone access. A separate incoming-only Voice SDK device registers an identity unique to their account and browser. A 20-second heartbeat keeps a 65-second availability lease; closing/leaving the dialer, a busy call, an unsaved outcome, or a revoked session routes callers to voicemail. Only one browser is rung. A shared database lock prevents incoming and outgoing calls from being reserved simultaneously, including calls started in different browser windows.

An available agent rings for 25 seconds. Declined, unanswered, busy and offline callbacks hear “Please leave your name, number, and a message after the tone,” followed by a beep and up to two minutes of voicemail. Answered live calls are capped at 30 minutes and are not recorded.

**Callbacks & voicemail** lists incoming numbers, time, dialed number, answered/missed status, and all matching currently assigned leads (up to 20). The matching name and phone are clickable, with a folder/state/email preview.
**Open lead card** opens the existing calling workspace with contact details,
all imported columns and saved notes. Matching supports valid formatted US numbers
and the same unambiguous imported phone columns as outgoing calls. Assignment is
rechecked when opening the card. No match shows an explicit message, and multiple
matches show separate choices. Existing callbacks benefit immediately.
A match is never drawn from another agent's leads. Duplicate matches require the agent to choose. A portal badge counts unreviewed callbacks; playing a voicemail or marking the callback reviewed clears it. No email, SMS or external notifications are sent.

Voicemail webhooks validate the provider signature and recording ownership, download only a constructed Twilio recording endpoint, then copy the audio to the private `dialer-voicemails` bucket. The provider copy is removed only after the archive and database reference succeed. Playback requires the owning agent's active MFA session; no public recording URLs are exposed. A five-minute authenticated maintenance job retries incomplete recordings and provider-copy cleanup.

Incoming records use a separate callback ledger. This release does not change subscription prices or existing outbound minute accounting. Actual-cost accounts continue using their existing provider usage billing.

### Verification

- `node tests/dialer-incoming.cjs`: signed legacy/new webhooks, voicemail routing, completed calls, private audio and provider cleanup, incoming-only tokens, owner/MFA checks.
- `NODE_PATH=/tmp/vivid-notes-tests/node_modules node tests/dialer-callbacks-dom.cjs`: real dialer DOM with simulated SDK calls; online controls, matched lead, answer/mute/hangup, busy/away handling, renewal and account cleanup.
- `tests/dialer-incoming.sql`: recovery-only rollback fixtures for presence, callback replay, busy/offline routing, lead isolation and both outgoing grant paths. No real calls are placed.
- Real microphone/audio and provider delivery still require a controlled phone test: go online, call the displayed caller ID from another phone, answer and verify both directions; then go offline, leave a message and play it from the callback inbox.
