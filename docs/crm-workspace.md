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
