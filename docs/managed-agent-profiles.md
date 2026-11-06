# Profiles tab

Admins, Master and Super Master accounts have a Profiles navigation tab. Team leaders have it for direct non-leader agents in the same agency. Ordinary agents do not have management access.

The directory uses the existing profile dialog. The Management selector now uses the portal's blue bordered styling. Licensing is read from onboarding, labeled self-reported, and includes status, NPN and states. Missing answers do not mean unlicensed.

The new read RPC returns only the agent directory fields and licensing. It checks a live verified session, onboarding, active/non-archived manager, and server-derived agency/team scope. Pages are bounded to 500 records with a UUID cursor and eight-second statement timeout. No checklist-table grants or RLS policies were broadened.

Admins retain their existing account actions and agency scope. Team leaders can rename a direct agent or disable sign-in; disabling expires sessions and retains all leads, deals and history. Team leaders cannot enable accounts, change email/agency/role, reset security, remove accounts or manage other leaders/admins. Each write is limited to one locked agent, uses live team membership, and records an audit event. The agency admin handles re-enabling.

Verification: tests/managed-agent-profiles.sql rolls back its fixtures and checks scoped reads, mutation boundaries, session expiry, and denied ordinary-agent, foreign, self, unverified and anonymous access. tests/agent-profiles.cjs checks directory/profile controls, licensing states, retry/account switching, and leader confirmation/cancel behavior. Portal security and browser-only build checks also apply.
