-- Install with enforcement off. Enable only after the matching portal is deployed.
alter table public.portal_onboarding_checklists add column if not exists is_licensed boolean;

create table private.portal_onboarding_gate (
 singleton boolean primary key default true check (singleton),
 enabled boolean not null default false
);
insert into private.portal_onboarding_gate(singleton,enabled) values(true,false);
revoke all on private.portal_onboarding_gate from public,anon,authenticated;
grant all on private.portal_onboarding_gate to service_role;

create function private.portal_onboarding_status(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 p public.profiles; c public.portal_onboarding_checklists;
 r public.portal_onboarding_resources; acknowledged boolean; signed boolean;
 steps boolean[]; complete boolean; enabled boolean;
begin
 select * into p from public.profiles where id=p_user;
 select * into c from public.portal_onboarding_checklists where user_id=p_user;
 select * into r from public.portal_onboarding_resources where user_id=p_user;
 select g.enabled into enabled from private.portal_onboarding_gate g where singleton;
 acknowledged:=exists(select 1 from public.portal_onboarding_receipts where user_id=p_user and completion_kind='acknowledged');
 signed:=exists(select 1 from public.portal_signwell_agreements where user_id=p_user and environment='live'
  and not superseded and status='completed' and document_id is not null and completed_at is not null)
  or exists(select 1 from public.portal_docusign_agreements where user_id=p_user and environment='live'
  and not superseded and status='completed' and envelope_id is not null and completed_at is not null);
 steps:=array[
  c.welcome_read_at is not null or acknowledged,
  (c.compliance_acknowledged_at is not null or acknowledged) and signed,
  coalesce(c.is_licensed or r.xcel,false),
  coalesce(c.is_licensed or r.study,false),
  coalesce(c.is_licensed or r.exam,false),
  c.is_licensed=false or (c.is_licensed=true and coalesce(c.npn ~ '^[0-9]{1,10}$',false) and cardinality(c.licensed_states)>0)
 ];
 steps[6]:=coalesce(steps[6],false);
 complete:=not(false=any(steps));
 return jsonb_build_object('required',p.role='agent' and coalesce(enabled,false),
  'complete',complete,'allowed',coalesce(p.active and not p.archived and
   (p.role='admin' or (p.role='agent' and (not coalesce(enabled,false) or complete))),false),
  'steps',to_jsonb(steps),'isLicensed',c.is_licensed,'agreementComplete',signed);
end $$;
revoke all on function private.portal_onboarding_status(uuid) from public,anon,authenticated;
grant execute on function private.portal_onboarding_status(uuid) to service_role;

create function private.portal_onboarding_allowed(p_user uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce((private.portal_onboarding_status(p_user)->>'allowed')::boolean,false)
$$;
revoke all on function private.portal_onboarding_allowed(uuid) from public,anon,authenticated;
grant execute on function private.portal_onboarding_allowed(uuid) to service_role;

create function private.portal_onboarding_allowed() returns boolean
language sql stable security definer set search_path='' as $$
 select private.portal_onboarding_allowed(auth.uid())
$$;
revoke all on function private.portal_onboarding_allowed() from public,anon;
grant execute on function private.portal_onboarding_allowed() to authenticated,service_role;

create function public.portal_onboarding_status() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform public.require_portal_mfa();
 return private.portal_onboarding_status(auth.uid());
end $$;
revoke all on function public.portal_onboarding_status() from public,anon;
grant execute on function public.portal_onboarding_status() to authenticated;

create function public.require_portal_onboarding() returns boolean
language plpgsql stable security definer set search_path='' as $$
begin
 perform public.require_portal_mfa();
 if not private.portal_onboarding_allowed() then
  raise sqlstate 'PT403' using message='Complete onboarding and the signed NDA and chargeback agreement before opening the portal.',detail='ONBOARDING_REQUIRED';
 end if;
 return true;
end $$;
revoke all on function public.require_portal_onboarding() from public,anon;
grant execute on function public.require_portal_onboarding() to authenticated;

create function public.save_portal_licensing(p_licensed boolean,p_npn text default null,p_states text[] default '{}') returns void
language plpgsql security definer set search_path='' as $$
declare states text[]; npn text:=nullif(btrim(p_npn),'');
begin
 perform public.require_portal_mfa();
 if p_licensed is null then raise exception 'Choose whether you are currently licensed.';end if;
 select coalesce(array_agg(distinct s order by s),'{}') into states from unnest(p_states) s;
 if p_licensed then
  if npn is null or npn !~ '^[0-9]{1,10}$' then raise exception 'Enter a valid NPN (1 to 10 digits).';end if;
  if p_states is null or array_position(p_states,null) is not null or cardinality(states)=0 or not states<@array['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY']::text[] then
   raise exception 'Select at least one valid licensed state.';
  end if;
 end if;
 insert into public.portal_onboarding_checklists(user_id,is_licensed,npn,licensed_states)
 values(auth.uid(),p_licensed,case when p_licensed then npn end,case when p_licensed then states else '{}' end)
 on conflict(user_id) do update set is_licensed=excluded.is_licensed,
  npn=case when p_licensed then excluded.npn else public.portal_onboarding_checklists.npn end,
  licensed_states=case when p_licensed then excluded.licensed_states else public.portal_onboarding_checklists.licensed_states end,updated_at=now();
end $$;
revoke all on function public.save_portal_licensing(boolean,text,text[]) from public,anon;
grant execute on function public.save_portal_licensing(boolean,text,text[]) to authenticated;

create or replace function public.check_portal_request() returns void
language plpgsql security definer set search_path='' as $$
declare path text:=regexp_replace(ltrim(coalesce(current_setting('request.path',true),''),'/'),'^rest/v1/','');
 method text:=current_setting('request.method',true);
begin
 if auth.role()='service_role' then return;end if;
 if auth.role()='authenticated' and path in('rpc/account_bootstrap','account_bootstrap') and method in('GET','HEAD','POST') then return;end if;
 if auth.role() is distinct from 'authenticated' then raise sqlstate 'PT401' using message='Sign in to the portal first.';end if;
 perform public.require_portal_mfa();
 if path in('rpc/require_portal_mfa','rpc/portal_onboarding_status','rpc/require_portal_onboarding',
  'rpc/save_portal_onboarding_checklist','rpc/save_portal_licensing') then return;end if;
 if path in('profiles','portal_onboarding_checklists','portal_onboarding_receipts') and method in('GET','HEAD') then return;end if;
 perform public.require_portal_onboarding();
end $$;

-- PostgREST pre-request also protects security-definer RPCs. Restrictive RLS
-- protects table reads via Realtime and Storage as well as direct REST access.
do $$ declare t record;begin
 for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in('r','p') and c.relrowsecurity
  and c.relname not in('profiles','portal_onboarding_checklists','portal_onboarding_receipts') loop
  execute format('create policy "portal onboarding required" on public.%I as restrictive for all to authenticated using ((select private.portal_onboarding_allowed())) with check ((select private.portal_onboarding_allowed()))',t.relname);
 end loop;
end $$;
create policy "portal onboarding required" on public.profiles as restrictive for all to authenticated
 using(id=(select auth.uid()) or (select private.portal_onboarding_allowed()))
 with check((select private.portal_onboarding_allowed()));
create policy "portal onboarding required" on storage.objects as restrictive for all to authenticated
 using((select private.portal_onboarding_allowed())) with check((select private.portal_onboarding_allowed()));

-- Suppress private chat/deal previews for incomplete agents, including already
-- queued deliveries (the dispatcher revalidates each item before sending).
create or replace function private.portal_push_items(p_user uuid,p_session uuid)
returns table(event_key text,category text,title text,body text,target jsonb,occurred_at timestamptz,source_read boolean)
language plpgsql security definer set search_path='' as $$
declare old_claims text:=current_setting('request.jwt.claims',true);old_sub text:=current_setting('request.jwt.claim.sub',true);
begin
 if not private.portal_push_session_valid(p_user,p_session) or not private.portal_onboarding_allowed(p_user) then return;end if;
 perform set_config('request.jwt.claim.sub',p_user::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'aal','aal2','role','authenticated','session_id',p_session)::text,true);
 return query select n.* from private.portal_notification_items() n;
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
exception when others then
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
 raise;
end $$;
notify pgrst,'reload schema';
