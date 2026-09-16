create schema if not exists private;
create or replace function private.transfer_agent_division(p_agent_id uuid,p_division text,p_expected_division text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare old_division text; reclaimed integer;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='admin' and active and is_super_admin) then
  raise exception 'Only the Master Admin can change agent divisions' using errcode='42501';
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
end $$;
revoke all on function private.transfer_agent_division(uuid,text,text) from public,anon;
grant usage on schema private to authenticated;
grant execute on function private.transfer_agent_division(uuid,text,text) to authenticated;
create or replace function public.transfer_agent_division(p_agent_id uuid,p_division text,p_expected_division text)
returns jsonb language sql security invoker set search_path='' as $$ select private.transfer_agent_division(p_agent_id,p_division,p_expected_division); $$;
revoke all on function public.transfer_agent_division(uuid,text,text) from public,anon;
grant execute on function public.transfer_agent_division(uuid,text,text) to authenticated;
