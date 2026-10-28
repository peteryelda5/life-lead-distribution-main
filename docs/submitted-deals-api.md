# Submitted-deals integration

GET https://www.lldportal.com/api/submitted-deals

Send the existing restricted leaderboard API key in the `Authorization: Bearer <key>` header, from your backend only. Do not send keys in URLs, browser code, email, or this public repository. No database login, Supabase secret, or portal account is needed.

This feed reports records submitted to Deals / Closed Business. It does not read or publish CRM stages, carrier statuses, client details, notes, policy numbers, cancellations, or chargebacks. Do not use it to calculate net issued production. There is no status-based deduction logic.

Every deal has exactly these fields:

| Field | Meaning |
| --- | --- |
| deal_id | Stable submission record UUID; use to deduplicate |
| agent_id | Agent UUID |
| agent_name | Agent display name |
| agency | Always `Vivid Life Advisors` |
| monthly_premium | Recorded monthly premium in USD, or null if missing |
| annual_premium | Recorded annual premium in USD, or null if missing |
| submitted_at | Time the Closed Business record was created, with timezone |

Agency branding does not expand access: the key remains restricted to its server-configured agency division(s). This is not a client or CRM API.

## Requests and pagination

- `period=month` (default), `today`, `week`, or `previous`.
- For `previous` only, provide `month=YYYY-MM-01` for a completed month.
- `limit=200` by default, from 1 to 500.
- `after=<UUID>` uses the previous response's `next_after` value.
- Any other or repeated parameter is rejected. There is no status, agency, table, or column selector.

Examples (authenticate through your server's protected secret):

```text
GET /api/submitted-deals?period=month&limit=200
GET /api/submitted-deals?period=previous&month=2026-09-01
```

Response envelope: `version`, `timezone`, `currency`, `as_of`, `period`, `deals`, `next_after`. `next_after=null` means the scan is complete. Periods use America/Detroit, Monday-start weeks, and creation time rather than application/effective date. Rows are ordered by UUID, not time.

Poll every five minutes. Start each scan without `after`, follow all pages using the same period/month, and upsert by `deal_id`. Never add the full returned total to a running total on each poll. The cursor is only for a single scan; it is not a persistent change-feed watermark. For month rollover, use an explicit completed month for historical scans. Concurrent new submissions can appear on the next full scan.

This reads current Closed Business records, not an immutable historical ledger. Direct edits to those records are reflected; actual deleted records are absent. Absence is not a cancellation/chargeback notification and must not be treated as one. CRM status changes are not integration events. Historical manual leaderboard AP adjustments are not submission records and are excluded, so totals can differ from the older aggregate endpoint.

Limits: 60 requests/minute per credential, shared with `/api/leaderboard`. Responses are private/no-store. Errors: 400 invalid parameters, 401 missing/expired/revoked key, 405 unsupported method, 429 throttled (Retry-After: 60), 503 temporarily unavailable. Retry 429/503 with backoff; do not delete previously received data on errors.

Existing `/api/leaderboard` remains unchanged. This endpoint is the appropriate source for the newly agreed submitted-deal contract.

## Verification

Run `node tests/submitted-deals-api.cjs` and `node tests/leaderboard-api.cjs`.
Database test `tests/submitted-deals-api.sql` must run inside a BEGIN/ROLLBACK transaction after installing `database/submitted-deals-api.sql`; it creates temporary test credentials, checks scope, values, pagination, revoked/expired credentials, execution permissions, and throttling. Never commit test credentials.
