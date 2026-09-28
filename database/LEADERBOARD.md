# Live leaderboard

The web Leaderboard tab is available to active admins and MFA-verified agents. It shows only permitted divisions. Agents see their own division; admins use existing scopes. Customer data and raw closed-business permissions remain unchanged.

`public.live_leaderboard` is a security-invoker wrapper around a private, authorization-checked aggregation function. It exposes agent display names and production amounts, not client information. AP is annualized premium, not revenue or commission. Periods use the recorded close timestamp (`created_at`) and America/Detroit calendar boundaries. Weekly totals begin Monday. Monthly rankings include zero-production active agents; today's feed is capped at 50 while totals include all deals.

A trigger updates the three division-scoped `leaderboard_updates` counters after closed-business mutations and profile edits. These counters contain no sale or client data. Only this table is published to Supabase Realtime. RLS controls which counters a viewer can receive. Websocket events debounce a fresh authorized RPC read. A 30-second refresh also handles dropped events, date rollover and current permissions. Connection loss is shown explicitly, and returning to a visible tab or reconnecting fetches current totals. Leaving the tab or signing out removes its subscription and timers.

Verification SQL validates every active account's aggregate scope, rejects other divisions and unverified agents, checks RLS using the authenticated role, and verifies the database trigger inside a rolled-back subtransaction. Browser verification uses synthetic data and a mocked realtime transport to verify rendering, event handling, reconnect state and cleanup. It does not simulate a real user's authenticated websocket.
