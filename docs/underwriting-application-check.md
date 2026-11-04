# Carrier Application Check

Guide-based, human-reviewed screening support, not an eligibility decision or a carrier integration. It never emits Approved, Denied, or Eligible. Exact current application questions have **not** been connected. Prompts are derived from guide rows; the UI labels that distinction.

## Sources and scope

Rule data lives in `underwriting_guides.rules.applicationCheck` behind the existing verified-session and Master-write policies. Do not embed private guide text or rule datasets in public static files. No cases are written to the database.

Initial mappings:

- Transamerica FE Express, August 2026: Premier / Select / Graded issue ages, listed state exclusions, face-amount bands (p.4), 29 build rows (p.18), 92 exact drug names (p.17), self-contained condition rows (pp.10–14), comorbidity review (p.9). Time-dependent and multiline condition charts that have not been mapped stay unresolved; this is not a complete health questionnaire. Source SHA-256: b6523e263b35327467bdee589c523183cab75f8cf232cc2dd5f25d92e132b48b.
- Corebridge SimpliNow Legacy, April 2024 REV0424: ages (p.3), 27 build rows (p.8), selected condition / lookback rows (pp.4–7), diabetes plus stroke/coronary history and COPD plus tobacco combinations (pp.5–6), selected conditional medication references (pp.10–11), New York exclusion (p.12). Coverage limits and a complete state/application matrix remain unconfigured. Conditional medication rows only trigger review. Source SHA-256: 223e14b9bc329511bd10403a6b28c1a6097582abe2e0d45a7d0cefdbf99f5998.

Stored editions have not been certified as the latest carrier editions. Other library guides remain source-only until reviewed rules exist. No drug absence, unanswered question, unsupported height, or unconfigured rule is treated as clearance. Medication dosage and indication are collected; dose thresholds are not inferred where no reviewed rule exists.

## Version lifecycle

Schema 1 contains `sourceHash`, `edition`, `version`, `mappedOn`, `exactApplication`, `products`, `questions`, `build`, `medications`, and `combinations`. Bind mappings to the exact guide checksum and edition. Record a new rule version for every mapping change. Preserve old guides through the existing replacement/archive workflow. A replaced PDF does not inherit rules. The UI re-fetches guide metadata before evaluating and refuses a result when the source/rules changed or cannot be verified.

Before adding rules: inspect source pages and footnotes, distinguish guide prompts from actual application wording, map product/state scope, validate inclusivity and ambiguous boundaries, and test against the exact guide edition. Do not use general BMI classes or infer medication indications. Add only documented combination predicates, never a generic stacking algorithm. Current application forms, remaining charts and carrier verification are required before expanding any coverage claim.

## Verification

`node tests/underwriting-application.test.cjs` covers source invalidation, product isolation, age/amount/build boundaries, missing answers, medication matching and combination flags using synthetic data. Existing underwriting and security suites also apply. DOM integration checks exercise source refresh failures and account isolation. No carrier submissions or real client cases are used in tests.
