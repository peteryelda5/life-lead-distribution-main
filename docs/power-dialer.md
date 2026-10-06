# Power dialer

The portal navigation opens `/dialer.html` for the actual signed-in account. Support agent view never impersonates that agent's subscription or phone account. Agents see only their assigned leads and can select up to 1,000 across folders/pages of 500. Saving an outcome uses the existing atomic lead update and leaves assignment and folder unchanged.

## Plan and access

- $250 USD each month, three US local numbers, 5,000 shared connected minutes.
- Each completed call rounds up to a whole minute; unanswered calls count zero. Extra minutes cost $0.03, billed on the next invoice, or a final invoice after cancellation.
- Spending limit defaults to $50 and supports $0/$25/$50/$100. The database reserves the maximum call duration before issuing a single-use grant.
- Billing periods come from Stripe, rather than calendar months. Payment failures disable new calling. Cancellation lasts through the paid period, then releases only numbers created by this system.
- Test Stripe subscriptions cannot authorize real agent number purchases or calls. The Master account may explicitly acknowledge real Twilio charges for a test pilot.

## Configuration

Existing Supabase server key, Stripe secret/webhook keys and Twilio keys are server-only. `CRON_SECRET` authenticates the daily `/api/dialer/maintenance` job. Use the existing voice app URL `/api/dialer/voice`; it supports both the prior pilot and the new signed agent grants. Completed Number-leg callbacks use `/api/dialer/status-v2`. Incoming numbers use `/dialer-inbound.xml`; recording remains off.

Checkout automatically verifies and updates the existing Stripe webhook's event list, without replacing its signing secret. The live endpoint and matching live webhook secret must be configured when changing Stripe accounts/modes. Live subscriptions additionally require `DIALER_LIVE_BILLING_ENABLED=true`; leave unset for sandbox testing.

Apply `database/dialer-full-system.sql` once on a fresh database. On this project, migrations `agent_dialer_accounts_numbers_usage_billing` and `dialer_final_period_usage_aggregate` have already applied it. New tables expose no direct client permissions; server RPCs validate ownership/session and maintain call and invoice ledgers. Original pilot data is unchanged.

## Verification

Run `node tests/dialer-full.cjs` for mocked provider retry, pricing, ownership, grant signature and syntax checks. Database transactions verify isolation, minute rounding, callback replay and payment failure and roll back their fixtures.

Before live rollout, sign in as Master and an agent, complete two-step verification, run sandbox checkout, update payment method, cancel at period end and verify account status. Make a separately authorized real pilot call to a controlled phone and verify audio, callback duration and saved lead color. No verification script places calls or purchases numbers. Browser microphone and actual Stripe/Twilio deliveries require this live-user test.

Maintenance retries unfinished call durations, draft invoice fees and number release. Provider timeouts block duplicate number purchases and recover by the stored provider tag. A definitive failed purchase that did not create a provider number needs administrator review; retrying does not purchase twice. Renewal invoices pause finalization while usage is unresolved. A finalized invoice missing a usage quote returns an error for administrator review instead of silently adding a duplicate or guessing a charge.
