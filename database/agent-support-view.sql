-- Opens an audited, read-only support view. The Master remains the caller;
-- no agent credentials, factors, session, or roles are exchanged.
create or replace function public.open_agent_support(p_agent uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
 if auth.jwt()->>'aal' <> 'aal2' or not exists (
   select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'
   and p.is_super_admin and p.active and not coalesce(p.archived,false)) then
   raise exception 'Verified Master account required' using errcode='42501';
 end if;
 if not exists (select 1 from public.profiles p where p.id=p_agent and p.role='agent'
 and p.active and not coalesce(p.archived,false)) then
   raise exception 'Active agent not found' using errcode='22023';
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values (auth.uid(),'agent_support_view','profile',p_agent::text,jsonb_build_object('mode','read_only'));
 return true;
end $$;
revoke all on function public.open_agent_support(uuid) from public,anon;
grant execute on function public.open_agent_support(uuid) to authenticated;
