-- Run after deploying MFA changes. Exercises the exact pre-request gate and
-- one-row bootstrap for both existing role types without changing account data.
do $$
declare actor record; candidate text; profile jsonb; n bigint; rejected boolean;
begin
 for actor in
   (select id,role from public.profiles where active and not coalesce(archived,false)
    and role='admin' order by is_super_admin desc limit 1)
   union all
   (select id,role from public.profiles where active and not coalesce(archived,false)
    and role='agent' order by id limit 1)
 loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'role','authenticated','aal','aal1')::text,true);
  perform set_config('request.method','POST',true);
  set local role authenticated;
  foreach candidate in array array['account_bootstrap','rpc/account_bootstrap','/rpc/account_bootstrap','/rest/v1/rpc/account_bootstrap'] loop
   perform set_config('request.path',candidate,true);
   perform public.check_portal_request();
   profile:=public.account_bootstrap();
   if profile->>'id' <> actor.id::text or profile->>'role' <> actor.role::text then
     raise exception 'Sign-in bootstrap did not return only the caller for %',candidate;
   end if;
  end loop;
  perform set_config('request.path','rpc/admin_dashboard_stats',true);
  rejected:=false;
  begin perform public.check_portal_request(); exception when sqlstate 'PT403' then rejected:=true; end;
  if not rejected then raise exception 'Password-only % session accessed other RPCs',actor.role; end if;
  select count(*) into n from public.leads;
  if n<>0 then raise exception 'Password-only % session accessed lead rows',actor.role; end if;
  reset role;
 end loop;
end $$;
