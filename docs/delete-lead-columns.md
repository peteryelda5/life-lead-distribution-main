# Delete uploaded lead columns

Lead pool → Manage Leads → Delete Columns. Select a batch, select the uploaded columns, review the names, and confirm. At least one uploaded column must remain.

The operation removes headings and the corresponding CSV values in index order. Canonical contact fields, assignments, lead status, notes and sales are retained. Removing an uploaded Phone column does not erase the saved phone number. This is not a personal hide-column preference.

Scope follows the existing heading editor: filename, lead type, uploader and original headings; an agency admin updates that source agency, while master access can include assigned copies across permitted agencies. Uploads with the same batch identifiers are treated as one batch. Page/search/state filters do not limit this operation.

The invoker RPC preserves lead RLS, verified-session and admin checks, and processes at most 25 candidates per call. Already-updated rows advance the cursor without deleting more columns. Session storage holds resumable operation metadata, not lead values. Conflicting heading edits are blocked within the editor while a deletion is pending. Different browser sessions should finish one batch edit before starting another.

Validation: run tests/delete-lead-columns.sql in a transaction (it rolls back changes); run NODE_PATH pointing to an installed jsdom package with node tests/delete-lead-columns.cjs. The SQL test verifies header/value alignment, unchanged non-CSV lead fields, retry safety, index validation and access denial. Existing portal security and public-build tests also apply.
