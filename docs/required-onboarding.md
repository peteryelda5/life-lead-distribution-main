# Required agent onboarding

Agents and team leaders must complete the existing checklist before opening the portal. Administrators retain access to manage onboarding and countersign agreements.

The checklist requires the welcome and compliance acknowledgments, an explicit licensed/not-licensed answer, and a completed live NDA/chargeback agreement. The existing combined agreement includes both documents and requires the agent's signature followed by Peter Yelda's countersignature. Sandbox agreements, legacy grandfathering receipts, and agent-only signatures do not unlock access. Saved acknowledgments and completed live agreements are reused.

Licensed agents must supply a numeric NPN (1–10 digits) and at least one valid US licensed state/DC. XCEL, study and exam steps are marked not required for this path. Unlicensed agents do not need an NPN, but must complete the three existing self-reported training steps. Licensing data is self-reported; portal access is not license verification or permission to sell insurance.

The database is authoritative. PostgREST's existing pre-request hook preserves MFA and profile bootstrap, allows only onboarding routes while locked, and blocks other RPCs. Additional restrictive RLS covers public tables, other profiles, Realtime table access, and Storage. Private notification previews are suppressed for locked users, including queued deliveries. Authenticated dialer and push APIs check onboarding before service-role operations. The only dialer exception is stopping an owned existing Power Dialer session; its restricted response contains no lead data. Provider callbacks remain available to finish and reconcile existing calls. Signing, passkeys and sign-out stay available.

## Deployment order

1. Apply `20261024174853_required_agent_onboarding.sql` to Recovery and Production. It installs enforcement with a private flag initially off.
2. Run `tests/sql/required-onboarding.sql` in each database. It enables the flag only within a rolled-back transaction, creates fictional records, and checks both paths, RLS, RPCs, live signatures, admin access and MFA.
3. Deploy the matching portal/API changes. Confirm the HTML references `20261024-required-onboarding` assets.
4. Apply `20261024175547_enable_required_agent_onboarding.sql` to each database. All existing incomplete agents must answer the licensing question and finish the remaining steps.
5. Confirm admin access and locked agent behavior without modifying a real person's progress or signing documents for them.

If an urgent rollback is necessary, disable the private gate flag before rolling back the frontend/API. Only the database owner/service role can change that flag. Never weaken MFA or mark real agreements complete manually.

## Validation

- `NODE_PATH=<directory containing jsdom> node tests/required-onboarding.cjs`: complete DOM flow, conditional license fields, progress, blocked direct navigation, outage behavior and service-role API gate. Uses fake responses; no calls or agreement emails.
- `node tests/onboarding-progress.test.cjs`, `node tests/signwell.test.cjs`: progress and existing signing behavior.
- Existing portal loading/navigation, connection-error, push and passkey tests remain applicable.
- `tests/sql/required-onboarding.sql`: all fixture writes and gate changes roll back.

## Centered onboarding layout

The October 24 centered design uses a horizontal six-step tracker and a single task card for Welcome, Licensing, Agreements, Training, Study and Exam. Full-name state tiles support search and expand/collapse; filtering never removes a checked state from the saved selection. Both signature statuses come from the existing agreement response. The final checklist stays on the exam page after saving, and the existing canonical gate controls Enter portal. Existing letters, signatures, saved progress, admin oversight and database rules are retained. This presentation release requires no migration.

`NODE_PATH=<directory containing playwright> CHROMIUM_EXECUTABLE_PATH=<optional Chromium binary> node tests/centered-onboarding-browser.cjs` exercises the actual frontend with fictional API responses: all six desktop pages, 390px/320px layouts, licensing paths, all 51 state/DC choices, hidden selections, failed-save retry, signature statuses and final access. Screenshots go to `ONBOARDING_QA_DIR` or `/tmp/vivid-centered-onboarding-qa`; no real accounts, emails or signatures are changed.
