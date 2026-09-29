-- Transfer and assignment commit together; the existing pool/agent controls still work.
create or replace function private.send_leads_to_recipient(p_lead_ids uuid[],p_source text,p_destination text,p_agent_id uuid default null)
returns integer language plpgsql security definer set search_path='' as $$
declare expected integer; n integer;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin and active and not coalesce(archived,false)) then raise exception 'Master only' using errcode='42501';end if;
 if p_source is null or p_source='legacy_life' or p_destination is null then raise exception 'Choose a destination. Legacy leads stay in Legacy.';end if;
 if not exists(select 1 from public.divisions where id=p_destination) then raise exception 'Invalid destination';end if;
 expected:=cardinality(p_lead_ids);
 if expected is null or expected<1 or expected>1000 or array_position(p_lead_ids,null) is not null or (select count(distinct id) from unnest(p_lead_ids) id)<>expected then raise exception 'Select 1–1000 distinct leads';end if;
 if p_agent_id is null then return private.send_leads_to_division(p_lead_ids,p_source,p_destination);end if;
 perform set_config('lock_timeout','3s',true);
 lock table public.leads in row exclusive mode;
 perform id from public.leads where id=any(p_lead_ids) order by id for update;
 if (select count(*) from public.leads where id=any(p_lead_ids) and division=p_source and status='unassigned' and assigned_to is null)<>expected then raise exception 'Some leads changed. Refresh and select again.';end if;
 perform id from public.profiles where id=p_agent_id and role='agent' and active and not coalesce(archived,false) and division=p_destination for share;
 if not found then raise exception 'Agent is not active in the selected division';end if;
 if p_source<>p_destination then perform private.send_leads_to_division(p_lead_ids,p_source,p_destination);end if;
 n:=public.assign_leads_bulk(p_lead_ids,p_agent_id);
 if n<>expected then raise exception 'Assignment changed. No leads were sent. Refresh and try again.';end if;
 return n;
end $$;
create or replace function public.send_leads_to_recipient(p_lead_ids uuid[],p_source text,p_destination text,p_agent_id uuid default null)
returns integer language sql security invoker set search_path='' as $$select private.send_leads_to_recipient(p_lead_ids,p_source,p_destination,p_agent_id)$$;
revoke all on function private.send_leads_to_recipient(uuid[],text,text,uuid),public.send_leads_to_recipient(uuid[],text,text,uuid) from public,anon;
grant execute on function private.send_leads_to_recipient(uuid[],text,text,uuid),public.send_leads_to_recipient(uuid[],text,text,uuid) to authenticated;
