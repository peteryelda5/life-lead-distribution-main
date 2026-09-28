# Chat collaboration and leaderboard history

Apply `chat-social.sql` and `leaderboard-periods.sql` before serving the updated frontend.

Chat adds authenticated unread counters per workspace/channel, explicit member mentions, same-channel reply references, admin-managed links to division sales scripts, and four reactions on closed-deal announcements. Read cursors only advance when the active visible channel is at the bottom. The main navigation badge uses RLS-filtered realtime inserts with a 15-second fallback; per-channel metadata refreshes with the existing message subscription and fallback. No browser notification permission is required.

The private read/reaction/pin tables have RLS enabled and no client table grants. Public invoker RPCs delegate to scoped definer functions with empty search paths. Agents retain their division and MFA requirements. Existing admin scope grants apply. No private lead/customer fields are included in the social metadata.

Leaderboard periods are Today, This Week (Monday–Sunday), This Month, and Previous Months, using America/Detroit boundaries. Previous months with recorded sales or imports are offered automatically. Monthly imports remain monthly-only: they are not fabricated into daily/weekly production or individual deal cards. Missing imported deal counts/monthly premiums show a dash. September remains available in October; October does not inherit September adjustments. Historical results reflect later corrections/removals rather than immutable snapshots. Existing RPCs remain available for older clients.

Verification: `verify-chat-social.sql` tests authenticated master/agent behavior, cross-division and MFA denial, retry-safe sends/reactions, read cursors, pin permissions, current-month reconciliation, and a simulated October rollover. All test records and the simulated-clock function definition roll back. Browser fixtures in `tests/chat-browser.cjs` and `tests/leaderboard-browser.cjs` cover interactions, realtime callbacks, escaping and mobile layout; they do not impersonate a live signed-in user or test a real browser websocket session.
