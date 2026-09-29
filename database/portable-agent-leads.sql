-- Agent transfers retain the assignment and the lead's original division.
create table if not exists private.agent_portable_leads (
 lead_id uuid primary key references public.leads(id) on delete cascade,
 agent_id uuid not null references public.profiles(id),
 origin_division text not null references public.divisions(id),
 created_at timestamptz not null default now()
);
revoke all on private.agent_portable_leads from public,anon,authenticated;

create or replace function public.enforce_lead_division() returns trigger language plpgsql security definer set search_path='public' as $function$
declare caller_role public.user_role; caller_super boolean; caller_div text; agent_div text;
begin
 if tg_op='UPDATE' and new.division is distinct from old.division then
  if not (
   (public.is_super_admin() and old.division<>'legacy_life' and old.status='unassigned' and old.assigned_to is null and new.status='unassigned' and new.assigned_to is null)
   or (old.status='closed' and new.status='closed' and old.assigned_to is not null and new.assigned_to=old.assigned_to and public.admin_can_access_division(old.division) and public.admin_can_access_division(new.division) and exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='agent' and p.division=new.division and not coalesce(p.archived,false)))
  ) then raise exception 'Lead division change is not allowed outside an authorized pool or agent transfer.' using errcode='42501'; end if;
 end if;
 if auth.uid() is not null then
  select p.role,p.is_super_admin,p.division into caller_role,caller_super,caller_div from public.profiles p where p.id=auth.uid() and p.active=true;
  if caller_role='admin'::public.user_role then
   if coalesce(caller_super,false) then
    if new.division is null then new.division:=caller_div; end if;
    if tg_op='INSERT' and new.division not in ('owner','vivid_life') then raise exception 'Master can add or move leads only to Vivid Life or Master' using errcode='42501';end if;
    if tg_op='INSERT' and new.owner_admin_id is null then new.owner_admin_id:=auth.uid();end if;
   else
    if caller_div is null then raise exception 'Admin division is not configured';end if;
    if tg_op='UPDATE' and not public.admin_can_access_division(old.division) then raise exception 'You cannot manage leads in another division' using errcode='42501';end if;
    if not public.admin_can_access_division(new.division) then raise exception 'You cannot add or move leads to another division' using errcode='42501';end if;
    if tg_op='INSERT' then new.owner_admin_id:=auth.uid();end if;
   end if;
  end if;
 end if;
 if new.division is null then new.division:='owner';end if;
 if new.assigned_to is not null then
  select p.division into agent_div from public.profiles p where p.id=new.assigned_to and p.role='agent'::public.user_role;
  if agent_div is null or (agent_div<>new.division and not (
   tg_op='UPDATE' and new.status in ('assigned','closed') and new.division=old.division
   and exists(select 1 from private.agent_portable_leads x where x.lead_id=new.id and x.agent_id=new.assigned_to and x.origin_division=new.division)
  )) then raise exception 'Lead and agent must belong to the same division';end if;
 end if;
 return new;
end $function$;

create or replace function private.clear_portable_lead() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.assigned_to is null or new.division is distinct from old.division or exists(select 1 from private.agent_portable_leads x where x.lead_id=new.id and (x.agent_id is distinct from new.assigned_to or x.origin_division is distinct from new.division)) then
  delete from private.agent_portable_leads where lead_id=new.id;
 end if;
 return new;
end $$;
drop trigger if exists z_clear_portable_lead on public.leads;
create trigger z_clear_portable_lead after update on public.leads for each row execute function private.clear_portable_lead();
revoke all on function private.clear_portable_lead() from public,anon,authenticated;

create or replace function private.transfer_agent_division(p_agent_id uuid,p_division text,p_expected_division text) returns jsonb language plpgsql security definer set search_path='' as $function$
declare old_division text; kept_open integer; kept_closed integer;
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent_id) or not public.admin_can_access_division(p_division) then raise exception 'You cannot manage the source or destination division' using errcode='42501';end if;
 if p_division is null or not exists(select 1 from public.divisions where id=p_division) then raise exception 'Invalid division';end if;
 perform set_config('lock_timeout','3s',true);
 lock table public.leads,public.closed_business in share row exclusive mode;
 select division into old_division from public.profiles where id=p_agent_id and role='agent' and not coalesce(archived,false) for update;
 if not found then raise exception 'Active or disabled agent not found; restore archived agents first';end if;
 if old_division is distinct from p_expected_division then raise exception 'The agent division changed. Refresh and try again.';end if;
 if old_division=p_division then return jsonb_build_object('division',p_division,'reclaimed',0,'open_leads_kept',0,'closed_leads_kept',0);end if;
 if exists(select 1 from public.leads l where l.assigned_to=p_agent_id and l.status in ('assigned','closed') and l.division<>old_division and not exists(select 1 from private.agent_portable_leads x where x.lead_id=l.id and x.agent_id=p_agent_id and x.origin_division=l.division)) then raise exception 'An assignment has an unrecognized source division';end if;
 if exists(select 1 from private.leaderboard_monthly_import where agent_id=p_agent_id and not public.admin_can_access_division(division)) then raise exception 'Historical sales exist in an inaccessible division' using errcode='42501';end if;
 insert into private.agent_portable_leads(lead_id,agent_id,origin_division)
 select id,p_agent_id,division from public.leads where assigned_to=p_agent_id and status in ('assigned','closed') and division<>p_division
 on conflict (lead_id) do update set agent_id=excluded.agent_id,origin_division=excluded.origin_division;
 delete from private.agent_portable_leads x using public.leads l where x.lead_id=l.id and l.assigned_to=p_agent_id and l.division=p_division;
 select count(*) filter(where status='assigned'),count(*) filter(where status='closed') into kept_open,kept_closed from public.leads where assigned_to=p_agent_id;
 update public.profiles set division=p_division,team_leader_id=null where id=p_agent_id;
 -- Sales rows retain their original source; team membership follows the profile.
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'agent_division_changed','profile',p_agent_id::text,jsonb_build_object('from_division',old_division,'to_division',p_division,'reclaimed',0,'open_leads_kept',kept_open,'closed_leads_kept',kept_closed));
 return jsonb_build_object('division',p_division,'reclaimed',0,'open_leads_kept',kept_open,'closed_leads_kept',kept_closed);
end $function$;

create or replace function private.agent_reclaim_types(p_agent uuid) returns table(lead_type text,lead_count bigint) language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent) then raise exception 'Cannot manage this agent' using errcode='42501';end if;
 return query select l.lead_type,count(*) from public.leads l where l.assigned_to=p_agent and l.status='assigned' and public.admin_can_access_division(l.division) group by l.lead_type order by l.lead_type nulls first;
end $$;
create or replace function private.reclaim_agent_leads_filtered(p_agent uuid,p_type text,p_count integer) returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent) then raise exception 'Cannot manage this agent' using errcode='42501';end if;
 if p_count is null or p_count<1 or p_count>500000 then raise exception 'Enter a quantity between 1 and 500,000';end if;
 with picked as (select id from public.leads where assigned_to=p_agent and status='assigned' and lead_type is not distinct from p_type and public.admin_can_access_division(division) order by assigned_at nulls first,created_at,id limit p_count for update)
 update public.leads l set assigned_to=null,status='unassigned',assigned_at=null,updated_at=now() from picked where l.id=picked.id;
 get diagnostics n=row_count;
 if n<>p_count then raise exception 'Only % matching leads are currently available. Refresh and choose a lower quantity.',n;end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'agent_leads_reclaimed','profile',p_agent::text,jsonb_build_object('count',n,'lead_type',p_type));
 return n;
end $$;
