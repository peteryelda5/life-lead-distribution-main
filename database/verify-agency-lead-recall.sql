-- Transactional fixtures only: every change is rolled back, including audits/receipts.
do $$
declare m uuid; agent uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid();
 l1 uuid; l2 uuid; l3 uuid; closed_id uuid; business_id uuid; outsider uuid; legacy_id uuid;
 batch text:='recall-test-'||gen_random_uuid(); req uuid:=gen_random_uuid();
 preview jsonb; payload jsonb; bad jsonb; n integer; denied boolean; actor uuid;
begin
 select id into m from public.profiles where is_super_admin and role='admin' and active and not coalesce(archived,false) limit 1;
 if m is null then raise exception 'No test Master available'; end if;
 begin
  perform set_config('request.jwt.claims','{}',true);
  insert into auth.users(id,email) values(agent,agent||'@example.invalid'),(admin_id,admin_id||'@example.invalid');
  insert into public.profiles(id,email,full_name,role,active,division)
  values(agent,agent||'@example.invalid','Recall Agent','agent',true,'vivid_life'),
   (admin_id,admin_id||'@example.invalid','Recall Admin','admin',true,'vivid_life')
  on conflict(id) do update set role=excluded.role,active=true,division='vivid_life',archived=false;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  insert into public.leads(first_name,division,lead_type,notes,call_notes,agent_status,csv_headers,csv_values)
  values('Pool','vivid_life',batch,'Original note','Call note','appointment_follow_up','["Phone"]','["2025550101"]') returning id into l1;
  insert into public.leads(first_name,division,lead_type,assigned_to,status,assigned_at)
  values('Agent','vivid_life',batch,agent,'assigned',now()) returning id into l2;
  insert into public.leads(first_name,division,lead_type,assigned_to,status,assigned_at)
  values('Admin','vivid_life',batch,admin_id,'assigned',now()) returning id into l3;
  insert into public.leads(first_name,division,lead_type,assigned_to,status)
  values('Closed','vivid_life',batch,agent,'closed') returning id into closed_id;
  insert into public.leads(first_name,division,lead_type,assigned_to,status)
  values('Business','vivid_life',batch,agent,'assigned') returning id into business_id;
  insert into public.leads(first_name,division,lead_type) values('Other agency','owner',batch) returning id into outsider;
  insert into public.leads(first_name,division,lead_type) values('Legacy recall','owner',batch) returning id into legacy_id;
  perform public.send_leads_to_division(array[legacy_id],'owner','legacy_life');
  reset role;
  insert into public.closed_business(lead_id,agent_id,carrier,policy_type,monthly_premium,application_date)
  values(business_id,agent,'Test carrier','Test policy',1,current_date);
  set local role authenticated;
  preview:=public.agency_recall_preview('vivid_life',batch,'all',100);
  if (preview->>'available')::int<>3 or jsonb_array_length(preview->'leads')<>3 then raise exception 'Preview failed to exclude closed business'; end if;
  if (public.agency_recall_preview('vivid_life',batch,'pool',100)->>'available')::int<>1 then raise exception 'Pool filter failed'; end if;
  if (public.agency_recall_preview('vivid_life',batch,'assigned',100)->>'available')::int<>2 then raise exception 'Assigned filter failed'; end if;
  if not exists(select 1 from jsonb_array_elements(public.agency_recall_options('vivid_life')) x where x->>'type'=batch and (x->>'count')::int=3) then raise exception 'Folder count wrong'; end if;
  select jsonb_agg(jsonb_build_object('id',x->>'id','updated_at',x->>'updated_at')) into payload from jsonb_array_elements(preview->'leads') x;
  bad:=jsonb_set(payload,'{0,updated_at}','"2000-01-01T00:00:00Z"');
  denied:=false;begin perform public.agency_recall_commit('vivid_life',bad,gen_random_uuid()); exception when serialization_failure then denied:=true;end;
  if not denied then raise exception 'Stale preview accepted';end if;
  bad:=payload||jsonb_build_array(jsonb_build_object('id',outsider,'updated_at',(select updated_at from public.leads where id=outsider)));
  denied:=false;begin perform public.agency_recall_commit('vivid_life',bad,gen_random_uuid()); exception when serialization_failure then denied:=true;end;
  if not denied then raise exception 'Wrong agency accepted';end if;
  bad:=payload||jsonb_build_array(jsonb_build_object('id',closed_id,'updated_at',(select updated_at from public.leads where id=closed_id)));
  denied:=false;begin perform public.agency_recall_commit('vivid_life',bad,gen_random_uuid()); exception when serialization_failure then denied:=true;end;
  if not denied then raise exception 'Closed lead accepted';end if;
  bad:=payload||jsonb_build_array(jsonb_build_object('id',business_id,'updated_at',(select updated_at from public.leads where id=business_id)));
  denied:=false;begin perform public.agency_recall_commit('vivid_life',bad,gen_random_uuid()); exception when serialization_failure then denied:=true;end;
  if not denied then raise exception 'Closed business accepted';end if;
  if (select count(*) from public.leads where id in(l1,l2,l3) and division='vivid_life')<>3 then raise exception 'Failed recall moved some leads';end if;
  n:=public.agency_recall_commit('vivid_life',payload,req);
  if n<>3 or (select count(*) from public.leads where id in(l1,l2,l3) and division='owner' and assigned_to is null and assigned_at is null and status='unassigned')<>3 then raise exception 'Recall incomplete';end if;
  if not exists(select 1 from public.leads where id=l1 and notes='Original note' and call_notes='Call note' and agent_status='appointment_follow_up' and lead_type=batch and csv_headers='["Phone"]'::jsonb and csv_values='["2025550101"]'::jsonb and uploaded_by=m and owner_admin_id=m) then raise exception 'Lead data or provenance lost';end if;
  if public.agency_recall_commit('vivid_life',payload,req)<>3 then raise exception 'Safe replay failed';end if;
  denied:=false;begin perform public.agency_recall_commit('vivid_life',jsonb_build_array(payload->0),req); exception when others then denied:=true;end;
  if not denied then raise exception 'Request reused for another set';end if;
  if (select count(*) from public.audit_logs where action='agency_leads_reclaimed' and entity_id=req::text)<>1 then raise exception 'Duplicate/missing recall audit';end if;
  if (select count(*) from public.lead_delivery_receipts where source_division='vivid_life' and destination_division='owner' and lead_ids @> array[l1] and lead_count=3)<>1 then raise exception 'Missing return receipt';end if;
  if not exists(select 1 from public.lead_history_events where lead_id=l2 and action='reclaimed') or not exists(select 1 from public.lead_history_events where lead_id=l2 and action='division_transfer') then raise exception 'Missing lead history';end if;
  if not exists(select 1 from jsonb_array_elements(public.agency_recall_agencies()) a where a->>'id'='legacy_life') then raise exception 'Legacy/archived agency missing from picker';end if;
  bad:=public.agency_recall_preview('legacy_life',batch,'all',1)->'leads';
  if jsonb_array_length(bad)<>1 or public.agency_recall_commit('legacy_life',bad,gen_random_uuid())<>1 then raise exception 'Master cannot recall Legacy leads';end if;
  if not exists(select 1 from public.leads where id=legacy_id and division='owner') then raise exception 'Legacy recall destination wrong';end if;
  denied:=false;begin perform public.agency_recall_preview('vivid_life',null,'all',1001);exception when others then denied:=true;end;
  if not denied then raise exception 'Unbounded recall accepted';end if;
  reset role;
  foreach actor in array array[agent,admin_id,m] loop
   perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','aal',case when actor=m then 'aal1' else 'aal2' end)::text,true);
   set local role authenticated;
   denied:=false;begin perform public.agency_recall_agencies();exception when insufficient_privilege then denied:=true;end;
   if not denied then raise exception 'Agency picker permission leak';end if;
   denied:=false;begin perform public.agency_recall_options('vivid_life');exception when insufficient_privilege then denied:=true;end;
   if not denied then raise exception 'Options permission leak';end if;
   denied:=false;begin perform public.agency_recall_preview('vivid_life',null,'all',10);exception when insufficient_privilege then denied:=true;end;
   if not denied then raise exception 'Preview permission leak';end if;
   denied:=false;begin perform public.agency_recall_commit('vivid_life',payload,req);exception when insufficient_privilege then denied:=true;end;
   if not denied then raise exception 'Commit permission leak';end if;
   if actor=agent and exists(select 1 from public.leads where id=l2) then raise exception 'Former agent can still read recalled lead';end if;
   if actor=admin_id and exists(select 1 from public.leads where id in(l1,l2,l3,legacy_id)) then raise exception 'Former agency admin can still read recalled leads';end if;
   reset role;
  end loop;
  raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id in(agent,admin_id)) or exists(select 1 from public.leads where lead_type=batch) or exists(select 1 from private.agency_lead_recalls where request_id=req) then raise exception 'Fixtures persisted';end if;
 if has_function_privilege('anon','public.agency_recall_commit(text,jsonb,uuid)','execute') or has_table_privilege('authenticated','private.agency_lead_recalls','select,insert,update,delete') then raise exception 'Private recall state exposed';end if;
end $$;
