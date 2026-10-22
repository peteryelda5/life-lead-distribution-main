# Book of Business CRM

The existing Book of Business entry now contains Clients, Pipeline, Tasks and Comp grid.
Clients uses the approved list with a profile sidebar; Pipeline uses the approved five-column board.

Client entry includes name, phone, agent, carrier, policy type/product, monthly premium,
application date and a separate policy effective date. Alternate phone, email, address,
date of birth, mortgage balance, policy number and notes are optional. Prospects may
leave the effective date blank. In force requires a recorded date that is not in the future.

The pipeline supports New prospect, Contacted, Application submitted, Approved and In force.
Lapsed/cancelled clients remain searchable and appear below the pipeline. Dragging and
Move to controls use the same version-checked save. Each column initially displays at most
25 cards, with View all linking to the paginated client list. Search, stage and agent filters
are applied on the server. CSV export covers all matching clients, with formula escaping.

Existing data stays in private.book_crm_clients. No historical effective dates are inferred.
Previously Issued policies display as Approved, since Issued alone does not establish that
coverage is active. Existing Active policies display as In force. The original policy status
and production links remain stored. The existing production routine records a new In force
policy once; later edits retain the same linked deal. Approved alone does not create production.

The profile includes contact details, notes, follow-up tasks and the latest 100 activity
entries. Tasks have a due date/time and can be completed or reopened from the Tasks tab.
Tasks are displayed inside the CRM; this release does not schedule outbound messages.
The Call link opens the device's registered telephone handler. It does not start a power-dialer session.

All new records are private with RLS enabled and no table access granted to browser roles.
Public RPC wrappers use security invoker; restricted private routines enforce the existing
verified session, personal book PIN and agency/owner authorization. No credentials or
customer data are embedded in the public source. Existing PIN and compensation controls remain.

## Verification

- `node --check book-of-business.js`
- `NODE_PATH=/tmp/vivid-crm-tests/node_modules node tests/crm-workspace-browser.cjs`
- `NODE_PATH=/tmp/vivid-crm-tests/node_modules node tests/portal-push-dom.cjs`
- Execute `tests/crm-workspace.sql` unchanged against the recovery database, then production.
  Its transaction rolls back clients, tasks, notes, generated deals and notification events.

Browser tests require Playwright 1.56.1 with Chromium; push DOM tests require jsdom 26.1.0.
The browser test uses the complete portal stylesheet order, mocked RPC responses and synthetic
client records. Database tests separately exercise the real functions, persistence, permission
denials, production accounting and optimistic concurrency. No live calls or messages are sent.

## Release

Apply `20261022154713_crm_client_workspace.sql` before deploying the updated frontend.
It is additive and preserves the old RPCs for existing open tabs and rollback compatibility.
The migration was applied and verified on recovery before production. Existing unrelated
Supabase advisor warnings are unchanged; the new private tables intentionally deny direct
access and therefore have no client RLS policies.

## Pipeline board refinement

Pipeline uses five equal-height columns and compact cards matching the selected board
reference. Agent/carrier filters and search apply on the server before the per-column
25-card cap. Counts cover every matching client; View all opens the filtered, paginated
List inside Pipeline. CSV export respects these same filters. Clients retains its summary.

Drag the card, client name or grip on desktop. On touch devices, drag the grip; the board
scrolls at its edges. Drop zones highlight and a status confirms the saved stage. The
three-dot menu exposes a native stage selector for keyboard use. Failed or conflicting
writes retain the previous card stage. Moving a client to In force without a valid date
asks only for the actual coverage start date, then sends a partial, version-checked update.
Existing production, audit and activity routines remain unchanged.

Today's follow-ups uses the browser's local midnight boundaries (including DST), limited
to eight open tasks with a total and View all tasks link. It includes tasks for matching
clients beyond the first 25 cards. Completing a task uses the existing version check.

Apply `20261022161843_crm_pipeline_board.sql` before this frontend release. The new read RPC
is additive; old clients keep using the original workspace RPC. Run `tests/crm-pipeline.sql`
unchanged on recovery and production: all test rows are rolled back. The Chromium fixture
covers desktop name/grip drag, real touch events and edge scrolling, keyboard moves,
failed-save recovery, date confirmation, Board/List filters and task completion.

## Multiple policies per client

Clients is now a person-level list. Open a client and choose **Add policy** to add another
carrier/product without re-entering the shared contact. Each policy has its own premium,
application date, effective date, policy number, stage, notes, linked deal and commission
estimate. Estimates use the existing comp grid/snapshots and do not represent confirmed
carrier payments. Pipeline cards and stage counters represent policies. CSV exports remain
one row per policy and include both Client ID and Policy ID.

The profile sidebar groups policy cards, shows the active/issued monthly total, and lets
users edit policies independently. Contact edits apply across the person's policies.
Follow-up tasks and activity are collected in the profile but retain their policy identity;
new notes/tasks explicitly select the policy they refer to.

`20261022172331_crm_multiple_policies.sql` adds private profiles and links existing CRM rows
one-to-one using their existing IDs. Historical policy rows, task/activity references,
production links, dates, statuses and commission snapshots remain intact. Existing rows
are not automatically combined by name or phone. Additional policies reuse the existing
policy save/production routines with separate IDs. Existing open tabs and closed-business
inserts remain compatible through a private contact synchronization trigger. The shared
profile table denies direct access; RPCs preserve the existing PIN/MFA and agency scope,
with every returned policy individually authorized. Only accounts authorized to manage the
client's agent can add policies or edit the shared contact through the new APIs.

Validation: rollback-only `tests/crm-multiple-policies.sql` covers two carrier/product pairs,
independent premiums/dates/stages/commission estimates, idempotent create retry, production
once per policy, stale edits, shared contacts and linked-deal contact snapshots, legacy API
compatibility, policy-labelled tasks/history, cancellation totals and authorization gates.
`tests/crm-workspace.sql` verifies original workflows still work. Chromium tests include
multi-policy add/edit, error recovery, independent stage moves, shared contact edits,
policy-specific notes, CSV identities and desktop/mobile rendering. Push DOM tests cover
the new policy-write route without sending any real notifications.
