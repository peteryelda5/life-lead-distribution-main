# Dialer flow improvements — October 28, 2026

Requested scope: reliability measurement, reusable calling sessions, one-click outcomes and optional continuation, retry timing and inline callbacks, then shared-agent overflow and adaptive pacing.

## Evidence

The October 27, 4:24 PM Eastern call ending 0991 recorded busy on both provider legs, zero connected seconds, and browser error 31603 at 7,469 ms while ringing. No provider alert identified why it was declined. This does not establish whether the recipient, screening, carrier, or device rejected it. Advanced Voice Insights was not enabled; no paid integration was activated.

A recent Power Dialer connection recorded 5,262 ms of synchronous AMD and an unknown result. Detection delay is verified; actual two-way-audio delay is not yet measured.

## Current changes

- Reuse the outgoing Voice SDK Device only for the same provider account, application, authenticated user and login session. Refresh its token before the next call, not during active audio. Rebuild after an error or identity change. Existing per-batch conference, signed single-use call grant, limits and cleanup remain. This is SDK reuse, not a persistent billed conference or persistent microphone stream.
- Record batch preparation, headset-ready, launch and lead presentation phases. Connection report shows scoped recent failures, busy results, decline events, detection times and overlapping/uncertain pickups. Samples are bounded and clearly labeled. Detection is not relabeled as proven human speech.
- One-click business outcomes save before advancing; optional continuous dialing waits five seconds after confirmed batch completion. Default is off. Errors, hidden tab, unavailable agent, unsaved conversation, due callback, exhausted queue or explicit Pause prevent automatic dialing. Pause does not hang up a conversation.
- Server checks prior provider-bound attempts by agent and normalized phone. Thirty-minute spacing and five attempts in a rolling 24 hours; retries of the same prepared batch exclude that batch's existing ledger entries. Unused grants do not count. Frontend retains cooldowns for the current session to choose eligible leads. Existing user lock prevents concurrent batches.
- Power Dialer due callbacks display inline with Open lead and explicit 15/60-minute rescheduling. Opening does not resolve the task. Rescheduling rechecks authenticated ownership and only updates unresolved visible tasks.
- Optional conservative pacing reduces line count after overlapping/uncertain pickups. It never raises the configured maximum automatically and is not a predictive campaign algorithm.

## Still gated

Shared-agent overflow is not implemented or enabled. It needs same-agency opt-in recipients, atomic agent reservation, provider-account routing, permitted temporary lead access without ownership transfer, connection acknowledgement, bounded fallbacks, and usage attribution. Do not forward a customer into another agent's call or grant broad lead access.

Full persistent agent conference, automatic pacing increases, and AMD tuning need controlled phone tests. No system can promise perfect classification or zero network/carrier errors. Do not enable the dormant twenty-number pool or paid diagnostics without the owner's go-live instruction.

## Controlled acceptance

Verify one human plus two voicemails, screening, two simultaneous human answers, failed destination/31603, SDK reuse across batches, Pause while speaking, Break and Offline during countdown, background tab, lost network, stale save conflict, due callback reschedule, thirty-minute retry and daily cap, and continued admin listen isolation. Record answer-to-agent audio timing separately from webhook/detection timing.

## Automated verification

Nine targeted suites cover portal regression, Power Dialer DOM flow, provider lifecycle and signed identities, preparation authorization, client health, operations ownership, availability, retry limits, and reliability reporting. Mocked providers place no real calls. The DOM suite verifies opt-in continuation, SDK reuse, one-click outcomes, repeated clicks, failed saves, background pause, retry cooldown, and conservative pacing.
