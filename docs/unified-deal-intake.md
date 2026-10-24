# Unified deal entry

Closing an assigned lead and logging a manual/chat deal now use the same required client-and-policy form. Existing lead/CSV contact data is prefilled. New clients are captured once and saved with the deal; the agent does not have to create a second CRM entry.

Required fields are client name, phone, carrier, product/type, positive monthly premium, application date and agent pipeline stage. Approved/In force requires an effective date; pending applications can leave it blank. In force cannot have a future effective date. Additional contact information, policy number and notes are saved when entered. Primary and alternate phones share the existing CRM formatter.

The database transaction creates the complete CRM policy first, then attaches the production record through the existing exact-ID link. Existing commission snapshots, deal announcements and lead-close behavior are preserved. Carrier confirmation starts unverified. Client contact details are not included in the team announcement. People are never merged by similar names or phone numbers.

Request IDs plus a payload fingerprint make retries return the same deal. Changed payloads with the same request ID are rejected. Any downstream error rolls back the client, deal and request together. MFA, completed onboarding, assigned-lead ownership, agency access and eligible agent credit are checked on the server. No Book PIN is required to submit a deal; reading/editing the CRM still uses its existing gate.

## Release order

The user approved the Supabase rollout on October 24, 2026. Both migrations passed recovery verification, and the additive RPC passed production verification before UI deployment. Checks used transaction rollback, leaving no test clients, deals or announcements. Current deployment and enforcement status is recorded in PR #60.

1. Recovery (`ebvubpcevljgjuhiraqn`): install `20261024195054_unified_deal_intake.sql`, then `20261024195553_enforce_complete_deal_intake.sql`. Verify with isolated rollback fixtures and review relevant database advisors.
2. Production (`yfuuigykpihoetgaefmu`): install the first migration only. It adds one private request ledger, one public RPC with a private implementation, and an inactive validation trigger function. It does not change existing deals.
3. Merge the approved code and verify the production deployment and all changed assets.
4. Apply the second migration to production. It activates the insert guard so outdated forms/direct inserts cannot create incomplete clients. Existing CRM policy creation uses the same exact-ID context and continues to work; an older incomplete client must have its contact details completed before recording new production.
5. Check portal errors and confirm a controlled submission when authorized. Never create fake live production or send team notifications merely for testing.

The guard applies to new production inserts, not edits/backfills of historical deals. If reverting the frontend, first remove the new guard trigger; retaining the additive private ledger and RPC is safe. Do not delete historical CRM, deal or notification records as part of rollback.

## Validation

- `tests/deal-intake-sql.cjs`: isolated PostgreSQL via PGlite 0.5.11, executing the actual migrations and existing repository writers/contact/commission/announcement triggers. Covers atomic lead/manual creation, contact sharing, comp snapshot, private feed fields, input/date validation, replay/conflict, authorization, rollback, authenticated RPC and private-table permissions. This is not a remote production integration test.
- `tests/deal-intake-browser.cjs`: actual shared UI with fictional RPC fixtures; prefill, products, required fields, dates, summary, retry identity, duplicate-submit prevention, CRM display, mobile and account changes.
- Existing CRM workspace, client linking, sidebar/phone, close-refresh and push DOM suites. Test fixtures load the extracted phone helper and supply the existing onboarding gate context.
- JavaScript syntax and whitespace checks.

Local test dependencies: PGlite 0.5.11 and jsdom 30.1.3, plus the workspace Playwright runtime. Set `CHROMIUM_EXECUTABLE_PATH` when using a system Chromium.

`tools/record-deal-intake-demo.cjs` records the implemented form and CRM using fictional fixtures. It produces a captioned MP4; the clip clearly identifies itself as a proposed-update simulation.
