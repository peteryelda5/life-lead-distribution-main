# Live Chat workspace

The chat layout uses a conversation list, central message thread, and contextual members/resources panel. On small screens a back button opens the list and a details button opens the side panel.

All/Unread and conversation search use the existing per-user metadata. Private conversation previews contain up to 240 characters of the most recent authorized message, plus sender ID and timestamp, from the existing membership-scoped list RPC. Media metadata is displayed as a photo/GIF or shared-document label. No public storage links or wider conversation access are introduced.

Own messages use blue bubbles; date separators, channel reply/reaction controls, media, send/retry and existing deletion permissions are retained. Search in the thread filters loaded messages only and is labeled accordingly. Channel pins come from the existing scoped metadata; private conversations do not inherit channel pins. The shared sales-process shortcut opens Agent Tools. Shared documents use the existing protected download handler and only files in loaded messages are listed. Member names are retrieved through the existing member-only RPC for private conversations.

Validation: chat creation/retry/search DOM tests run with the new layer loaded; workspace DOM tests cover filters, escaping, private/channel separation, details and mobile controls; existing message deletion, shared channel and media tests remain applicable. The rollback SQL test verifies list scope and real preview values without sending messages. The browser-only build excludes SQL and server files.
