-- Only Vivid Life's designated sales-process sheet is shared across agencies.
-- Existing restrictive session/onboarding checks and all write policies remain in force.
create policy master_sales_process_read on public.sales_scripts
 for select to authenticated using (
  division = 'vivid_life' and lead_type = 'Sales Process / Objection Sheet'
  and ((select public.is_admin()) or (select public.is_active_agent()))
 );
