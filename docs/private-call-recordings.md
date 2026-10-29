# Private call recording — controlled test

Audio capture uses Twilio **Media Streams**, not Twilio Recordings. The existing
single-call, conference, and monitor TwiML stays `record="do-not-record"`. This
feature never creates a provider Recording, downloads one, or deletes one. Twilio
still transports/processes the live call and keeps its ordinary call metadata.

## First test

Only the master account can start capture, and only on its own connected Power
Dialer session whose winner is the owner-provided test phone ending 3969.
Capture is manual, requires confirmation that everyone agrees, and lasts at most
10 minutes. No automatic agency-wide recording is enabled. New conversations,
not historical unrecorded calls, can be captured.

1. In Power Dialer, call the owner-provided test phone and answer.
2. In **Private recording test**, confirm consent and start recording.
3. Speak on both ends, then stop recording or end the call.
4. Finish the batch, open **Call recordings**, refresh, and play the entry.
5. Confirm both voices, duration, and the **No Twilio recording found** result.
   This check reads the agent and winner call Recording lists; it creates none.

## Data handling

The signed WSS handshake and short-lived, one-use stream grant bind capture to the
stored account/call. The server requests `both_tracks` on the agent call. Inbound
is the agent channel, outbound is the other conference audio; live listeners are
muted by the existing monitor flow. Media stays out of application logs.

Timestamp-aligned mu-law audio becomes stereo PCM WAV. Ten-second pieces are
uploaded to the private `dialer-recordings` bucket, with hashes in the database.
Finalization verifies each part and assembles one playable WAV in the same bucket.
Parts are retained for recovery (roughly doubles audio storage). There is no
separate off-site backup or retention/deletion policy in this test release.

Browser roles cannot read the tables or bucket directly. Playback uses an
authenticated server endpoint, active session checks, the existing agency/team
scope, an audit entry, and a 15-minute signed URL. Do not share playback URLs.

A broken stream/storage write does not send call-control commands. Recovery runs
every five minutes and marks recovered audio partial. A crash can lose the last
unsaved window; partial recordings are not presented as complete. This test has
no automatic stream restart. Vercel hosts the receiver with an 800-second timeout;
capture stops at ten minutes. Streaming, compute, storage and egress are billable.

## Checks before wider enablement

Controlled physical phone test; realistic-length call; stop/end/connection-loss
recovery; both audio channels; no Twilio saved Recording; playback authorization;
agent-visible recording state and consent/disclosure policy; storage retention;
capacity and cost checks. Single-line/inbound recording and automatic agency-wide
capture are intentionally not enabled by this test release.
