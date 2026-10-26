# Book of Business CRM

## Missing client details

The old “Client not linked” placeholder appeared when a closed deal lacked a client
name, or when the lead name existed only in uploaded CSV columns. New closed deals
read the exact linked lead’s standard fields and recognized CSV contact columns.
AgentName and unrelated records are never used to infer a client. Later lead
corrections and the legacy Book contact API fill missing CRM names while preserving
known contacts, policy data, production and commission records.

The migration repairs only profiles with missing names and an exact existing source,
with an audit snapshot. Unknown clients show “Client details needed”; their sidebar
provides **Add client details**, using the normal permission/PIN/version-checked
shared-contact editor. Existing named clients are never merged or overwritten.

Chat’s Log a closed deal form now requires the client name and accepts optional
phone/email. The new RPC creates the deal and its private CRM contact atomically,
retains agency/agent verification and idempotency, and does not require a Book PIN
just to record a sale. Client contact information stays out of the public deal feed.
Old API signatures remain available for compatibility.

Apply `20261023180330_crm_client_contact_recovery.sql` first. Verify with rollback-only
`tests/crm-client-linking.sql`, CRM regressions,
`tests/crm-client-linking-browser.cjs` and the push DOM suite.

## Chargebacks

Chargeback is a red pipeline column, always available as a drag target, and is
included in stage selectors, client filters and CSV exports. Carrier status has
its own Chargeback option with the same evidence requirements as other confirmed
updates. A carrier-confirmed Chargeback creates/reuses the assigned agent's red
automated follow-up task. Changing either status never changes the other.

An agent pipeline Chargeback is excluded from agent-reported active/issued totals.
Recorded Closed Business and commission snapshots remain intact; this status does
not calculate a chargeback amount or deduct money. Apply
`20261023174804_crm_chargeback_statuses.sql` before this frontend. Verify with
`tests/crm-chargebacks.sql`, `tests/crm-chargebacks-browser.cjs` and the existing
client-actions, carrier-status and pipeline regressions.

## Client deletion and carrier follow-ups

Open a client in Clients and choose **Delete client** in the profile header. The
confirmation lists all policies being removed. This removes that CRM profile,
its policy records, notes and tasks, and returns the contact to the same agent's
My Leads. Linked clients keep their original lead folder, uploaded fields and call
notes; manually entered clients use **Returned from CRM**. Updated CRM contact
details replace corresponding CSV fields. Policy notes, client notes and open task
reminders are copied into the returned lead's call notes. Multiple policies create
one returned contact, marked **Call back** (known dead numbers remain marked dead).

Recorded Closed Business and commission snapshots remain unchanged. A new working
lead retains a private link to the original closed lead, so it can be worked and
closed again without overwriting the previous sale. An already-open exact linked
lead is reused. Returns never merge people by name or phone. The operation retains
an audit snapshot and cannot delete the CRM profile unless the lead return succeeds.
Repeating the same deletion returns the original result without creating another lead.
This does not cancel carrier coverage. The API requires the current profile and every policy/deal
version, the existing Book PIN/MFA, and permission to manage the whole profile.
An unrelated or recently changed client cannot be deleted from a stale dialog.

Carrier-confirmed **Initial premium failed, Grace period, Late offer period,
Lapsed, Cancelled, Declined and Chargeback** create a red, high-priority task for the policy's
assigned agent. These appear in CRM Tasks and the client sidebar, with a link
back to the client and policy. Urgent tasks sort before normal tasks. Each policy
has one automated task; a changed problem reuses/reopens it. Re-recording the same
status does not duplicate a task or reopen one the agent already completed.
Recording a status outside those seven completes an open automated task, while
manual tasks stay unchanged. Existing identity-matched problem statuses are
included once during migration. No carrier status changes agent stage or production.

Apply both `20261023172948_crm_client_deletion_and_carrier_tasks.sql` and
`20261023173539_crm_client_delete_lock_alias.sql` before deploying the frontend.
Run `tests/crm-client-actions.sql` as a rollback-only check, plus the carrier and
multiple-policy SQL regressions. Chromium coverage is in
`tests/crm-client-actions-browser.cjs` and `tests/crm-workspace-browser.cjs`.

The return behavior additionally requires
`20261024212330_crm_deleted_clients_return_to_leads.sql`, followed by
`20261026011323_crm_return_generated_lead_status.sql`. The correction respects the
existing generated dead-number column. Apply both in one transaction on a fresh
target, then verify before deploying the matching UI. The user approved recovery
and production deployment; recovery integration passed with rollback-only fixtures.
Current rollout status is recorded in PR #61.
The change has local PostgreSQL coverage in `tests/crm-delete-return-leads.cjs`
(PGlite 0.5.11), plus the client-actions Chromium test. Lead upload and agency rules
are preserved; only an exact, transaction-scoped private return record permits the
CRM operation. No ordinary upload permissions are expanded and no old deletions are
automatically restored.

The existing Book of Business entry now contains Clients, Pipeline, Tasks and Comp grid.
Clients uses the approved list with a profile sidebar; Pipeline uses the approved board with a sixth Chargeback column.

Client entry includes name, phone, agent, carrier, policy type/product, monthly premium,
application date and a separate policy effective date. Alternate phone, email, address,
date of birth, mortgage balance, policy number and notes are optional. Prospects may
leave the effective date blank. In force requires a recorded date that is not in the future.

The pipeline supports New prospect, Contacted, Application submitted, Approved, In force and Chargeback.
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

## Carrier-confirmed status

Agent pipeline stage and carrier-confirmed status are separate. Moving a card continues
the existing agent-reported production accounting and never writes carrier confirmation.
A carrier update never moves the pipeline, creates a deal, changes premiums or alters
commission snapshots. Premium totals are labelled agent-reported. They are not a count or
premium total of carrier-verified in-force policies.

Open a client, expand a policy, and choose **Carrier-confirmed status → Record update**.
Record a status, source (carrier portal, email, statement or phone confirmation), date,
reference and optional notes. This is an attributed manual record, not a live carrier sync.
There is no default date/source and no confirmation inferred from historical issued/active
records. Every existing and new policy starts Unverified until evidence is entered.

A confirmation snapshots the carrier, product and policy/application number. Changes to
those identifiers show Needs recheck and preserve the previous confirmation for review.
Choose Unverified with a reason to correct an unsupported entry. Activity and audit retain
before/after evidence, actor and recording time. Status dates are historical observations,
not guarantees of current coverage; the confirmation date is always shown in policy detail.

`20261022180241_crm_carrier_status.sql` adds a private, RLS-enabled status table with no direct
browser grants. The dedicated invoker RPC preserves book PIN/MFA, policy-level agency scope
and optimistic version checks. Legacy generic saves cannot set these fields. Read RPCs append
the independent status/provenance; CSV distinguishes agent status from carrier evidence.

Run rollback-only `tests/crm-carrier-status.sql` on recovery then MAIN. It covers independence
in both directions, siblings, unchanged production, required evidence, stale updates, identity
changes, audit history, reset, owner/agent permissions and PIN/MFA. Re-run multiple-policy SQL
regressions and Chromium fixtures (including evidence form, failed save, escaping, desktop/mobile).

Apply the companion `20261022180753_crm_carrier_status_deal_version.sql` before deployment; it also checks the linked deal version so external Closed Business edits cannot be confirmed from a stale open profile.

## Agency branding and compact layout

The approved Clean & compact design puts each agency's logo, CRM navigation and actions in
one header. A slim stage/count strip replaces the large cards. Search stays above the client
list and the wide profile sidebar starts alongside it. The Pipeline board, tasks, policy
editing, separate carrier confirmation and agent-reported accounting retain their behavior.

Open **Settings → Agency logo** to preview, upload or replace a logo. PNG, JPG and WebP up to
2 MB are supported, with content signature and browser image-decode checks. Agency admins
manage only their current agency; active Super Masters can select all non-archived agencies.
Agents and team leaders only see branding. No extra lead-management scope grants logo edits.
The branding context resolves membership on each CRM load; transferred agents receive their
new agency's branding. Without an upload, show the agency name. Vivid Life uses the exact
user-supplied Vivid Life Advisors PNG as its default logo. Reset restores that default (or the
agency name elsewhere). Image-load failures fall back to text; branding API errors don't block
CRM data and provide a retry action. Account-switch responses are discarded.

`20261022183654_crm_agency_branding.sql` adds a private RLS table and the public `agency-logos`
Storage bucket. These are public brand assets, never client documents. Upload paths include
agency, actor and unique file ID; uploads cannot overwrite existing objects. The dedicated
save RPC validates membership, uploaded object metadata and optimistic version before linking
it to an agency. Logo changes are audited. Only unused files uploaded by the current permitted
admin are eligible for Storage API cleanup. Historical assets are retained; Reset unlinks them.
No direct private table access or anonymous RPC access is granted. Brand editing requires the
portal's existing verified session; the CRM itself retains its separate Book PIN.

Validation: rollback-only `tests/crm-agency-branding.sql` exercises real authenticated-role
Storage insert/update policies plus cleanup predicate, admin/agent/Super Master scopes,
version conflicts, missing-object rejection, reset, membership transfer and MFA gates.
Storage deletions must go through the Storage API; tests do not disable its SQL-delete guard.
Chromium fixtures exercise actual file input, signature checks, decoding, preview, successful
upload/save, failed-save retry without duplicate upload, reset, role/agency display, graceful
branding failure and existing CRM desktop/mobile workflows. The Storage SDK upload transport
uses the portal's existing authenticated client; the browser suite mocks its network response.

## Account consolidation and deletion choices

Admins already have a personal **My deals** filter. Maintenance can consolidate a
confirmed duplicate agent into its admin login with
`private.consolidate_admin_agent`. This function is not exposed to portal/API roles.
It archives the source profile, retains a private before-state snapshot, transfers
clients/policies and production without recalculating captured commissions, and
keeps lead agencies/folders intact. Exact portable assignments allow the admin to
work those leads without receiving broad access to the source agency. Existing
source JWTs fail active-profile checks. Legal records and unused billing setup
remain historical; active provider assets stop the operation for separate handling.
The four user-confirmed transfers were applied and verified in production.

The CRM deletion dialog now offers **Delete & return to leads** and **Delete
without returning to leads**. Both enforce current policy/profile versions,
onboarding, MFA, Book PIN and ownership scope, and retain an audit snapshot.
Delete-only leaves existing leads and recorded production unchanged. Old cached
clients retain the default return behavior through the existing RPC.

Deleting a deal through **Closed Business** now removes its exact linked CRM policy
before the foreign key can detach it. Sibling policies remain; empty profiles are
removed. Tasks, activity, carrier status and compensation are captured in the audit.
The existing deal-removal flow reopens its linked lead, including active admin and
portable assignments. Historical orphan policies are not mass-deleted by this change.

Validation: `tests/admin-account-consolidation.sql` ran inside rolled-back recovery
and production transfers and again in the committed transfer transaction.
`tests/crm-deletion-options.sql` verifies real database RPCs in a rolled-back
transaction. `tests/crm-client-actions-browser.cjs` covers both buttons, mobile
layout, exact payloads, stale-dialog failure, duplicate-click protection and
account changes while a request is pending.
