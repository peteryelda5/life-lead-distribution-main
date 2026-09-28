# Monthly production imports

Private monthly AP adjustments reconcile a user-supplied snapshot with sales already recorded at capture time. Original sales, lead records, and chat history remain intact. Snapshot figures are kept in the private database, not the public repository. New sales and removed sales naturally adjust AP afterward.

Rows use real profile IDs and the profiles' existing divisions; division RLS helpers still gate every board request. No access grants are expanded. The combined permitted-divisions view displays the combined agency snapshot. Deal counts and monthly premium are unknown for the screenshot totals, so those fields display a dash rather than invented counts. September's agency goal appears only when both relevant divisions are selected.

Only rows for the current calendar month affect MTD rankings. At October 1 midnight America/Detroit (Eastern), the month changes automatically and September adjustments stop affecting MTD. Historical adjustments remain included in that calendar year's AP. No recurring destructive reset or scheduled delete is needed.

Verification: source snapshot total; new Mark/Myles profile mappings; new sale addition and removal; no Legacy import data; simulated October 1 function clock with rollback asserted zero October MTD and no active September import. All fixture sales and simulated function changes rolled back. Browser leaderboard layout/regression tests passed.
