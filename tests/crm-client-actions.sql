-- Real public RPCs with synthetic policies. All mutations and events roll back.
begin;
do $$
declare a uuid; b uuid; owner_id uuid; sid uuid:=gen_random_uuid(); one uuid:=gen_random_uuid(); two uuid:=gen_random_uuid(); other uuid:=gen_random_uuid();
 r jsonb; d jsonb; versions jsonb; stale jsonb; contact_version timestamptz; state text; task_id uuid; manual_id uuid:=gen_random_uuid(); denied boolean;
 v_deal_id uuid; deal_before jsonb; price_before jsonb; production_before bigint; tasks_before bigint;
begin
 select p.id into a from public.profiles p join public.divisions ag on ag.id=p.division where p.active and p.role='agent' and not coalesce(p.archived,false) and not ag.archived and p.division='vivid_life' limit 1;
 select p.id into b from public.profiles p join public.divisions ag on ag.id=p.division where p.active and p.role='agent' and not coalesce(p.archived,false) and not ag.archived and p.id<>a limit 1;
 select id into owner_id from public.profiles where active and is_super_admin limit 1;
 if a is null or b is null or owner_id is null then raise exception 'Active test roles missing';end if;
 insert into private.book_unlocks values(a,sid::text,now()+interval '15 minutes'),(b,sid::text,now()+interval '15 minutes'),(owner_id,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 perform public.book_crm_save_v2(one,jsonb_build_object('agent_id',a,'client_name','__CLIENT_ACTIONS_TEST__','phone','2025550111','carrier','Ethos','policy_type','Term','monthly_payment',100,'application_date',current_date,'effective_date',current_date,'pipeline_stage','in_force'));
 perform public.book_crm_policy_save(one,two,jsonb_build_object('carrier','Aetna','policy_type','Final Expense','monthly_payment',50,'application_date',current_date,'effective_date',current_date,'pipeline_stage','submitted'));
 perform public.book_crm_save_v2(other,jsonb_build_object('agent_id',a,'client_name','__CLIENT_ACTIONS_KEEP__','phone','2025550112','carrier','Aflac','policy_type','FEX','monthly_payment',50,'application_date',current_date,'effective_date',current_date,'pipeline_stage','submitted'));
 r:=public.book_crm_profile_detail(one)->'client';v_deal_id:=(r->>'deal_id')::uuid;
 select to_jsonb(c) into deal_before from public.closed_business c where id=v_deal_id;
 select to_jsonb(c) into price_before from private.book_deal_comp c where c.deal_id=v_deal_id;
 select count(*) into production_before from public.closed_business;
 if exists(select 1 from private.book_crm_tasks where client_id in(one,two)) then raise exception 'Unverified policy created a task';end if;
 -- Owner-entered carrier statuses must create tasks under the policy's agent.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'aal','aal2','session_id',sid)::text,true);
 foreach state in array array['initial_premium_failed','grace_period','late_offer_period','lapsed','cancelled','declined'] loop
  r:=public.book_crm_profile_detail(one)->'client';
  perform public.book_crm_carrier_status_save(one,state,'carrier_portal',current_date,'Test reference','',(r->>'updated_at')::timestamptz,r->'deal_version');
  if (select count(*) from private.book_crm_tasks where client_id=one and source='carrier_status')<>1 then raise exception 'Duplicate or missing carrier task for %',state;end if;
  if not exists(select 1 from private.book_crm_tasks where client_id=one and source='carrier_status' and priority='high' and carrier_status=state and completed_at is null) then raise exception 'Missing urgent open task for %',state;end if;
  if exists(select 1 from private.book_crm_tasks where client_id=two) then raise exception 'Sibling policy task leaked';end if;
 end loop;
 select id into task_id from private.book_crm_tasks where client_id=one and source='carrier_status';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 perform public.book_crm_action(one,'task',manual_id,'Earlier manual follow-up',now()-interval '1 day');
 d:=public.book_crm_workspace(1,'__CLIENT_ACTIONS_TEST__',a,'',50,'tasks','open');
 if d->'tasks'->0->>'id'<>task_id::text or d->'tasks'->0->>'priority'<>'high' or d->'tasks'->0->>'carrier'<>'Ethos' then raise exception 'Agent task ordering, assignment or policy link missing';end if;
 if (d->>'task_count')::int<>2 then raise exception 'Unexpected agent task count';end if;
 d:=public.book_crm_profile_detail(one);if not (d->>'can_delete_profile')::boolean or d->'tasks'->0->>'id'<>task_id::text then raise exception 'Profile capability or urgent ordering missing';end if;
 d:=public.book_crm_pipeline('__CLIENT_ACTIONS_TEST__',a,'','',1,50,'board',now()-interval '1 hour',now()+interval '1 hour');
 if d->'today_tasks'->0->>'id'<>task_id::text then raise exception 'Pipeline follow-up missing';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'aal','aal2','session_id',sid)::text,true);
 d:=public.book_crm_workspace(1,'__CLIENT_ACTIONS_TEST__',null,'',50,'tasks','open');if (d->>'task_count')::int<>0 then raise exception 'Foreign agent sees tasks';end if;
 denied:=false;begin perform public.book_crm_profile_delete(one,now(),'[]');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign agent deleted client';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 r:=public.book_crm_profile_detail(one)->'client';
 perform public.book_crm_carrier_status_save(one,'in_force','carrier_email',current_date,'Resolved reference','',(r->>'updated_at')::timestamptz,r->'deal_version');
 if not exists(select 1 from private.book_crm_tasks where id=task_id and completed_at is not null) then raise exception 'Healthy status did not resolve automated task';end if;
 if exists(select 1 from private.book_crm_tasks where id=manual_id and completed_at is not null) then raise exception 'Manual follow-up was changed';end if;
 r:=public.book_crm_profile_detail(one)->'client';
 perform public.book_crm_carrier_status_save(one,'lapsed','carrier_email',current_date,'New issue','',(r->>'updated_at')::timestamptz,r->'deal_version');
 if not exists(select 1 from private.book_crm_tasks where id=task_id and completed_at is null and carrier_status='lapsed') then raise exception 'New issue did not reopen existing task';end if;
 perform public.book_crm_action(one,'complete',task_id,'',null,'',(select updated_at from private.book_crm_tasks where id=task_id));
 r:=public.book_crm_profile_detail(one)->'client';
 perform public.book_crm_carrier_status_save(one,'lapsed','carrier_email',current_date,'Same issue','',(r->>'updated_at')::timestamptz,r->'deal_version');
 if not exists(select 1 from private.book_crm_tasks where id=task_id and completed_at is not null) then raise exception 'Repeat status reopened a manually completed task';end if;
 -- Independent policy issue; one per policy, never one per profile or recording actor.
 r:=public.book_crm_profile_detail(two)->'client';
 perform public.book_crm_carrier_status_save(two,'grace_period','carrier_portal',current_date,'Second policy','',(r->>'updated_at')::timestamptz,r->'deal_version');
 if (select count(*) from private.book_crm_tasks where client_id in(one,two) and source='carrier_status')<>2 then raise exception 'Per-policy task identity failed';end if;
 -- Confirming a carrier status never edits production.
 if (select to_jsonb(c) from public.closed_business c where id=v_deal_id) is distinct from deal_before then raise exception 'Carrier task changed production';end if;
 -- A stale modal may not delete a newly edited policy or a changed linked deal.
 d:=public.book_crm_profile_detail(one);contact_version:=(d->'profile'->>'updated_at')::timestamptz;
 select jsonb_agg(jsonb_build_object('id',x->>'id','updated_at',x->>'updated_at','deal_version',x->'deal_version')) into versions from jsonb_array_elements(d->'policies')x;
 stale:=versions;r:=public.book_crm_profile_detail(two)->'client';
 perform public.book_crm_policy_save(one,two,'{"notes":"Edited after confirmation opened"}',(r->>'updated_at')::timestamptz,r->'deal_version');
 denied:=false;begin perform public.book_crm_profile_delete(one,contact_version,stale);exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale policy deletion accepted';end if;
 d:=public.book_crm_profile_detail(one);contact_version:=(d->'profile'->>'updated_at')::timestamptz;
 select jsonb_agg(jsonb_build_object('id',x->>'id','updated_at',x->>'updated_at','deal_version',x->'deal_version')) into versions from jsonb_array_elements(d->'policies')x;
 update public.closed_business set notes='External deal edit' where id=v_deal_id;
 denied:=false;begin perform public.book_crm_profile_delete(one,contact_version,versions);exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale linked deal deletion accepted';end if;
 d:=public.book_crm_profile_detail(one);
 select jsonb_agg(jsonb_build_object('id',x->>'id','updated_at',x->>'updated_at','deal_version',x->'deal_version')) into versions from jsonb_array_elements(d->'policies')x;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal1','session_id',sid)::text,true);
 denied:=false;begin perform public.book_crm_profile_delete(one,contact_version,versions);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'MFA bypass';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',gen_random_uuid())::text,true);
 denied:=false;begin perform public.book_crm_profile_delete(one,contact_version,versions);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'PIN bypass';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 select to_jsonb(c) into deal_before from public.closed_business c where id=v_deal_id;
 perform public.book_crm_profile_delete(one,contact_version,versions);
 if exists(select 1 from private.book_crm_clients where id in(one,two)) or exists(select 1 from private.book_crm_profiles where id=one) or exists(select 1 from private.book_crm_tasks where client_id in(one,two)) then raise exception 'Client or children were not removed';end if;
 if not exists(select 1 from private.book_crm_clients where id=other) then raise exception 'Unrelated client deleted';end if;
 if (public.book_crm_profiles_list(1,'__CLIENT_ACTIONS_TEST__')->>'count')::int<>0 or (public.book_crm_workspace(1,'__CLIENT_ACTIONS_TEST__',a,'',50,'tasks','open')->>'task_count')::int<>0 then raise exception 'Deleted client or tasks still visible';end if;
 if (select to_jsonb(c) from public.closed_business c where id=v_deal_id) is distinct from deal_before or (select count(*) from public.closed_business)<>production_before or (select to_jsonb(c) from private.book_deal_comp c where c.deal_id=v_deal_id) is distinct from price_before then raise exception 'Deletion changed recorded financial data';end if;
 if not exists(select 1 from public.audit_logs where action='crm_client_deleted' and entity_id=one::text and jsonb_array_length(details->'before'->'policies')=2 and jsonb_array_length(details->'before'->'tasks')=3) then raise exception 'Deletion audit snapshot missing';end if;
 if has_function_privilege('anon','public.book_crm_profile_delete(uuid,timestamptz,jsonb)','execute') or has_function_privilege('authenticated','private.book_crm_sync_carrier_task(uuid,text,uuid,boolean)','execute') or has_table_privilege('authenticated','private.book_crm_tasks','update') then raise exception 'Direct write permissions exposed';end if;
end;$$;
select 'PASS: all six carrier problems, agent assignment, urgent ordering, repeat protection, resolution/reopening, independent policies, deletion/version checks, audit snapshot, preserved production and PIN/MFA/scope gates; rolled back' result;
rollback;
