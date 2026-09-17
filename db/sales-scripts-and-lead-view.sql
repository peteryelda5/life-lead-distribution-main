create table public.sales_scripts (
 id uuid primary key default gen_random_uuid(),
 division text not null check(division in ('owner','vivid_life','legacy_life')),
 title text not null check(length(btrim(title)) between 1 and 160),
 lead_type text not null default '' check(length(lead_type)<=120),
 body text not null check(length(btrim(body)) between 1 and 50000),
 created_by uuid not null default auth.uid() references public.profiles(id),
 created_at timestamptz not null default now()
);
alter table public.sales_scripts enable row level security;
create index sales_scripts_division_created on public.sales_scripts(division,created_at desc,id desc);
create policy scripts_read on public.sales_scripts for select to authenticated using(
 (public.is_admin() and (public.is_super_admin() or division=public.current_admin_division())) or
 (public.is_active_agent() and division=(select p.division from public.profiles p where p.id=(select auth.uid())))
);
create policy scripts_insert on public.sales_scripts for insert to authenticated with check(
 public.is_admin() and (public.is_super_admin() or division=public.current_admin_division()) and created_by=(select auth.uid())
);
create policy scripts_update on public.sales_scripts for update to authenticated using(
 public.is_admin() and (public.is_super_admin() or division=public.current_admin_division())
) with check(public.is_admin() and (public.is_super_admin() or division=public.current_admin_division()));
create policy scripts_delete on public.sales_scripts for delete to authenticated using(public.is_admin() and (public.is_super_admin() or division=public.current_admin_division()));
revoke all on public.sales_scripts from anon,authenticated;
grant select,delete on public.sales_scripts to authenticated;
grant insert(division,title,lead_type,body) on public.sales_scripts to authenticated;
grant update(title,lead_type,body) on public.sales_scripts to authenticated;

-- Explicit read-only lead access; does not affect admin roles or write helpers.
create table private.extra_lead_read_access(user_id uuid not null references public.profiles(id),division text not null check(division='owner'),primary key(user_id,division));
alter table private.extra_lead_read_access enable row level security;
revoke all on private.extra_lead_read_access from public,anon,authenticated;
create function private.my_extra_lead_divisions() returns text[] language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(g.division),array[]::text[]) from private.extra_lead_read_access g join public.profiles p on p.id=g.user_id where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)
$$;
revoke all on function private.my_extra_lead_divisions() from public,anon;
grant execute on function private.my_extra_lead_divisions() to authenticated;
create function public.my_extra_lead_divisions() returns text[] language sql stable security invoker set search_path='' as $$ select private.my_extra_lead_divisions() $$;
revoke all on function public.my_extra_lead_divisions() from public,anon;
grant execute on function public.my_extra_lead_divisions() to authenticated;
create policy extra_admin_lead_read on public.leads for select to authenticated using (division=any((select private.my_extra_lead_divisions())::text[]));

create policy deny_direct_extra_lead_grant_access on private.extra_lead_read_access for all to authenticated using(false) with check(false);
