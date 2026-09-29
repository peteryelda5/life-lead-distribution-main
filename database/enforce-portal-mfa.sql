-- Data API guard covers SECURITY DEFINER RPCs as well as ordinary table access.
create or replace function public.check_portal_request()
returns void language plpgsql security invoker set search_path = '' as $$
begin
 if auth.role()='service_role' then return; end if;
 if auth.role()='authenticated'
 and (ltrim(coalesce(current_setting('request.path',true),''),'/') ~ '(^|/)rpc/account_bootstrap/?$'
 or ltrim(coalesce(current_setting('request.path',true),''),'/')='account_bootstrap')
 and current_setting('request.method',true) in ('GET','HEAD','POST') then return; end if;
 if auth.role() is distinct from 'authenticated' then
   raise sqlstate 'PT401' using message='Sign in to access the portal.';
 end if;
 perform public.require_portal_mfa();
end $$;
revoke all on function public.check_portal_request() from public;
grant execute on function public.check_portal_request() to anon,authenticated,service_role;

-- Restrictive policies also apply outside PostgREST, including Storage and
-- Postgres Changes. Existing division/agent permissive policies remain required.
do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='public' loop
  execute format('drop policy if exists "portal verified session required" on public.%I',t.tablename);
  execute format('create policy "portal verified session required" on public.%I as restrictive for all to authenticated using ((select private.verified_portal_session())) with check ((select private.verified_portal_session()))',t.tablename);
 end loop;
end $$;
drop policy if exists "portal verified session required" on storage.objects;
create policy "portal verified session required" on storage.objects as restrictive for all to authenticated
using ((select private.verified_portal_session())) with check ((select private.verified_portal_session()));
alter role authenticator set pgrst.db_pre_request = 'public.check_portal_request';
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
