# Portal read performance — October 22, 2026

The Super Master dashboard failed with `canceling statement due to statement timeout`.
The authenticated `dashboard_overview('all',30)` query reproduced the 8-second timeout.
A raw inventory grouping scanned 114,594 leads and took 6.27 seconds on MAIN.
Historical query statistics also identified callback/priority lead matching as major database costs.

## Changes

- Maintain narrow lead totals by agency, status, assignee and UTC creation day using statement-level transition-table triggers.
- Insert, update, delete and truncate changes update totals in the same transaction. Note-only edits produce no counter delta; totals are not a stale cache.
- Backfill and trigger installation commit together. Migration uses a three-second lock acquisition timeout.
- Keep the dashboard function as SECURITY INVOKER. The private aggregate reader explicitly enforces active admin status, current agency scope and verified sessions. Agents cannot read it. The private table has RLS enabled and no direct client grants.
- Preserve the complete dashboard response, including inventory, workload, trends, sales and agency restrictions.
- Add an assigned-lead normalized-phone index for callback matching. Make priority matching use the identical indexed expression; retain existing service-only RPC grants.

## Verification

- Recovery: complete old/new dashboard JSON was equal. Recorded 321.21 ms before and 27.36 ms after in the same transaction.
- MAIN: authenticated all-agencies dashboard completed in 49.512 ms after previously exceeding eight seconds. These are database query times, not browser page-load times.
- MAIN: callback inbox for the account with the most callback records completed in 37.86 ms.
- Aggregate parity: zero mismatched groups; 114,594 leads on MAIN and 113,086 on recovery at validation.
- Exact statement trigger function passed isolated temporary-table insert, multirow assignment/agency/date update, note-only update and delete checks, all rolled back.
- Admin/agent boundaries, unverified-session restrictions, scoped inventory totals and dashboard invoker rights passed in recovery and MAIN.
- Existing dashboard rendering and callback/dialer DOM integration suites passed.
- Security advisor warning counts are unchanged. The extra private-table RLS-without-policy INFO is intentional: access is through the checked aggregate reader.

Run the three sections in `tests/portal-read-hotspots.sql` separately when using the SQL tool.
Also run `tests/portal-read-performance.sql`, `node tests/dashboard.cjs`, and the callback DOM suite.

An attempted combined public-table mutation test returned connector `Invalid or expired requestState`; it is not counted as a pass. Isolated trigger tests and read-only production integrity checks provide the recorded evidence. No real calls or messages were sent.

## Operations

The migration is applied to recovery and MAIN before publishing. UI changes are not required.
To investigate suspected drift, run the aggregate parity section; zero mismatched groups is expected.
Do not edit aggregate rows manually. Roll back the dashboard function to its previous invoker implementation if necessary; dropping this aggregate requires dropping its lead triggers first.
