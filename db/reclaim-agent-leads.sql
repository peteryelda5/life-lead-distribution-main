create or replace function private.reclaim_agent_leads(p_agent_id uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare reclaimed integer;
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent_id) then
  raise exception 'You cannot manage this agent' using errcode='42501';
 end if;
 update public.leads set assigned_to=null,status='unassigned',assigned_at=null,updated_at=now()
 where assigned_to=p_agent_id and status='assigned';
 get diagnostics reclaimed=row_count;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'agent_leads_reclaimed','profile',p_agent_id::text,jsonb_build_object('count',reclaimed));
 return reclaimed;
end $$;
revoke all on function private.reclaim_agent_leads(uuid) from public,anon;
grant execute on function private.reclaim_agent_leads(uuid) to authenticated;
create or replace function public.reclaim_agent_leads(p_agent_id uuid)
returns integer language sql security invoker set search_path='' as $$ select private.reclaim_agent_leads(p_agent_id); $$;
revoke all on function public.reclaim_agent_leads(uuid) from public,anon;
grant execute on function public.reclaim_agent_leads(uuid) to authenticated;
