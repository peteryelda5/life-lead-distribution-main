# Agent Dialer and Power Dialer — October 20, 2026

The portal navigation and page title are **Agent Dialer**. Its **Single-line dialer** workspace retains existing calls, notes and outcomes. The former three-line test screen is now **Power Dialer**, with assigned-lead folders, state filters, a selectable queue, caller ID, one to three concurrent lines, stable live cards and a lead-information panel. Existing `#power-dialer` bookmarks still work.

Power Dialer is visible to active agents and admins. Calling requires their existing dialer entitlement and an activated number. The $250 subscription and the five existing actual-cost exemptions are unchanged; no accounts, numbers, subscriptions or real calls are created by deployment. Accounts needing setup see a Numbers & billing link.

Each batch requires an agent click. The browser joins the conference before outbound calls start. Power Dialer requires answering-machine detection; cached clients requesting unfiltered fast connection receive a refresh message. Existing legacy test sessions can still be reviewed and stopped.

Clear human detections connect automatically without a recipient prompt or keypress. Detected machines and fax lines end without winning the headset; unclear pickups end with a qualified follow-up note. Other lines continue ringing. Detection can still misclassify a screening voice or a real person, so controlled carrier testing remains necessary.

One database-serialized winner gets the headset. Other unanswered phones are canceled. Already answered phones receive up to 15 seconds for detection; overflow messages receive a bounded 30-second window. A pickup racing a cancellation never falls back immediately to forced completion. Explicit Stop, expiry, lost heartbeat or access revocation still end all lines. A second confirmed answer hears the callback-number message and receives one timestamped follow-up note. A phone that picked up but ended before classification receives a distinct note stating that a live person was not confirmed. It is never labeled Uncalled. Late classifications can update history but cannot reopen a completed call; repeated callbacks cannot duplicate notes or overwrite agent edits. Notes remain scoped to the current lead assignee.

The connected lead opens automatically with details, notes, mute and end-call controls. Agents can minimize and reopen it without losing drafts; polling does not replace edits. A winner's outcome must be saved before continuing. Unanswered canceled leads stay in their folder and return to the selected queue as Uncalled. Confirmed and unconfirmed follow-ups are separately labeled and refresh their saved notes. Existing outcomes and folders remain intact; no batch redials automatically.

## Reliability and usage

- Basic Twilio Lookup validates numbering-plan format without paid lookup fields. It does not prove that a number is currently in service. Invalid or unavailable leads are skipped, with an explanation, while valid leads proceed.
- The three outbound requests run concurrently. Twilio can still queue them under the account's calls-per-second allowance.
- Definitive provider rejections close that line without stopping other leads. Ambiguous creation failures stop the batch and reconcile existing provider calls; they never retry call creation.
- Each outbound lead line has one `dialer_calls` usage row. Signed status events and cleanup update the same row, preserving billing idempotency. Standard reconciliation excludes direct Power Dialer legs; invoice settlement waits for their final usage.
- Caller ID, current assignment, signed-in session, entitlement and provider ownership are checked server-side. Reassignment between preparation and dialing prevents that lead from being called. Server-only tables and RPCs remain inaccessible to browser roles.
- Each phone leg ends within 30 minutes or the remaining minute allowance. Missing browser heartbeats stop the batch. Unconfirmed cleanup remains visible and blocks another batch until reconciled.
- Single-line calls reuse recent verified billing state for up to two minutes. Repeated historical-error notification scans were removed from the call-start path.
- Status polling begins only after batch preparation succeeds. Cancellation during preparation waits for the result and closes the batch without launching calls.
- Online callback heartbeats refresh billing verification before it expires. Fresh checks are reused for two minutes; revoked access and verification outages still prevent extending availability. Going offline does not depend on billing.

## Release and verification

Apply `database/dialer-power-leads.sql`, `database/dialer-power-followup-notes.sql`, then `database/dialer-power-answer-recovery.sql` before deploying the matching code. It adds the lead batch and usage integration while preserving the old test endpoints for cached exempt-account clients. Keep the three browser asset version bumps together.

Run the rollback-only `tests/dialer-power.sql` and `tests/dialer-power-answer-recovery.sql` on recovery and production. It creates only synthetic fixtures and rolls them back. It covers paid-agent/admin access, session ownership, duplicate requests, single/parallel exclusion, one winner, per-leg rounded usage, repeated and late callbacks, invalid numbers, reassignment, no pilot test cap and private permissions.

Browser verification: `tests/dialer-parallel-dom.cjs` loads the actual portal and Power Dialer code in JSDOM with mocked calls. It checks folder/states, selection, escaping, microphone failure, three-line launch, stable cards, winner details, preserved drafts, failed-stop recovery, required outcome, setup guidance and account cleanup.

Provider and entitlement verification: `tests/dialer-parallel.cjs`, `tests/dialer-power.cjs`, `tests/dialer-manual.cjs`, `tests/dialer-full.cjs`, plus existing incoming, callbacks, actual-cost and portal tests. Provider requests are mocked; no real calls or charges are generated.

A controlled live audio check remains necessary with an agent and three phones they are authorized to call: use Answering-machine detection on, answer one phone, confirm two-way audio and the matching lead card, end the call, save its outcome, then check call history/usage. Repeat with an answering machine, call screening, two simultaneous pickups and a missed incoming callback. Verify that no recipient is asked to press a key, machine or unclear detections do not open the conversation card or stop other ringing lines, and follow-up notes are retained. Automated checks cannot establish actual headset, carrier or account CPS performance.

## Publication status

Recovery migration and rollback verification passed. Peter explicitly approved publishing this change set to the existing public repository and deploying to LLD Portal on October 20, 2026. Apply and verify the production migration before merging, then verify the Vercel production deployment and browser asset versions. The release PR records the production verification result.

Provider references: [call state and cancellation](https://www.twilio.com/docs/voice/api/call-resource), [iOS screening behavior](https://www.twilio.com/en-us/blog/developers/tutorials/product/detect-ios-call-screening-amd-transcriptions).
