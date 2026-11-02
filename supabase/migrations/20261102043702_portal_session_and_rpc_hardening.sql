-- Require a live, account-bound session for both authenticator and passkey access.
-- No user records, sessions, or existing agency scopes are changed.
CREATE OR REPLACE FUNCTION private.verified_portal_session()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
 SELECT EXISTS (
  SELECT 1 FROM auth.sessions s JOIN public.profiles p ON p.id=s.user_id
  WHERE s.id=nullif(auth.jwt()->>'session_id','')::uuid AND s.user_id=auth.uid()
   AND (s.not_after IS NULL OR s.not_after>now())
   AND p.active AND NOT coalesce(p.archived,false) AND p.role IN ('admin','agent')
 ) AND (coalesce(auth.jwt()->>'aal'='aal2',false)
  OR private.portal_passkey_session_valid(auth.uid(),nullif(auth.jwt()->>'session_id','')::uuid));
$function$;

-- Preserve existing signed-in/server execution; remove inherited anonymous access.
-- check_portal_request remains callable because PostgREST uses it to reject anonymous requests.
DO $block$
DECLARE f record;
BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname IN (
  'admin_closed_page','admin_dashboard_summary','admin_delete_active_leads_in_division',
  'admin_delete_all_leads_scoped','admin_lead_filter_counts','admin_lead_filter_counts_scoped',
  'admin_lead_filter_options','admin_lead_ids_for_filter','admin_lead_page','agent_closed_page',
  'agent_lead_page','agent_portal_summary','assign_agent_owner_from_audit',
  'current_admin_division','is_super_admin','set_lead_owner_admin')
 LOOP
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role',f.signature);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon',f.signature);
 END LOOP;
END $block$;
