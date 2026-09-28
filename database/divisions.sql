-- A registry replaces the fixed three-division allowlist. Existing role boundaries remain.
set lock_timeout='5s';
create table public.divisions(id text primary key,name text not null check(char_length(name) between 2 and 80),is_system boolean not null default false,created_at timestamptz not null default now(),created_by uuid references public.profiles(id));
create unique index divisions_name_unique on public.divisions(lower(name));
insert into public.divisions(id,name,is_system) values('owner','Owner / Master',true),('vivid_life','Vivid Life',true),('legacy_life','Legacy Life',true);
alter table public.divisions enable row level security;
revoke all on public.divisions from public,anon,authenticated;
grant select on public.divisions to authenticated;
grant all on public.divisions to service_role;
create policy "Members see permitted divisions" on public.divisions for select to authenticated using(id=any(private.leaderboard_divisions()));
-- Keep the Peter-only Master constraint and the owner-only legacy read grant unchanged.
do $$declare r record;begin
 for r in select * from (values('public','profiles'),('public','leads'),('public','sales_scripts'),('public','chat_messages'),('private','admin_division_access'),('private','leaderboard_monthly_import')) v(s,t) loop
  execute format('alter table %I.%I drop constraint %I',r.s,r.t,r.t||'_division_check');
 end loop;
 for r in select * from (values('public','profiles'),('public','leads'),('public','sales_scripts'),('public','chat_messages'),('private','admin_division_access'),('private','leaderboard_monthly_import'),('public','lead_requests'),('public','leaderboard_updates'),('private','chat_reads'),('private','chat_pins')) v(s,t) loop
  execute format('alter table %I.%I add constraint %I foreign key (division) references public.divisions(id) not valid',r.s,r.t,r.t||'_division_registry_fk');
 end loop;
end $$;
create function private.create_division(p_name text,p_admin_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare new_id text:='division_'||replace(gen_random_uuid()::text,'-',''); clean_name text:=btrim(regexp_replace(p_name,'\s+',' ','g')); result jsonb;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and is_super_admin and role='admin' and active and not coalesce(archived,false)) then raise exception 'Master Admin only' using errcode='42501';end if;
 if clean_name is null or char_length(clean_name) not between 2 and 80 then raise exception 'Enter a division name between 2 and 80 characters';end if;
 if p_admin_id is not null and not exists(select 1 from public.profiles where id=p_admin_id and role='admin' and active and not is_super_admin and not coalesce(archived,false)) then raise exception 'Choose an active division admin';end if;
 insert into public.divisions(id,name,created_by) values(new_id,clean_name,auth.uid());
 insert into public.leaderboard_updates(division) values(new_id);
 if p_admin_id is not null then insert into private.admin_division_access(user_id,division) values(p_admin_id,new_id);end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'division_created','division',new_id,jsonb_build_object('name',clean_name,'admin_id',p_admin_id));
 return jsonb_build_object('id',new_id,'name',clean_name);
exception when unique_violation then raise exception 'A division with that name already exists';
end $$;
create function public.create_division(p_name text,p_admin_id uuid default null) returns jsonb language sql security invoker set search_path='' as $$ select private.create_division(p_name,p_admin_id); $$;
revoke all on function private.create_division(text,uuid),public.create_division(text,uuid) from public,anon;
grant execute on function private.create_division(text,uuid),public.create_division(text,uuid) to authenticated;
create function private.division_admin_directory() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and is_super_admin and role='admin' and active and not coalesce(archived,false)) then raise exception 'Master Admin only' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'is_system',d.is_system,'admins',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name,'active',p.active) order by p.full_name),'[]') from public.profiles p where p.role='admin' and not p.is_super_admin and not coalesce(p.archived,false) and (p.division=d.id or exists(select 1 from private.admin_division_access a where a.user_id=p.id and a.division=d.id)))) order by d.created_at,d.name),'[]') from public.divisions d);
end $$;
create function public.division_admin_directory() returns jsonb language sql security invoker set search_path='' as $$ select private.division_admin_directory(); $$;
revoke all on function private.division_admin_directory(),public.division_admin_directory() from public,anon;
grant execute on function private.division_admin_directory(),public.division_admin_directory() to authenticated;
CREATE OR REPLACE FUNCTION private.signal_leaderboard_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$begin update public.leaderboard_updates set revision=revision+1,updated_at=clock_timestamp() where division is not null;return null;end $function$
;
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
  if not exists(select 1 from public.divisions where id=new.division) then
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
$function$
;
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
 if p_division is null or not exists(select 1 from public.divisions where id=p_division) then raise exception 'Invalid division'; end if;
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
end $function$
;
CREATE OR REPLACE FUNCTION private.my_admin_divisions()
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce((select case when p.is_super_admin then array(select d.id from public.divisions d order by d.created_at,d.id) else array(select distinct d from (select p.division d union select g.division from private.admin_division_access g where g.user_id=p.id) scopes where d is not null order by d) end from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)),array[]::text[])
$function$
;
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
 if not exists(select 1 from public.divisions where id=div) then raise exception 'Invalid division'; end if;
 if not public.admin_can_access_division(div) then raise exception 'You cannot manage that division'; end if;
 delete from public.leads where status<>'closed' and division=div;
 get diagnostics deleted_count=row_count;
 insert into public.audit_logs(actor_id,action,entity_type,details) values(auth.uid(),'division_active_leads_deleted','lead',jsonb_build_object('count',deleted_count,'division',div));
 return deleted_count;
end; $function$
;
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
 if v_div is null or (v_div<>'all' and not exists(select 1 from public.divisions where id=v_div)) then raise exception 'Invalid division'; end if;
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
end $function$
;
notify pgrst,'reload schema';
