-- Execute after the migration as the database administrator. All fixtures roll back.
-- No pre-existing user or lead is changed. Failures abort rather than persist fixtures.
do $$
declare leader uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid(); agent uuid:=gen_random_uuid();
 own_lead uuid; portable uuid; admin_lead uuid; other_lead uuid; closed_lead uuid; business_lead uuid;
 batch text:='own-return-test-'||gen_random_uuid(); req uuid:=gen_random_uuid(); admin_req uuid:=gen_random_uuid();
 payload jsonb; admin_payload jsonb; bad jsonb; candidate jsonb; rejected boolean; actor uuid; before_row jsonb;
begin
 begin
  perform set_config('request.jwt.claims','{}',true);
  insert into auth.users(id,email) values(leader,leader||'@example.invalid'),(admin_id,admin_id||'@example.invalid'),(agent,agent||'@example.invalid');
  insert into public.profiles(id,email,full_name,role,active,division,is_team_leader)
  values(leader,leader||'@example.invalid','Return Test Leader','agent',true,'vivid_life',true),
   (admin_id,admin_id||'@example.invalid','Return Test Admin','admin',true,'vivid_life',false),
   (agent,agent||'@example.invalid','Return Test Agent','agent',true,'vivid_life',false)
  on conflict(id) do update set role=excluded.role,active=true,archived=false,division=excluded.division,is_team_leader=excluded.is_team_leader;
  insert into public.leads(first_name,division,lead_type,assigned_to,status,assigned_at,notes,call_notes,agent_status,csv_headers,csv_values,uploaded_by,owner_admin_id,state,phone)
  values('Own','vivid_life',batch,leader,'assigned',now(),'Original note','Call note','appointment_follow_up','["Phone"]','["2025550101"]',admin_id,admin_id,'MI','2025550101') returning id,to_jsonb(leads) into own_lead,before_row;
  insert into public.leads(first_name,division,lead_type) values('Portable','owner',batch) returning id into portable;
  insert into private.agent_portable_leads(lead_id,agent_id,origin_division) values(portable,leader,'owner');
  update public.leads set assigned_to=leader,status='assigned',assigned_at=now() where id=portable;
  insert into public.leads(first_name,division,lead_type,assigned_to,status,assigned_at)
  values('Admin','vivid_life',batch,admin_id,'assigned',now()) returning id into admin_lead;
  insert into public.leads(first_name,division,lead_type,assigned_to,status)
  values('Other agent','vivid_life',batch,agent,'assigned') returning id into other_lead;
  insert into public.leads(first_name,division,lead_type,assigned_to,status)
  values('Closed','vivid_life',batch,leader,'closed') returning id into closed_lead;
  insert into public.leads(first_name,division,lead_type,assigned_to,status)
  values('Business','vivid_life',batch,leader,'assigned') returning id into business_lead;
  insert into public.closed_business(lead_id,agent_id,carrier,policy_type,monthly_premium,application_date)
  values(business_lead,leader,'Test carrier','Test policy',1,current_date);
  select jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at) order by id) into payload from public.leads where id in(own_lead,portable);
  select jsonb_build_array(jsonb_build_object('id',id,'updated_at',updated_at)) into admin_payload from public.leads where id=admin_lead;

  -- A regular agent cannot call the endpoint, even for their own lead.
  select jsonb_build_array(jsonb_build_object('id',id,'updated_at',updated_at)) into bad from public.leads where id=other_lead;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',agent,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  rejected:=false;begin perform public.return_my_leads_to_pool(bad,gen_random_uuid());exception when insufficient_privilege then rejected:=true;end;
  if not rejected then raise exception 'Regular agent accepted';end if;
  reset role;
  perform set_config('request.jwt.claims','{}',true);
  set local role authenticated;
  rejected:=false;begin perform public.return_my_leads_to_pool(payload,req);exception when insufficient_privilege then rejected:=true;end;
  if not rejected then raise exception 'Missing identity accepted';end if;
  reset role;

  -- Inactive/archived profiles, demoted leaders, and AAL1 sessions must fail.
  for actor in select unnest(array[leader,admin_id]) loop
   perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','aal','aal2')::text,true);
   update public.profiles set active=false where id=actor;
   set local role authenticated;
   rejected:=false;begin perform public.return_my_leads_to_pool(payload,req);exception when insufficient_privilege then rejected:=true;end;
   if not rejected then raise exception 'Inactive profile accepted';end if;
   reset role;
   update public.profiles set active=true,archived=true where id=actor;
   set local role authenticated;
   rejected:=false;begin perform public.return_my_leads_to_pool(payload,req);exception when insufficient_privilege then rejected:=true;end;
   if not rejected then raise exception 'Archived profile accepted';end if;
   reset role;
   update public.profiles set archived=false where id=actor;
   perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','aal','aal1')::text,true);
   set local role authenticated;
   rejected:=false;begin perform public.return_my_leads_to_pool(payload,req);exception when insufficient_privilege then rejected:=true;end;
   if not rejected then raise exception 'Unverified session accepted';end if;
   reset role;
  end loop;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',leader,'role','authenticated','aal','aal2','user_metadata',jsonb_build_object('is_team_leader',true))::text,true);
  update public.profiles set is_team_leader=false where id=leader;
  set local role authenticated;
  rejected:=false;begin perform public.return_my_leads_to_pool(payload,req);exception when insufficient_privilege then rejected:=true;end;
  if not rejected then raise exception 'Editable metadata authorized a demoted leader';end if;
  reset role;
  update public.profiles set is_team_leader=true where id=leader;

  -- Fail the entire batch for a foreign assignment, closed sale, or stale revision.
  for candidate in select jsonb_build_object('id',id,'updated_at',updated_at) from public.leads where id in(other_lead,closed_lead,business_lead) loop
   bad:=payload||jsonb_build_array(candidate);
   set local role authenticated;
   rejected:=false;begin perform public.return_my_leads_to_pool(bad,gen_random_uuid());exception when serialization_failure then rejected:=true;end;
   if not rejected then raise exception 'Foreign or closed lead accepted';end if;
   reset role;
  end loop;
  set local role authenticated;
  bad:=jsonb_set(payload,'{0,updated_at}','"2000-01-01T00:00:00Z"');
  rejected:=false;begin perform public.return_my_leads_to_pool(bad,req);exception when serialization_failure then rejected:=true;end;
  if not rejected then raise exception 'Stale preview accepted';end if;
  foreach bad in array array['[]'::jsonb,'{}'::jsonb,'null'::jsonb,payload||jsonb_build_array(payload->0),jsonb_build_array(jsonb_build_object('id',own_lead))] loop
   rejected:=false;begin perform public.return_my_leads_to_pool(bad,gen_random_uuid());exception when others then rejected:=true;end;
   if not rejected then raise exception 'Invalid selection accepted';end if;
  end loop;
  rejected:=false;begin perform public.return_my_leads_to_pool(payload,null);exception when others then rejected:=true;end;
  if not rejected then raise exception 'Missing request ID accepted';end if;
  reset role;
  if (select count(*) from public.leads where id in(own_lead,portable) and assigned_to=leader and status='assigned')<>2 then raise exception 'Rejected batch partially changed assignments';end if;
  if exists(select 1 from private.my_lead_pool_returns where request_id=req) then raise exception 'Rejected batch wrote a receipt';end if;

  set local role authenticated;
  if public.return_my_leads_to_pool(payload,req)<>2 then raise exception 'Leader return count wrong';end if;
  if public.return_my_leads_to_pool(payload,req)<>2 then raise exception 'Safe retry failed';end if;
  rejected:=false;begin perform public.return_my_leads_to_pool(jsonb_build_array(payload->0),req);exception when others then rejected:=true;end;
  if not rejected then raise exception 'Request reused for a different selection';end if;
  reset role;
  if (select count(*) from public.leads where id in(own_lead,portable) and assigned_to is null and assigned_at is null and status='unassigned')<>2 then raise exception 'Returned assignments not cleared';end if;
  if not exists(select 1 from public.leads where id=own_lead and division='vivid_life') or not exists(select 1 from public.leads where id=portable and division='owner') then raise exception 'Return changed agency ownership';end if;
  if (select to_jsonb(l)-array['assigned_to','assigned_at','status','updated_at'] from public.leads l where id=own_lead) is distinct from before_row-array['assigned_to','assigned_at','status','updated_at'] then raise exception 'Return changed lead information or provenance';end if;
  if exists(select 1 from private.agent_portable_leads where lead_id=portable) then raise exception 'Portable access grant remains';end if;
  if (select count(*) from public.audit_logs where action='own_leads_returned_to_pool' and entity_id=req::text)<>1 then raise exception 'Missing/duplicate audit';end if;
  if (select count(*) from public.lead_delivery_receipts where sender_id=leader and lead_ids && array[own_lead,portable] and recipient_id is null and source_division=destination_division and lead_count=1)<>2 then raise exception 'Missing/duplicate destination receipts';end if;
  if (select count(*) from public.lead_history_events where lead_id in(own_lead,portable) and action='reclaimed' and actor_id=leader)<>2 then raise exception 'Missing reclaim history';end if;
  if (select count(*) from public.leads where id in(other_lead,closed_lead,business_lead) and assigned_to is not null)<>3 then raise exception 'Protected assignment changed';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated','aal','aal2')::text,true);
  select admin_payload||jsonb_build_array(jsonb_build_object('id',id,'updated_at',updated_at)) into bad from public.leads where id=other_lead;
  set local role authenticated;
  rejected:=false;begin perform public.return_my_leads_to_pool(bad,gen_random_uuid());exception when serialization_failure then rejected:=true;end;
  if not rejected then raise exception 'Admin returned another user''s lead';end if;
  rejected:=false;begin perform public.return_my_leads_to_pool(payload,req);exception when others then rejected:=true;end;
  if not rejected then raise exception 'Another actor reused the request';end if;
  if public.return_my_leads_to_pool(admin_payload,admin_req)<>1 then raise exception 'Admin cannot return own lead';end if;
  reset role;
  if not exists(select 1 from public.leads where id=admin_lead and division='vivid_life' and assigned_to is null and status='unassigned') then raise exception 'Admin return incorrect';end if;
  raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id in(leader,admin_id,agent)) or exists(select 1 from public.leads where lead_type=batch) or exists(select 1 from private.my_lead_pool_returns where request_id in(req,admin_req)) then raise exception 'Fixtures persisted';end if;
 if has_function_privilege('anon','public.return_my_leads_to_pool(jsonb,uuid)','execute') or has_function_privilege('anon','private.return_my_leads_to_pool(jsonb,uuid)','execute') or has_table_privilege('authenticated','private.my_lead_pool_returns','select,insert,update,delete') then raise exception 'Return permissions exposed';end if;
end $$;
