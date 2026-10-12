# Portal loading improvements — October 12, 2026

## Changes

- Startup scripts use `defer` in their existing dependency order. The main app moved unchanged from inline HTML to `portal-app.js`, apart from adding an ID tie-breaker to assigned-lead pagination. This lets the browser parse the page without waiting for script execution.
- Database connection preconnect starts during document parsing.
- Dashboard inventory, workload and daily trend share one RLS-visible lead aggregation. Two covering indexes support lead counts, pool sorting and assigned-folder counts without requiring every CSV payload.
- Collaboration polling pauses while the document is hidden and catches up on return. Background list requests share in-flight work; explicit refreshes after mutations still start a fresh read. Request and account generations reject stale responses.
- Dashboard background refreshes are limited to once per 30 seconds or longer, never overlap, and fetch goals and dashboard data in parallel. Chat list/history also load in parallel.
- Unread fallback polling runs every 30 seconds; realtime message notifications remain enabled.

## Verification

Measured authenticated database work on the live project before and after applying the two SQL migrations. Three calls per query were made; the table uses the average of calls 2 and 3. These are database query times, not full browser page-load measurements. First-call timings were highly variable and are excluded.

| Query | Before | After |
| --- | ---: | ---: |
| Master dashboard | 223.66 ms | 141.59 ms |
| Lead pool page plus exact count (500 rows) | 72.32 ms | 50.77 ms |
| Lead pool filter counts | 56.65 ms | 48.18 ms |
| Agent folder counts | 5.81 ms | 4.89 ms |

Dashboard, pool and agent query output hashes matched before and after on live data. Recovery-database dashboard output hashes also matched for Master all-agency, 7-day Vivid, 90-day Owner and scoped admin views. Assigned-page row ordering originally had tied timestamps; the client now explicitly orders those ties by ID. No improvement is claimed for assigned-page or agent lead-row query timing.

`tests/portal-read-performance.sql` passes on both projects: scoped admin totals, admin/agent boundaries, MFA restrictions and security-invoker rights. No RLS policies, grants or lead records were changed by the migrations.

Node tests passed for navigation/session isolation, startup loading, dashboards, team controls, lead requests, folder/state filters, heading editing, closed periods and the dialer. New tests exercise the actual deferred script order in JSDOM, hidden-tab polling, overlapping requests, mutation freshness, account resets and parallel loads. No authenticated browser performance measurement was available.

Run the JSDOM tests with `jsdom` installed externally:

```sh
node tests/portal-background.cjs
NODE_PATH=/tmp/vivid-request-tests/node_modules node tests/portal-startup.cjs
NODE_PATH=/tmp/vivid-request-tests/node_modules node tests/request-fulfillment.cjs
```
