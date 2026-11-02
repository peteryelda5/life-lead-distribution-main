-- Master admins operate only in their granted agencies. Super Master remains
-- the existing unique owner role; this tier never grants owner-only RPCs.
create table private.master_admin_accounts(
 user_id uuid primary key references public.profiles(id),
 granted_by uuid not null references public.profiles(id),granted_at timestamptz not null default now()
);
alter table private.master_admin_accounts enable row level security;
revoke all on private.master_admin_accounts from public,anon,authenticated;
create policy no_direct_master_role_access on private.master_admin_accounts to authenticated using(false) with check(false);
create function private.is_master_admin()
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.master_admin_accounts m join public.profiles p on p.id=m.user_id
 where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false) and not p.is_super_admin)
$$;
revoke all on function private.is_master_admin() from public,anon,authenticated;
create or replace function public.account_bootstrap()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'role',p.role,
 'active',p.active and not coalesce(p.archived,false),'is_super_admin',p.is_super_admin,'is_master_admin',private.is_master_admin(),
 'created_by_admin_id',p.created_by_admin_id,'division',p.division,
 'is_team_leader',p.is_team_leader,'team_leader_id',p.team_leader_id)
 from public.profiles p where p.id=auth.uid()
$$;
revoke all on function public.account_bootstrap() from public,anon;
grant execute on function public.account_bootstrap() to authenticated;
create or replace function private.can_transfer_lead_pool(p_source text,p_destination text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.verified_portal_session() and p_source is not null and p_source<>'legacy_life' and p_destination is not null
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)
 and (p.is_super_admin or (private.is_master_admin() and p_destination<>'legacy_life'
 and public.admin_can_access_division(p_source) and public.admin_can_access_division(p_destination))))
$$;
create or replace function private.can_recall_agency_pool(p_source text,p_destination text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.verified_portal_session() and p_destination='owner' and p_source<>'owner'
 and exists(select 1 from public.divisions where id=p_source)
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)
 and (p.is_super_admin or (private.is_master_admin() and public.admin_can_access_division('owner') and public.admin_can_access_division(p_source))))
$$;
create or replace function private.assert_agency_recall_access(p_source text)
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(private.can_recall_agency_pool(p_source,'owner'),false) then
 raise exception 'A verified Master Admin with access to this agency and Owner / Master is required' using errcode='42501';end if;
end $$;
create or replace function private.agency_recall_agencies()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.verified_portal_session() or not (public.is_super_admin() or (private.is_master_admin() and public.admin_can_access_division('owner'))) then
 raise exception 'Verified Master Admin access required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'archived',d.archived) order by d.archived,d.name),'[]')
 from public.divisions d where d.id<>'owner' and (public.is_super_admin() or public.admin_can_access_division(d.id)));
end $$;
revoke all on function private.can_transfer_lead_pool(text,text),private.can_recall_agency_pool(text,text),private.assert_agency_recall_access(text) from public,anon,authenticated;
notify pgrst,'reload schema';
