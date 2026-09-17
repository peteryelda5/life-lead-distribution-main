-- Allow active division admins to manage teams in their own division.
create or replace function private.set_agent_team(p_agent uuid,p_is_leader boolean,p_leader uuid)
returns void language plpgsql security definer set search_path='' as $$
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
 if not coalesce(v_master,false) and v_target_division is distinct from v_division then
  raise exception 'You can only manage teams in your own division' using errcode='42501';
 end if;
 update public.profiles set is_team_leader=p_is_leader,team_leader_id=p_leader where id=p_agent;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'agent_team_changed','profile',p_agent::text,
 jsonb_build_object('is_team_leader',p_is_leader,'team_leader_id',p_leader,'division',v_target_division));
end $$;
revoke all on function private.set_agent_team(uuid,boolean,uuid) from public,anon;
grant execute on function private.set_agent_team(uuid,boolean,uuid) to authenticated;
