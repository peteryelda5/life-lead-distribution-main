# Unified Organization workspace

Organization replaces the separate Agents and Management navigation items for admins. The hierarchy uses the existing permitted agency registry and agent team_leader_id relationships. Master sees permitted agencies; ordinary agency admins remain limited to adminDivisionList. Master-only owner records are excluded from the agency hierarchy and production rollup; existing list selectors retain access to master records.

Hierarchy cards expand agency admins, team leaders, and direct-to-agency agents (including agents whose leader is unavailable). Add offers existing agent/admin/agency creation forms, with agency preselection for agents. Team-leader promotion and team assignment use existing Team settings. No new account privileges or database changes.

List view preserves all existing Agents & team leaders, Admins, and Agencies management screens and actions. Legacy navigation into those screens resolves to Organization's corresponding list. Person clicks open the existing edit modal; team Manage opens existing team settings. No new side panel is introduced in this release.

Monthly AP and recorded deal counts use the existing authenticated closed_period_totals RPC per permitted agency. Its monthly calculation uses application date, falling back to recorded creation date, in America/Detroit. Failed totals display unavailable, never a misleading zero. These are recorded gross deals, NOT carrier-adjusted net deals. Historical imported leaderboard AP adjustments are not included in this closed-deals metric. Agent roster pagination uses fetchAll to avoid the database's default response limit.

Validation: organization DOM tests with actual legacy list rendering/binding, agency isolation, escaping, team relationships, add/edit actions, stale/unavailable summary behavior; portal navigation/session, team UI scope, and portal dialer regression suites. No live accounts or teams created for tests. No authenticated production browser session available for full live UI verification.
