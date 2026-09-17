set local lock_timeout='3s';
alter table public.profiles add column is_team_leader boolean not null default false;
alter table public.profiles add column team_leader_id uuid references public.profiles(id) on delete set null;
alter table public.leads add column uploaded_by uuid references public.profiles(id) on delete set null;
create index leads_uploaded_by_created_idx on public.leads(uploaded_by,created_at desc);
create index profiles_team_leader_idx on public.profiles(team_leader_id);
create or replace function private.is_team_leader() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and public.is_active_agent() and exists(select 1 from public.profiles where id=auth.uid() and is_team_leader);
$$;
create or replace function private.leader_division() returns text language sql stable security definer set search_path='' as $$
 select division from public.profiles where id=auth.uid() and private.is_team_leader();
$$;
create or replace function private.stamp_lead_uploader() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  new.uploaded_by:=auth.uid();
  if private.is_team_leader() then
   if new.division is distinct from private.leader_division() then raise exception 'Upload leads only to your division' using errcode='42501'; end if;
   new.status:='unassigned';new.assigned_to:=null;new.assigned_at:=null;new.owner_admin_id:=null;
  end if;
 elsif new.uploaded_by is distinct from old.uploaded_by then raise exception 'Lead uploader cannot be changed'; end if;
 return new;
end $$;
create trigger aaa_stamp_lead_uploader before insert or update on public.leads for each row execute function private.stamp_lead_uploader();
create policy "team leader inserts own leads" on public.leads for insert to authenticated with check ((select private.is_team_leader()) and uploaded_by=(select auth.uid()) and division=(select private.leader_division()) and status='unassigned' and assigned_to is null);
create policy "team leader reads own uploads" on public.leads for select to authenticated using ((select private.is_team_leader()) and uploaded_by=(select auth.uid()) and division=(select private.leader_division()));
-- No direct DELETE or UPDATE policy: deletes use the ownership-checked function below.
create or replace function private.delete_team_uploads(p_ids uuid[]) returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if not private.is_team_leader() then raise exception 'Team leader access required' using errcode='42501'; end if;
 if p_ids is null or cardinality(p_ids)<1 or cardinality(p_ids)>100 then raise exception 'Select between 1 and 100 leads'; end if;
 if exists(select 1 from unnest(p_ids) x(id) left join public.leads l on l.id=x.id where l.id is null or l.uploaded_by is distinct from auth.uid() or l.division is distinct from private.leader_division() or l.status='closed') then raise exception 'You can delete only your own non-closed uploads' using errcode='42501'; end if;
 delete from public.leads where id=any(p_ids) and uploaded_by=auth.uid() and division=private.leader_division() and status<>'closed';
 get diagnostics n=row_count;
 insert into public.audit_logs(actor_id,action,entity_type,details) values(auth.uid(),'team_uploads_deleted','lead',jsonb_build_object('count',n));
 return n;
end $$;
create or replace function public.delete_team_uploads(p_ids uuid[]) returns integer language sql security invoker set search_path='' as $$select private.delete_team_uploads(p_ids)$$;
create or replace function private.validate_team_membership() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.is_team_leader and (new.role<>'agent' or new.team_leader_id is not null) then raise exception 'Team leaders must be agents without another team leader'; end if;
 if new.team_leader_id is not null then
  if new.id=new.team_leader_id or new.role<>'agent' then raise exception 'Invalid team leader assignment'; end if;
  perform 1 from public.profiles where id=new.team_leader_id and role='agent' and is_team_leader and active and not archived and division=new.division for share;
  if not found then raise exception 'Choose an active team leader in the same division'; end if;
 end if;
 if tg_op='UPDATE' and (not new.is_team_leader or new.division is distinct from old.division) and exists(select 1 from public.profiles where team_leader_id=new.id) then raise exception 'Reassign this leader''s agents before changing their role or division'; end if;
 return new;
end $$;
create trigger validate_team_membership before insert or update of is_team_leader,team_leader_id,division,role on public.profiles for each row execute function private.validate_team_membership();
create or replace function private.set_agent_team(p_agent uuid,p_is_leader boolean,p_leader uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Master Admin only' using errcode='42501'; end if;
 if p_is_leader is null then raise exception 'Team leader role is required'; end if;
 update public.profiles set is_team_leader=p_is_leader,team_leader_id=p_leader where id=p_agent and role='agent' and not archived;
 if not found then raise exception 'Agent not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'agent_team_changed','profile',p_agent::text,jsonb_build_object('is_team_leader',p_is_leader,'team_leader_id',p_leader));
end $$;
create or replace function public.set_agent_team(p_agent uuid,p_is_leader boolean,p_leader uuid) returns void language sql security invoker set search_path='' as $$select private.set_agent_team(p_agent,p_is_leader,p_leader)$$;
create or replace function private.my_team_info() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.is_active_agent() then raise exception 'Active agent with 2-step verification required' using errcode='42501'; end if;
 select jsonb_build_object('leader_name',l.full_name,'leader_active',l.active and not l.archived) into result from public.profiles p left join public.profiles l on l.id=p.team_leader_id and l.division=p.division where p.id=auth.uid();
 return result;
end $$;
create or replace function public.my_team_info() returns jsonb language sql security invoker set search_path='' as $$select private.my_team_info()$$;
create or replace function private.agent_reclaim_types(p_agent uuid) returns table(lead_type text,lead_count bigint) language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent) then raise exception 'Cannot manage this agent' using errcode='42501'; end if;
 return query select l.lead_type,count(*) from public.leads l where assigned_to=p_agent and status='assigned' group by l.lead_type order by l.lead_type nulls first;
end $$;
create or replace function public.agent_reclaim_types(p_agent uuid) returns table(lead_type text,lead_count bigint) language sql security invoker set search_path='' as $$select * from private.agent_reclaim_types(p_agent)$$;
create or replace function private.reclaim_agent_leads_filtered(p_agent uuid,p_type text,p_count integer) returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent) then raise exception 'Cannot manage this agent' using errcode='42501'; end if;
 if p_count is null or p_count<1 or p_count>500000 then raise exception 'Enter a quantity between 1 and 500,000'; end if;
 with picked as (select id from public.leads where assigned_to=p_agent and status='assigned' and lead_type is not distinct from p_type order by assigned_at nulls first,created_at,id limit p_count for update)
 update public.leads l set assigned_to=null,status='unassigned',assigned_at=null,updated_at=now() from picked where l.id=picked.id;
 get diagnostics n=row_count;
 if n<>p_count then raise exception 'Only % matching leads are currently available. Refresh and choose a lower quantity.',n; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'agent_leads_reclaimed','profile',p_agent::text,jsonb_build_object('count',n,'lead_type',p_type));
 return n;
end $$;
create or replace function public.reclaim_agent_leads_filtered(p_agent uuid,p_type text,p_count integer) returns integer language sql security invoker set search_path='' as $$select private.reclaim_agent_leads_filtered(p_agent,p_type,p_count)$$;
revoke all on function private.is_team_leader(),private.leader_division(),private.stamp_lead_uploader(),private.validate_team_membership(),private.delete_team_uploads(uuid[]),private.set_agent_team(uuid,boolean,uuid),private.my_team_info(),private.agent_reclaim_types(uuid),private.reclaim_agent_leads_filtered(uuid,text,integer) from public,anon;
grant execute on function private.is_team_leader(),private.leader_division(),private.delete_team_uploads(uuid[]),private.set_agent_team(uuid,boolean,uuid),private.my_team_info(),private.agent_reclaim_types(uuid),private.reclaim_agent_leads_filtered(uuid,text,integer) to authenticated;
revoke all on function public.delete_team_uploads(uuid[]),public.set_agent_team(uuid,boolean,uuid),public.my_team_info(),public.agent_reclaim_types(uuid),public.reclaim_agent_leads_filtered(uuid,text,integer) from public,anon;
grant execute on function public.delete_team_uploads(uuid[]),public.set_agent_team(uuid,boolean,uuid),public.my_team_info(),public.agent_reclaim_types(uuid),public.reclaim_agent_leads_filtered(uuid,text,integer) to authenticated;
