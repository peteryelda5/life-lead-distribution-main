# Large lead imports — prepared upgrade

Status: prepared for review, **not applied to production**. Automatic approval review rejected the production migration because it changes access grants, adds privileged functions and triggers, builds indexes, and takes a table lock. Explicit user approval is required before retrying that action. Do not deploy this frontend before its database migration succeeds.

## What changes

- The CSV is fingerprinted and parsed incrementally in a dedicated worker. At most 500 rows are submitted per batch; the whole file is never loaded into a text string or a row array.
- Full-content, fixed-block SHA-256 chaining identifies the file for resume. Checkpoints store byte offsets at CSV record boundaries. UTF-8, CRLF, quoted newlines, escaped quotes, duplicate headers, and additional columns are preserved.
- One batch is in flight. The batch RPC locks its import job and atomically inserts rows and saves progress. A repeated batch is recognized by its digest and cannot duplicate rows. A different batch at the same checkpoint is rejected.
- Completed copies of the same file with the same division, batch name and source are recognized. Different files or batch names may still contain duplicate people; this is retry protection, not contact deduplication.
- Lead pages fetch 100 rows plus one lookahead using timestamp/ID cursors. They no longer request exact counts or deep OFFSET pages. Assigned pages are ordered by creation time for a stable cursor.
- Statement-level summary triggers keep grouped counts current for the dashboard, agents, and filters. Existing totals are initialized during migration.
- Composite indexes support division-scoped paging. A trigram index supports the existing substring search across common fields.
- The startup recovery hotfix is included.

## Limits and operating requirements

Keep the browser tab open during upload. Closing it stops the client; choose the exact same file, division, batch name and source to resume. Already committed batches remain safe. This is not a server-side background import service.

The input must be UTF-8 CSV, no more than 256 columns or 512 KB per record. The server accepts at most 500 rows and 8 MB per request. Ingest speed and storage capacity depend on actual row width, network speed, database compute, indexes, and the Supabase plan. One million live rows were **not** uploaded or load-tested in production. Large deletion/assignment operations and very broad searches still warrant separate measurement before heavy use.

## Tests run

- `node --expose-gc tests/csv-stream.test.cjs`: 1,000,000 synthetic rows / 84 MB, 2.81 seconds on this runtime, maximum 500 buffered rows; observed JS heap growth peaked around 89 MB. This is a parser test, not an upload benchmark or browser FPS measurement.
- `node tests/pagination.test.cjs`: 100-row cursor pages, timestamp ties, division resets, no OFFSET/count requests.
- `tests/import-database.test.cjs` ran against local PGlite 0.5.8 (Postgres WASM) with fixture roles/tables. The exact migration SQL passed. Tested atomicity, replay, mismatched retries, byte checkpoints, final replay, master/Legacy boundaries, agent/anonymous denial, and summary maintenance after insert/update/delete. This does not replace testing against production's existing triggers and RLS after authorization.

To reproduce the local database test without adding runtime dependencies to the app:

```sh
npm install --prefix /tmp/lld-db-test --no-audit --no-fund @electric-sql/pglite@0.5.8
NODE_PATH=/tmp/lld-db-test/node_modules node tests/import-database.test.cjs
```

## Release sequence

1. Obtain explicit approval for `db/large-imports.sql`; explain the short write lock, index builds, and new import/summary functions and access grants.
2. Recheck the live schema, latest main commit, row totals, project storage/compute capacity, and recent writes. Confirm the migration has not already been applied.
3. Apply the migration transactionally during a suitable low-traffic window. Verify totals match the source rows and test import/permission paths using disposable rows inside a rolled-back transaction. Run security advisors and inspect query plans.
4. Merge/deploy this branch after the database checks pass. Verify the production deployment and perform an authenticated small CSV import, then representative staged load testing before the first million-row production import.
5. If the frontend release has a problem, restore the prior main frontend. The migration is additive except for the three replaced reporting functions; retain jobs and summaries while investigating rather than deleting imported data.
