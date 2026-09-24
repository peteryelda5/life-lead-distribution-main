create table private.admin_division_access(user_id uuid not null references public.profiles(id),division text not null check(division in ('owner','vivid_life','legacy_life')),primary key(user_id,division));
alter table private.admin_division_access enable row level security;
revoke all on private.admin_division_access from public,anon,authenticated;
create policy deny_direct_admin_grants on private.admin_division_access for all to authenticated using(false) with check(false);
create function private.my_admin_divisions() returns text[] language sql stable security definer set search_path='' as $$
 select coalesce((select case when p.is_super_admin then array['owner','vivid_life','legacy_life']::text[] else array(select distinct d from (select p.division d union select g.division from private.admin_division_access g where g.user_id=p.id) scopes where d is not null order by d) end from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)),array[]::text[])
$$;
revoke all on function private.my_admin_divisions() from public,anon;
grant execute on function private.my_admin_divisions() to authenticated;
create function public.my_admin_divisions() returns text[] language sql stable security invoker set search_path='' as $$select private.my_admin_divisions()$$;
revoke all on function public.my_admin_divisions() from public,anon;
grant execute on function public.my_admin_divisions() to authenticated;
create or replace function public.admin_can_access_division(p_division text) returns boolean language sql stable security invoker set search_path='' as $$select coalesce(p_division=any(private.my_admin_divisions()),false)$$;
revoke all on function public.admin_can_access_division(text) from public,anon;
grant execute on function public.admin_can_access_division(text) to authenticated;
create or replace function public.admin_can_manage_agent(target_agent uuid) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from public.profiles p where p.id=target_agent and p.role='agent' and public.admin_can_access_division(p.division))$$;
revoke all on function public.admin_can_manage_agent(uuid) from public,anon;
grant execute on function public.admin_can_manage_agent(uuid) to authenticated;
alter policy "leads division admin all" on public.leads using(public.admin_can_access_division(division)) with check(public.admin_can_access_division(division));
alter policy "profiles division admin read agents" on public.profiles using(role='agent' and public.admin_can_access_division(division));
alter policy "closed division admin all" on public.closed_business using(public.admin_can_manage_agent(agent_id)) with check(public.admin_can_manage_agent(agent_id));
alter policy scripts_read on public.sales_scripts using(public.admin_can_access_division(division) or (public.is_active_agent() and division=(select p.division from public.profiles p where p.id=auth.uid())));
alter policy scripts_insert on public.sales_scripts with check(public.admin_can_access_division(division) and created_by=auth.uid());
alter policy scripts_update on public.sales_scripts using(public.admin_can_access_division(division)) with check(public.admin_can_access_division(division));
alter policy scripts_delete on public.sales_scripts using(public.admin_can_access_division(division));

CREATE OR REPLACE FUNCTION public.admin_agent_stats()
 RETURNS TABLE(agent_id uuid, open_leads bigint, annual_premium numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  return query
  select p.id,
         coalesce(l.open_leads,0)::bigint,
         coalesce(c.annual_premium,0)::numeric
  from public.profiles p
  left join (
    select assigned_to as agent_id,count(*) as open_leads from public.leads
    where status='assigned' and assigned_to is not null group by assigned_to
  ) l on l.agent_id=p.id
  left join (
    select cb.agent_id,coalesce(sum(cb.annual_premium),0) as annual_premium from public.closed_business cb group by cb.agent_id
  ) c on c.agent_id=p.id
  where p.role='agent'::public.user_role and coalesce(p.archived,false)=false
    and public.admin_can_access_division(p.division);
end; $function$;


CREATE OR REPLACE FUNCTION public.admin_dashboard_stats()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare result jsonb; v_master boolean; v_division text;
begin
 if not public.is_admin() then raise exception 'Admin only'; end if;
 v_master:=public.is_super_admin();
 v_division:=public.current_admin_division();
 select jsonb_build_object(
 'total_leads',count(*),
 'unassigned',count(*) filter(where l.status='unassigned'),
 'assigned',count(*) filter(where l.status='assigned'),
 'closed',count(*) filter(where l.status='closed'))
 into result from public.leads l where public.admin_can_access_division(l.division);
 return result||(select jsonb_build_object(
 'monthly_premium',coalesce(sum(cb.monthly_premium),0),
 'annual_premium',coalesce(sum(cb.annual_premium),0))
 from public.closed_business cb join public.profiles p on p.id=cb.agent_id
 where public.admin_can_access_division(p.division));
end $function$;


CREATE OR REPLACE FUNCTION public.set_lead_division_on_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.division is null or btrim(new.division)='' then
    if public.is_super_admin() then
      new.division := public.current_admin_division();
    elsif public.is_admin() then
      new.division := public.current_admin_division();
    end if;
  end if;
  if new.division not in ('owner','vivid_life','legacy_life') then
    raise exception 'Invalid division';
  end if;
  if public.is_admin() and not public.is_super_admin() and not public.admin_can_access_division(new.division) then
    raise exception 'You cannot add leads to another division';
  end if;
  if public.is_super_admin() and new.division not in ('owner','vivid_life') then
    raise exception 'Master can add leads only to Vivid Life or Master' using errcode='42501';
  end if;
  return new;
end;
$function$;


CREATE OR REPLACE FUNCTION public.admin_lead_filter_counts_scoped(p_division text DEFAULT NULL::text)
 RETURNS TABLE(lead_type text, state text, lead_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare div text;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  div:=coalesce(nullif(btrim(p_division),''),public.current_admin_division());
  if not public.admin_can_access_division(div) then raise exception 'Division access denied' using errcode='42501';end if;
  if div is null then raise exception 'Admin division is not configured'; end if;
  return query
  select nullif(btrim(l.lead_type),'') as lead_type,
         nullif(btrim(l.state),'') as state,
         count(*)::bigint as lead_count
  from public.leads l
  where l.status='unassigned' and l.division=div
  group by nullif(btrim(l.lead_type),''),nullif(btrim(l.state),'');
end;
$function$;


CREATE OR REPLACE FUNCTION public.admin_delete_all_leads_scoped(p_division text DEFAULT NULL::text, p_include_closed boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare deleted_count integer:=0; div text;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  div:=coalesce(nullif(btrim(p_division),''),public.current_admin_division());
  if not public.admin_can_access_division(div) then raise exception 'Division access denied' using errcode='42501';end if;
  if div is null then raise exception 'Admin division is not configured'; end if;
  if p_include_closed then
    delete from public.closed_business cb using public.profiles p where cb.agent_id=p.id and p.division=div;
    delete from public.leads where division=div;
  else
    delete from public.leads where division=div and status<>'closed';
  end if;
  get diagnostics deleted_count=row_count;
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(auth.uid(),'division_leads_deleted','lead',jsonb_build_object('count',deleted_count,'division',div,'include_closed',p_include_closed));
  return deleted_count;
end;
$function$;


CREATE OR REPLACE FUNCTION public.admin_delete_active_leads_in_division(p_division text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare deleted_count integer:=0; div text;
begin
 if not public.is_admin() then raise exception 'Admin only'; end if;
 div:=coalesce(nullif(p_division,''),public.current_admin_division());
 if div not in ('owner','vivid_life','legacy_life') then raise exception 'Invalid division'; end if;
 if not public.admin_can_access_division(div) then raise exception 'You cannot manage that division'; end if;
 delete from public.leads where status<>'closed' and division=div;
 get diagnostics deleted_count=row_count;
 insert into public.audit_logs(actor_id,action,entity_type,details) values(auth.uid(),'division_active_leads_deleted','lead',jsonb_build_object('count',deleted_count,'division',div));
 return deleted_count;
end; $function$;


CREATE OR REPLACE FUNCTION public.dashboard_overview(p_division text DEFAULT NULL::text, p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_div text; v_start timestamptz; result jsonb;
begin
 if not coalesce(public.is_admin(),false) then raise exception 'Admin only' using errcode='42501'; end if;
 if p_days is null or p_days not in (7,30,90) then raise exception 'Invalid dashboard period'; end if;
 v_div := coalesce(p_division,public.current_admin_division());
 if v_div is null or v_div not in ('all','owner','vivid_life','legacy_life') then raise exception 'Invalid division'; end if;
 if not coalesce(public.is_super_admin(),false) and not public.admin_can_access_division(v_div) then raise exception 'Division access denied' using errcode='42501'; end if;
 v_start := ((current_timestamp at time zone 'UTC')::date - (p_days-1))::timestamp at time zone 'UTC';
 with inventory as (
  select count(*) total_leads,count(*) filter(where status='unassigned') unassigned,
   count(*) filter(where status='assigned') assigned,count(*) filter(where status='closed') closed
  from public.leads where (v_div='all' or division=v_div)
 ), sales as materialized (
  select c.agent_id,count(*) closed_count,coalesce(sum(c.monthly_premium),0) monthly_premium,coalesce(sum(c.annual_premium),0) annual_premium
  from public.closed_business c join public.profiles p on p.id=c.agent_id
  where (v_div='all' or p.division=v_div) and c.created_at>=v_start group by c.agent_id
 ), workload as (
  select assigned_to,count(*) assigned from public.leads where (v_div='all' or division=v_div) and status='assigned' and assigned_to is not null group by assigned_to
 ), ranking as (
  select p.id,p.full_name,p.division,p.active,coalesce(p.archived,false) archived,coalesce(w.assigned,0) assigned,
   coalesce(s.closed_count,0) closed_count,coalesce(s.monthly_premium,0) monthly_premium
  from public.profiles p left join workload w on w.assigned_to=p.id left join sales s on s.agent_id=p.id
  where p.role='agent' and (v_div='all' or p.division=v_div) and (not coalesce(p.archived,false) or coalesce(s.closed_count,0)>0 or coalesce(w.assigned,0)>0)
 ), daily as (
  select (created_at at time zone 'UTC')::date as day,count(*) n from public.leads where (v_div='all' or division=v_div) and created_at>=v_start group by 1
 ), series as (
  select (v_start at time zone 'UTC')::date+i as day,coalesce(d.n,0) count
  from generate_series(0,p_days-1) i left join daily d on d.day=(v_start at time zone 'UTC')::date+i
 )
 select jsonb_build_object('division',v_div,'days',p_days,'period_start',v_start,'inventory',(select to_jsonb(i) from inventory i),
 'monthly_premium',coalesce((select sum(monthly_premium) from sales),0),'annual_premium',coalesce((select sum(annual_premium) from sales),0),
 'closed_period',coalesce((select sum(closed_count) from sales),0),
 'active_agents',(select count(*) from public.profiles p where p.role='agent' and (v_div='all' or p.division=v_div) and p.active and not coalesce(p.archived,false)),
 'leaderboard',coalesce((select jsonb_agg(to_jsonb(r) order by r.closed_count desc,r.monthly_premium desc,r.assigned desc,r.id) from ranking r),'[]'::jsonb),
 'trend',(select jsonb_agg(to_jsonb(s) order by s.day) from series s)) into result;
 return result;
end $function$;


CREATE OR REPLACE FUNCTION private.set_agent_team(p_agent uuid, p_is_leader boolean, p_leader uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_master boolean; v_division text; v_target_division text;
begin
 if auth.uid() is null then raise exception 'Active admin only' using errcode='42501'; end if;
 select p.is_super_admin,p.division into v_master,v_division from public.profiles p
 where p.id=auth.uid() and p.role='admin' and p.active and not p.archived for share;
 if not found then raise exception 'Active admin only' using errcode='42501'; end if;
 if p_is_leader is null then raise exception 'Team leader role is required'; end if;
 select p.division into v_target_division from public.profiles p
 where p.id=p_agent and p.role='agent' and not p.archived for update;
 if not found then raise exception 'Agent not found'; end if;
 if not public.admin_can_access_division(v_target_division) then
  raise exception 'You can only manage teams in your own division' using errcode='42501';
 end if;
 update public.profiles set is_team_leader=p_is_leader,team_leader_id=p_leader where id=p_agent;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'agent_team_changed','profile',p_agent::text,
 jsonb_build_object('is_team_leader',p_is_leader,'team_leader_id',p_leader,'division',v_target_division));
end $function$;

CREATE OR REPLACE FUNCTION private.transfer_agent_division(p_agent_id uuid, p_division text, p_expected_division text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_division text; reclaimed integer;
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent_id) or not public.admin_can_access_division(p_division) then
  raise exception 'You cannot manage the source or destination division' using errcode='42501';
 end if;
 if p_division is null or p_division not in ('owner','vivid_life','legacy_life') then raise exception 'Invalid division'; end if;
 perform set_config('lock_timeout','3s',true);
 -- Serialize against assignments and closings so none can cross the transfer.
 lock table public.leads,public.closed_business in share row exclusive mode;
 select division into old_division from public.profiles where id=p_agent_id and role='agent' and not coalesce(archived,false) for update;
 if not found then raise exception 'Active or disabled agent not found; restore archived agents first'; end if;
 if old_division is distinct from p_expected_division then raise exception 'The agent division changed. Refresh and try again.'; end if;
 if old_division=p_division then return jsonb_build_object('division',p_division,'reclaimed',0); end if;
 if exists(select 1 from public.closed_business where agent_id=p_agent_id) or exists(select 1 from public.leads where assigned_to=p_agent_id and status='closed') then
  raise exception 'This agent has closed business. Transfer blocked to keep sales history within its original division.';
 end if;
 update public.leads set assigned_to=null,status='unassigned',assigned_at=null,updated_at=now() where assigned_to=p_agent_id and status='assigned';
 get diagnostics reclaimed=row_count;
 if exists(select 1 from public.leads where assigned_to=p_agent_id) then raise exception 'Other lead assignments must be resolved before moving this agent'; end if;
 update public.profiles set division=p_division where id=p_agent_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'agent_division_changed','profile',p_agent_id::text,jsonb_build_object('from_division',old_division,'to_division',p_division,'reclaimed',reclaimed));
 return jsonb_build_object('division',p_division,'reclaimed',reclaimed);
end $function$;

CREATE OR REPLACE FUNCTION public.enforce_lead_division()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller_role public.user_role;
  caller_super boolean;
  caller_div text;
  agent_div text;
begin
  if tg_op='UPDATE' and new.division is distinct from old.division then raise exception 'Lead division cannot be changed; division pools stay separate' using errcode='42501';end if;
  if auth.uid() is not null then
    select p.role,p.is_super_admin,p.division into caller_role,caller_super,caller_div
    from public.profiles p where p.id=auth.uid() and p.active=true;

    if caller_role='admin'::public.user_role then
      if coalesce(caller_super,false) then
        if new.division is null then new.division:=caller_div; end if;
        if (tg_op='INSERT' or (tg_op='UPDATE' and new.division is distinct from old.division))
           and new.division not in ('owner','vivid_life') then
          raise exception 'Master can add or move leads only to Vivid Life or Master' using errcode='42501';
        end if;
        if tg_op='INSERT' and new.owner_admin_id is null then new.owner_admin_id:=auth.uid(); end if;
      else
        if caller_div is null then raise exception 'Admin division is not configured'; end if;
        if tg_op='UPDATE' and not public.admin_can_access_division(old.division) then
          raise exception 'You cannot manage leads in another division' using errcode='42501';
        end if;
        if not public.admin_can_access_division(new.division) then
          raise exception 'You cannot add or move leads to another division' using errcode='42501';
        end if;
        if tg_op='INSERT' then new.owner_admin_id:=auth.uid(); end if;
      end if;
    end if;
  end if;

  if new.division is null then new.division:='owner'; end if;
  if new.assigned_to is not null then
    select p.division into agent_div from public.profiles p where p.id=new.assigned_to and p.role='agent'::public.user_role;
    if agent_div is null or agent_div<>new.division then
      raise exception 'Lead and agent must belong to the same division';
    end if;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION private.can_manage_lead_request(p_agent uuid, p_division text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from public.profiles me where me.id=auth.uid() and me.active and not coalesce(me.archived,false) and
 ((me.role='admin' and (public.admin_can_access_division(p_division))) or
 (me.role='agent' and me.is_team_leader and public.is_active_agent() and me.division=p_division and exists(select 1 from public.profiles a where a.id=p_agent and a.team_leader_id=me.id and a.division=me.division))))
$function$;
