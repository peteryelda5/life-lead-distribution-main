# Division live chat

A Discord-style text chat tab with separate general/deals channels per authorized division. Existing profile, division grants, active/archive state, and agent MFA determine access. Master sees every division; scoped admins see only permitted divisions; agents see their own division.

- `/deal`: enter credited agent, carrier, policy type, monthly premium and application date. Chat deals are standalone; no existing-lead link, policy/application number or private notes fields. Agents can credit only themselves; admins select eligible agents in the selected division.
- `/leaderboard`: open the existing leaderboard in this division.
- `/help`: command reference. Arrow keys, Enter/Tab, Escape supported.
- Text: Enter sends; Shift+Enter inserts newline. Drafts are in-memory per room, cleared on logout/account change. Retry uses the same request UUID. Maximum 4,000 characters / 30 messages per minute per user.

## Storage and live events

`public.chat_messages` has SELECT-only client grants and division RLS. All writes go through checked private functions with invoker public wrappers. No anonymous grants. Author ID/name are server supplied. The table is added to supabase_realtime, with authenticated tokens supplied explicitly in the client. Events trigger a scoped refresh; reconnect, visibility, and a 15-second fallback catch missed messages. Leaving the tab removes the subscription. The view loads 100 messages initially and supports up to 1,000 recent messages to bound DOM/network costs; older records remain stored.

Closed Business insert/update/delete triggers create/update a deal announcement. Only agent identity, carrier, policy type, and premium are shared. Removal withdraws the card. Client details, policy numbers, and notes are excluded. Existing historical sales are not backfilled as new announcements. Existing close-lead buttons also trigger announcements.

`chat_close_deal` locks the lead, validates the caller and assigned agent, writes Closed Business + lead status + audit atomically, and returns the existing sale ID on retry. The existing unique lead_id constraint adds duplicate protection. Existing leaderboard triggers update production automatically. No production encryption claim is made; this is authenticated division-scoped chat, not end-to-end encrypted messaging.

## Verification

- Applied `database/live-chat.sql` to project yfuuigykpihoetgaefmu.
- `database/verify-live-chat.sql`: real authenticated database role, every active admin/agent scope, message retry, forged direct inserts denied, unauthorized search/send denied, agent MFA, own-lead sale + idempotency + safe card. All writes rolled back.
- Additional rollback check: Jonah could record permitted owner/Vivid agent sales with correct credit, and could not record Legacy sales.
- `node tests/chat-browser.cjs`: full app with synthetic fixtures and mocked REST/realtime transport; commands, keyboard, send/error retry, event refresh, deal form/card, escaping, room drafts, mobile overflow and cleanup.
- Existing leaderboard, agent restore, team UI and dashboard tests passed.
- Realtime publication and RLS verified on live database; no actual signed-in user websocket was used in browser tests.

Website deployment only. The separately bundled Windows trial must be rebuilt to include this UI.

The leaderboard signal trigger explicitly scopes its three counter updates to work with PostgREST safeupdate. Verified standalone saves and counter signals under the authenticated database role; fixture sale rolled back. The connector does not permit loading the safeupdate library, so that session configuration could not be reproduced in the database test.

## Removing deals

Admins can remove a closed deal from its chat card or the Closed Business detail dialog. The server checks current admin division grants, locks the record, writes an audit entry, deletes the sale and reopens a linked lead (assigned to an active same-division agent, otherwise returned unassigned to its pool). Standalone deals have no lead to reopen. Existing triggers withdraw the chat card and invalidate leaderboard totals. Agents cannot remove closed deals. Repeated removal is harmless. Database rollback checks verified cross-division denial, agent denial, premium subtraction, withdrawn cards and linked-lead reopening; browser verification covers confirmation and admin-only controls.
