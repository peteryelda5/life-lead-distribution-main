# Master-managed divisions

The Divisions tab is available only to the active Master Admin. Creating a division adds a registry entry and leaderboard invalidation row. An optional existing admin receives an additional scoped grant; their original division is not moved. New admin accounts can be created from each division card. No production division or account is created by deployment itself.

The registry replaces hard-coded division checks and dropdown options across the portal and account-creation endpoints. Foreign keys validate profile, lead, script, chat, request, notification, and import division references. Registry rows are readable only within existing permitted scopes. Creation is an authenticated Master-only RPC with an audit entry, normalized unique names, and no direct client write grants.

Peter remains the sole Master with oversight across all divisions. His lead-upload destinations remain Vivid Life and Owner / Master, matching the existing rule. New divisions' scoped admins can upload to their own divisions. Existing Vivid, Legacy, Jonah, and team-leader permissions remain unchanged unless the Master explicitly selects an admin for a new division. Lead-request routing now also recognizes explicitly granted admin division access.

Deploy database/divisions.sql, database/validate-division-references.sql and database/division-request-routing.sql, then the updated create-agent/create-admin/update-admin Edge Functions and frontend. Existing RPC signatures remain compatible. Registry and create-account changes were tested using rolled-back database fixtures, Edge Function mocks, and desktop/mobile browser fixtures. No real test user, lead, division, or grant is retained.

Verification: database/verify-divisions.sql, tests/divisions-browser.cjs, tests/division-edge.cjs, tests/agent-restore.cjs, tests/team-ui.cjs. Browser checks use synthetic REST fixtures, not a signed-in production session.
