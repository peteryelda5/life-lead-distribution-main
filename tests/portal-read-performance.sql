-- Read-only security regression check; no account, lead or permission changes.
BEGIN;
DO $test$
DECLARE admin_id uuid; admin_div text; agent_id uuid; master_id uuid;
expected bigint; visible bigint; result jsonb; denied boolean;
BEGIN
 SELECT id,division INTO admin_id,admin_div FROM public.profiles
 WHERE role='admin' AND active AND NOT coalesce(archived,false) AND NOT is_super_admin
 AND division IS NOT NULL ORDER BY id LIMIT 1;
 SELECT id INTO agent_id FROM public.profiles WHERE role='agent' AND active AND NOT coalesce(archived,false) ORDER BY id LIMIT 1;
 SELECT id INTO master_id FROM public.profiles WHERE role='admin' AND active AND is_super_admin ORDER BY id LIMIT 1;
 IF admin_id IS NULL OR agent_id IS NULL OR master_id IS NULL THEN RAISE EXCEPTION 'Missing role fixtures'; END IF;
 SELECT count(*) INTO expected FROM public.leads WHERE division=admin_div;
 IF (SELECT prosecdef FROM pg_proc WHERE oid='public.dashboard_overview(text,integer)'::regprocedure) THEN RAISE EXCEPTION 'Dashboard must keep invoker rights'; END IF;
 EXECUTE 'SET LOCAL ROLE authenticated';
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated','aal','aal2')::text,true);
 result:=public.dashboard_overview(admin_div,30);
 IF (result->'inventory'->>'total_leads')::bigint<>expected THEN RAISE EXCEPTION 'Scoped admin total changed'; END IF;
 denied:=false;
 BEGIN PERFORM public.dashboard_overview('all',30); EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
 IF NOT denied THEN RAISE EXCEPTION 'Ordinary admin accessed all agencies'; END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',agent_id,'role','authenticated','aal','aal2')::text,true);
 denied:=false;
 BEGIN PERFORM public.dashboard_overview(admin_div,30); EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
 IF NOT denied THEN RAISE EXCEPTION 'Agent accessed admin dashboard'; END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal1')::text,true);
 SELECT count(*) INTO visible FROM public.leads;
 IF visible<>0 THEN RAISE EXCEPTION 'Unverified session read leads'; END IF;
 result:=public.dashboard_overview('all',30);
 IF (result->'inventory'->>'total_leads')::bigint<>0 THEN RAISE EXCEPTION 'Unverified dashboard leaked inventory'; END IF;
 EXECUTE 'RESET ROLE';
 PERFORM set_config('vivid.security_check','PASS: scoped totals, admin/agent boundaries, MFA, and invoker rights',true);
END $test$;
SELECT current_setting('vivid.security_check') AS result;
ROLLBACK;

