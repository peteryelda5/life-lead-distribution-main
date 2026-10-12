-- Cover the small fields used by inventory, filters and folder counts without
-- loading every lead's CSV payload. All existing RLS policies remain in force.
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';

CREATE INDEX IF NOT EXISTS leads_inventory_cover_idx
ON public.leads (division, status, created_at DESC, id DESC)
INCLUDE (assigned_to, uploaded_by, lead_type, state);

CREATE INDEX IF NOT EXISTS leads_assigned_folder_cover_idx
ON public.leads (assigned_to, lead_type, state)
INCLUDE (division, uploaded_by, status)
WHERE status = 'assigned';

ANALYZE public.leads;
