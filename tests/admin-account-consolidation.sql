-- Run after consolidation calls inside a transaction, then ROLLBACK for rehearsal.
do $$
declare m record; sid uuid; doc jsonb; expected bigint; actual bigint; before_record jsonb; after_record jsonb;
begin
 for m in select * from private.admin_account_consolidations where completed_at>=transaction_timestamp() loop
  if exists(select 1 from public.profiles where id=m.source_id and (active or not archived)) then raise exception 'Duplicate login still enabled';end if;
  if exists(select 1 from private.book_crm_clients where agent_id=m.source_id) or exists(select 1 from public.closed_business where agent_id=m.source_id) then raise exception 'Source production remains';end if;
  for before_record in select value from jsonb_array_elements(m.before_state->'public.leads') loop
   select to_jsonb(l)-'assigned_to'-'updated_at' into after_record from public.leads l where id=(before_record->>'id')::uuid and assigned_to=m.target_id;
   if after_record is distinct from before_record-'assigned_to'-'updated_at' then raise exception 'Lead contents or origin changed';end if;
  end loop;
  for before_record in select value from jsonb_array_elements(m.before_state->'private.book_crm_clients') loop
   select to_jsonb(c)-'agent_id'-'updated_at' into after_record from private.book_crm_clients c where id=(before_record->>'id')::uuid and agent_id=m.target_id;
   if after_record is distinct from before_record-'agent_id'-'updated_at' then raise exception 'Policy contents changed';end if;
  end loop;
  select count(*) into expected from private.book_crm_clients where agent_id=m.target_id;
  sid:=gen_random_uuid();
  insert into private.book_unlocks(user_id,session_id,expires_at) values(m.target_id,sid::text,now()+interval '15 minutes');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',m.target_id,'role','authenticated','aal','aal2','session_id',sid)::text,true);
  perform set_config('role','authenticated',true);
  doc:=public.book_crm_workspace(p_agent=>m.target_id,p_limit=>2000);
  if jsonb_array_length(doc->'rows')<>expected then raise exception 'Admin personal book does not show combined policies';end if;
  select count(*) into actual from public.leads where id in(select (value->>'id')::uuid from jsonb_array_elements(m.before_state->'public.leads'));
  if actual<>(m.counts->>'leads')::bigint then raise exception 'Admin cannot read transferred personal leads';end if;
  perform public.my_lead_folders();
  perform set_config('role','postgres',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',m.source_id,'role','authenticated','aal','aal2','session_id',sid)::text,true);
  if private.verified_portal_session() or private.portal_onboarding_allowed(m.source_id) then raise exception 'Retired login still authorized';end if;
  delete from private.book_unlocks where user_id=m.target_id and session_id=sid::text;
 end loop;
 if has_function_privilege('authenticated','private.consolidate_admin_agent(uuid,uuid,uuid,text)','execute') or has_table_privilege('authenticated','private.admin_account_consolidations','select') then raise exception 'Maintenance data exposed';end if;
end $$;
