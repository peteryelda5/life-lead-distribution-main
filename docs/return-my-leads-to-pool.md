# Return personal leads to agency pools

Admins (including Master) and team leaders get **Return to agency pool** in **My Leads**. Apply the existing folder, state, and search filters, open the dialog, select leads from the current page (up to 500), and confirm. The dialog refreshes the current page before review and shows the destination agency for each record. To return additional pages, repeat after the list refreshes.

Returns clear assignment, not agency ownership. Each lead stays in its existing agency, becomes unassigned, and keeps notes, dispositions/colors, imported fields, folder, uploader and owner provenance. A portable Owner/Master lead returns to the Owner/Master pool shown in the preview. Closed leads and any lead with a closed-business record are rejected. The operation accepts only leads currently assigned to the caller, regardless of who originally assigned them; it grants no ability to reclaim another person's leads.

The mutation requires an active, unarchived admin or team leader and a verified AAL2 session. It checks the live profile, locks lead IDs in order, compares every preview revision, and commits all selected returns together. A private RLS-enabled request ledger makes network retries idempotent. Current lead history and portable-grant cleanup triggers continue to run. The RPC writes one delivery receipt per destination pool and an `own_leads_returned_to_pool` audit record. No new broad lead-table grants or update policies are added.

Call-note drafts must finish saving before preview. Unresolved drafts stop the flow. Once a return is attempted, its exact selection is frozen until success or closure so a lost response cannot cause a retry to act on different leads.

Deployment order:

1. Restore access to the LLD production and recovery Supabase projects.
2. Apply `database/return-my-leads-to-pool.sql` in recovery, run `database/verify-return-my-leads-to-pool.sql`, and inspect security advisors.
3. Apply and verify the same migration in production.
4. Merge the prepared branch to main to release the UI through the existing Vercel Git integration. Do not release the button before the RPC exists.

Local verification: run `tests/lead-return-dom.cjs` and `tests/portal-startup.cjs` with JSDOM 26.1.0; `tests/lead-return-sql.cjs` uses PGlite 0.5.10 with a minimal local schema and the actual existing lead-history/portable cleanup behavior. This checks function behavior, permissions and trigger compatibility, but does not replace recovery/production verification or a signed-in browser check.

Deployment verification on October 19, 2026: LLD access was restored. Migration `return_personal_leads_to_agency_pool` was applied in recovery and production; the complete rollback-only SQL fixture passed on both deployed schemas. Subsequent checks found zero persisted test leads or returns, no anonymous execute permission, and no direct authenticated ledger access. No real customer leads were returned during verification.

Security advisor comparison introduced no warning or error. The sole new informational notice is the private ledger having RLS without policies, which is intentional: clients have no table grants and all access goes through the guarded function. Existing unrelated advisor findings were unchanged. [Supabase RLS notice reference](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).

The UI is ready for the production Git release. A signed-in visual check is still a manual follow-up; local DOM/startup tests and the deployed database checks passed.
