# Closing and reopening leads

Mark closed saves a linked production record and changes the assigned lead to
`closed` in one database transaction. My Leads, folders, state filters, assigned
lead lists, and dialer eligibility include only assigned leads. The linked-chat
close route follows the same rule. A standalone chat or CRM deal without a lead
link cannot identify or close an existing lead.

Removing a closed deal subtracts its production and reopens its linked lead. It
returns to the active agent's My Leads, or to the agency pool if that assignment
is no longer eligible. Use Edit deal details to correct a policy or premium
without removing the deal. The removal confirmation explains this explicitly.

## Display behavior

After the close RPC succeeds, the browser removes the lead and updates the local
folder/state counts before refreshing the two My Leads endpoints. The close no
longer depends on reloading the entire account. A failed follow-up refresh says
the deal was saved; it cannot leave the closed row looking open or invite a
duplicate save. Requests started before the close are invalidated, and results
for an earlier account or superseded request are ignored. Rejected saves retain
the lead and re-enable the form; unsaved call notes still block closing.

## Verification

- `NODE_PATH=/tmp/vivid-crm-tests/node_modules node tests/closed-lead-refresh.cjs`
  tests agent/admin forms, failed refreshes, delayed reads, duplicate submits,
  failed saves, notes, counts, and account changes with DOM fixtures.
- `node tests/my-lead-states.cjs` and `node tests/portal-loading.cjs` check folder,
  state, paging and account-loading behavior.
- `node tests/closed-lead-corrections.cjs` checks the correction payload and
  foreign-agent UI gate.
- `tests/closed-lead-lifecycle.sql` runs isolated rollback-only fixtures under
  authenticated roles: agent/admin/chat closes, state/folder exclusions, dialer
  rejection, duplicate and foreign-agent rejection, removal/reopening, and
  standalone deals. Passed against recovery and production on 2026-10-22.

The production audit found no linked-deal status, ownership, or missing-lead
mismatches. No existing customer records were changed by the investigation or
tests. These checks do not place phone calls or send messages.
