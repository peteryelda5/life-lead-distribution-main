# Conversation assistant

The agent can start a two-track transcript after connecting a call and confirming the client's agreement. The conversation panel labels utterances You and Client. Final utterances arrive through signed Twilio callbacks and appear on the next 2.5-second refresh. The panel retrieves the latest 250 statements so long calls stay responsive; the AI summary uses the full provider transcript. This is near-real-time phrase transcription, not guaranteed word-by-word captions.

Supported: Power Dialer winner, single-line and manual calls, and answered incoming callbacks. The server resolves the actual active PSTN leg from the authenticated user and source record. It never accepts a provider Call SID from the browser. No transcript starts during ringing, screening, or an unconnected parallel leg. Consent is required anew for every call. Stop transcript ends transcription without hanging up. It cannot be restarted for that same call.

Twilio Conversation Intelligence (classic) provides the summary. An account-scoped service named `lld-agent-conversations-v1` is created on explicit setup/start, with AutoTranscribe=false, DataLogging=false and AutoRedaction=true. Only the published Summarization operator is attached. This does not automatically transcribe existing recordings or enable audio recording. Each account, including actual-cost subaccounts, uses its existing credentials. No new AI key is exposed to the browser. Summary API access is restricted to the same account, transcript and pinned operator. Generative text is fetched unredacted under owner-only access because the provider redacts the whole generated output otherwise.

Summaries remain editable drafts. Adding one appends to the currently matching lead's notes draft; the agent must save their normal lead outcome. The feature does not change outcomes, follow-up notes, or lead assignment. Incoming/manual conversations without a pinned lead do not offer automatic note insertion.

Storage and delivery:

- `dialer_conversations` and `dialer_conversation_lines` have RLS enabled and no browser-role privileges. The MFA/origin-protected server endpoint always scopes reads to the authenticated owner and live mode.
- Atomic claims prevent duplicate paid streams. An uncertain provider creation is reconciled by its deterministic name rather than blindly repeated.
- Twilio webhook signatures and account/call/transcript binding are verified. Final event sequence IDs deduplicate callbacks. Late start/content events do not resurrect a stopped stream.
- Text renders as text, never HTML. Account changes remove the panel. Recent transcripts show only the signed-in agent's most recent 30 conversations.
- Conversation text and summaries expire after 30 days. The five-minute maintenance job removes the corresponding Twilio CI transcript and the portal copy; failed provider deletion is retried before deleting the portal tracking record. User-added lead notes follow the existing lead retention behavior.
- Provider status/summary checks are limited to once per 15 seconds per stored conversation during active reads. Background maintenance reconciles the last two hours.

Twilio metered transcription and AI charges apply to the provider account; existing dialer subscription prices, exemptions and spending rules are unchanged. The start UI discloses charges and text processing. Do not start before consent or capture payment details. No controlled phone call has been verified solely by unit or database tests.

References checked 2026-10-20:

- https://www.twilio.com/docs/voice/api/realtime-transcription-resource
- https://www.twilio.com/docs/voice/twiml/transcription
- https://www.twilio.com/docs/conversation-intelligence-classic/api/service-resource
- https://www.twilio.com/docs/conversation-intelligence-classic/api/prebuilt-operator-subresource
- https://www.twilio.com/docs/conversation-intelligence-classic/api/operator-attachment-subresource
- https://www.twilio.com/docs/conversation-intelligence-classic/api/transcript-operator-results-subresource
- https://www.twilio.com/en-us/voice/pricing/us

Validation: backend/DOM regression suites and SQL rollback tests cover ownership, consent, active-call validation, duplicate and uncertain starts, signatures, provider binding, ordering, speaker mapping, stopped-state monotonicity, XSS, draft review and new-call consent reset. Live audio, real provider transcript delivery and screening require the controlled Pro5 phone test.
