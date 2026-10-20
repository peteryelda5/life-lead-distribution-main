# Agent workspace, phase one

Keep Twilio as the voice provider while developing the LLD agent workflow. This release adds availability, Save & Call Next, persistent callback tasks and a supervisor view. It does not claim Five9 parity or change numbers, subscriptions, AMD, recording, or live monitoring.

## Agent behavior

- Ready permits new outbound calls. Incoming calls still require the existing Go online button and microphone permission. Break and Offline block new grants at the database and send new inbound calls through the existing voicemail flow. Selecting either during a call does not disconnect it.
- Dialing, On call and Finishing notes appear automatically. Heartbeats expire after 50 seconds in the supervisor view; a disconnected browser never stays Ready indefinitely. Availability is shared across browsers and refreshes, and stale clients cannot reset it with a heartbeat.
- Power Dialer has Save outcome and Save & Call Next. A failed save preserves the draft and never starts a batch. Save & Call Next checks due callback tasks before placing another batch; due tasks open the priority queue for individual review. With no due tasks, it starts the next selected batch after a successful save. There is no unattended dialing loop.
- Priority callbacks include missed inbound calls, voicemail, second answers, uncertain pickups, and scheduled callbacks. Opening a card or marking voicemail read does not resolve a task. Mark handled explicitly resolves it. Tasks survive refresh and do not duplicate on provider retries or repeated polling.
- Schedule callback applies to the displayed lead. The dialog displays the browser’s time zone. The server stores the exact instant. A callback can be scheduled up to one year ahead. Scheduling does not overwrite the lead’s notes or disposition.
- Matching lead cards are restricted to currently assigned leads. Ambiguous phone matches are shown separately. Reassigned leads disappear from the former agent’s scheduled/power queue.

## Supervisor scope and metrics

Master admins see all active agents/admins; division admins see their division and explicitly granted divisions; team leaders see themselves and direct members in the same division. Regular agents cannot access the endpoint or service-only database functions. UI visibility is not the authorization boundary.

The view refreshes every 15 seconds. Today means Eastern time. Calls placed require a provider call SID. Conversations count Power Dialer batches with a winning connection, not every phone pickup. Call minutes include machine answers, so they are not labeled talk time. Unresolved inbound counts remain until handled; seen/read state does not clear them. Failed calls come from recorded call status. This phase does not include appointment conversion metrics or listen/whisper/join.

## Release gate

Apply `database/dialer-agent-workspace.sql`, followed by `database/dialer-agent-incoming-status.sql`, to recovery first. Run `tests/dialer-agent-workspace.sql`, `tests/dialer-power.sql`, `tests/dialer-power-answer-recovery.sql` and `tests/dialer-incoming.sql`. Fixtures roll back. Then apply and verify on production, run security advisors, and deploy the matching code/assets together.

Local checks: `tests/dialer-operations.cjs`, `tests/dialer-parallel-dom.cjs`, `tests/portal-dialer.cjs`, and existing power, callback and incoming regressions. JSDOM/provider tests mock calls and do not verify live audio.

Before release, verify the browser → operations API → database → UI flow on the authenticated portal. Keep real headset/three-phone AMD and screening tests separate. No real calls are placed by the automated checks.
