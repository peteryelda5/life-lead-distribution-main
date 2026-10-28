# Restricted leaderboard API

`GET https://www.lldportal.com/api/leaderboard`

Send the dedicated key in `Authorization: Bearer YOUR_LEADERBOARD_KEY` from your server. Do not put the key in a URL, public website JavaScript, repository, or browser storage. This is an application key, not a Supabase key or a portal login.

```bash
curl 'https://www.lldportal.com/api/leaderboard?period=month' \
  -H "Authorization: Bearer $LEADERBOARD_API_KEY"
```

The initial key is restricted to **Vivid Life**. Its fixed agency scope cannot be changed through the API. Scope is a fixed list in the private credential registry, so creating another agency does not silently add it to the key.

Allowed parameters:

| Parameter | Values |
| --- | --- |
| `period` | `today`, `week`, `month` (default), or `previous` |
| `month` | Required only for `previous`; first day of a past month, such as `2026-09-01` |

The response contains the scope, timezone, currency, generation time, period boundaries, calculation explanation, totals, and rankings. Each ranking contains only position, agent display name, annual premium, recorded annual premium, imported AP adjustment, deal count, and average AP. There are no account IDs, customer records, contact details, policy numbers, notes, deal-level feed, goals, billing information, or credentials.

AP is the sum of recorded annual premiums plus the applicable monthly imported adjustment. Attribution and sale timestamps match the portal. Rankings sort by AP descending and agent name ascending, with sequential positions. Day/week/month boundaries use America/Detroit; weeks start Monday. Current periods include sales recorded before the response generation time. Imported historical production can have unknown deal counts; those counts and averages are `null`, not zero. This API follows the portal's current calculation; SQL parity tests protect it when the calculation changes.

Only GET is supported. Unknown parameters, including agency, table, and field selectors, are rejected. Missing, invalid, expired, or revoked keys return 401. Invalid parameters return 400. More than 60 requests per minute per key returns 429 with `Retry-After: 60`. Upstream failures return a generic 503. Responses cannot be cached publicly. Polling every 30–60 seconds is sufficient.

Keys have 256 random bits; only their SHA-256 digests are stored in `private.leaderboard_api_keys`. The initial key expires one year after issuance. There is no plaintext-key recovery endpoint. Only a trusted database administrator can issue a replacement, change the scope, or revoke access. The web backend can update usage counters but cannot issue keys, change scope, or change expiration. No API key grants table access or portal access.

To revoke a key, use a trusted database administration session and the key's digest:

```sql
update private.leaderboard_api_keys
set revoked_at=now()
where key_hash='THE_KEY_SHA256_DIGEST';
```

Rotation: generate a fresh cryptographic key, insert only its digest and approved agency scope using a trusted administration session, deliver it privately to the intended recipient, then revoke the old key. Never commit an actual key or its digest to this repository. New credentials are not automatically granted additional agencies.

The Vercel function uses the existing server-side Supabase credential solely to call `leaderboard_api_read`. That RPC is invoker-only and executable only by `service_role`; anonymous and portal-authenticated roles cannot execute it. The private registry has RLS and no anonymous/authenticated grants. Both SQL and HTTP responses explicitly allowlist their output fields. Existing portal authentication and leaderboard RPCs are unchanged.

Verification: `node tests/leaderboard-api.cjs`; run `tests/leaderboard-api.sql` in a trusted database administration session. The SQL tests use a transaction and roll back their fixture key and counters.
