-- Serialize saves and detect edits from another window without changing lead outcomes.
create function private.save_lead_call_notes(p_lead_id uuid, p_notes text, p_expected_notes text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_notes text; desired text := nullif(btrim(coalesce(p_notes,'')),'');
begin
  if auth.uid() is null or not private.can_work_assigned_leads() then
    raise exception 'Account access is not active' using errcode='42501';
  end if;
  if length(coalesce(p_notes,'')) > 10000 then
    raise exception 'Call notes must be 10,000 characters or fewer.';
  end if;
  select l.call_notes into current_notes from public.leads l
  where l.id=p_lead_id and l.assigned_to=auth.uid() and l.status='assigned'
  for update;
  if not found then
    raise exception 'Lead is not assigned to you' using errcode='42501';
  end if;
  -- A retry after a lost response is a success and does not duplicate the audit.
  if current_notes is not distinct from desired then
    return jsonb_build_object('saved',true,'notes',current_notes);
  end if;
  if current_notes is distinct from p_expected_notes then
    return jsonb_build_object('saved',false,'notes',current_notes);
  end if;
  update public.leads set call_notes=desired where id=p_lead_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'lead_call_notes_updated','lead',p_lead_id::text,
    jsonb_build_object('has_notes',desired is not null));
  return jsonb_build_object('saved',true,'notes',desired);
end;
$$;
create function public.save_lead_call_notes(p_lead_id uuid, p_notes text, p_expected_notes text)
returns jsonb language sql security invoker set search_path='' as $$
  select private.save_lead_call_notes(p_lead_id,p_notes,p_expected_notes);
$$;
revoke all on function private.save_lead_call_notes(uuid,text,text) from public, anon;
revoke all on function public.save_lead_call_notes(uuid,text,text) from public, anon;
grant execute on function private.save_lead_call_notes(uuid,text,text) to authenticated;
grant execute on function public.save_lead_call_notes(uuid,text,text) to authenticated;
