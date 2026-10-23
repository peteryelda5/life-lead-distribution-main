-- Full lead-to-CRM simulation through real RPCs, using fictional data and rates.
-- Run in the recovery project. The entire transaction, including events, rolls back.
begin;
do $$
declare
 v_owner_id uuid; v_agent_id uuid; v_other_agent uuid; sid uuid:=gen_random_uuid(); v_lead_id uuid:=gen_random_uuid();
 v_deal_id uuid; v_policy_id uuid; v_task_id uuid; r jsonb; d jsonb; deal_before jsonb; production_before bigint;
begin
 select id into v_owner_id from public.profiles where active and is_super_admin limit 1;
 select p.id into v_agent_id from public.profiles p join public.divisions a on a.id=p.division
 where p.active and p.role='agent' and not coalesce(p.archived,false) and not a.archived and p.division='vivid_life' limit 1;
 select p.id into v_other_agent from public.profiles p join public.divisions a on a.id=p.division
 where p.active and p.role='agent' and not coalesce(p.archived,false) and not a.archived and p.id<>v_agent_id limit 1;
 if v_owner_id is null or v_agent_id is null or v_other_agent is null then raise exception 'Test roles missing';end if;
 insert into private.book_unlocks values(v_owner_id,sid::text,now()+interval '15 minutes'),(v_agent_id,sid::text,now()+interval '15 minutes'),(v_other_agent,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner_id,'aal','aal2','session_id',sid)::text,true);
 perform public.book_grid('save',v_agent_id,'Aetna','Final Expense',80,75,current_date);
 insert into public.leads(id,first_name,last_name,phone,email,state,division,assigned_to,status)
 values(v_lead_id,'__FLOW_DEMO__','Alex Morgan','2025550142','alex@example.invalid','MI','vivid_life',v_agent_id,'assigned');
 select count(*) into production_before from public.closed_business;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_agent_id,'aal','aal2','session_id',sid)::text,true);
 v_deal_id:=public.close_lead(v_lead_id,'Aetna','Final Expense',100,current_date,'DEMO-1023','Synthetic workflow verification');
 if (select status from public.leads where id=v_lead_id)<>'closed' then raise exception 'Lead stayed open';end if;
 if (select count(*) from public.closed_business)<>production_before+1 then raise exception 'Closing did not record exactly one deal';end if;
 select id into v_policy_id from private.book_crm_clients c where c.deal_id=v_deal_id;
 if v_policy_id is null then raise exception 'Closing did not create CRM policy';end if;
 r:=public.book_crm_profile_detail(v_policy_id)->'client';
 if r->>'client_name'<>'__FLOW_DEMO__ Alex Morgan' or r->>'pipeline_stage'<>'approved' or r->>'carrier_status'<>'unverified' then raise exception 'New CRM client or initial statuses incorrect: %',r;end if;
 if (r->>'comp_percent')::numeric is distinct from 80::numeric or (r->>'advance_percent')::numeric is distinct from 75::numeric or (r->>'estimated_advance')::numeric is distinct from 720::numeric then raise exception 'Matching grid did not produce the expected estimate';end if;
 if exists(select 1 from private.book_crm_tasks where client_id=v_policy_id) then raise exception 'Unverified closing created an urgent carrier task';end if;
 perform public.book_crm_save_v2(v_policy_id,jsonb_build_object('pipeline_stage','in_force','effective_date',current_date),(r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(v_policy_id)->'client';
 if r->>'pipeline_stage'<>'in_force' or r->>'carrier_status'<>'unverified' then raise exception 'Agent stage changed carrier confirmation';end if;
 select to_jsonb(c) into deal_before from public.closed_business c where c.id=v_deal_id;
 -- The owner records the carrier evidence; the policy's agent receives the task.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner_id,'aal','aal2','session_id',sid)::text,true);
 perform public.book_crm_carrier_status_save(v_policy_id,'initial_premium_failed','carrier_portal',current_date,'DEMO-1023','Synthetic carrier evidence',(r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(v_policy_id)->'client';
 if r->>'pipeline_stage'<>'in_force' or r->>'carrier_status'<>'initial_premium_failed' or (r->>'estimated_advance')::numeric is distinct from 720::numeric then raise exception 'Carrier status incorrectly changed agent stage or estimate';end if;
 select id into v_task_id from private.book_crm_tasks where client_id=v_policy_id and source='carrier_status' and priority='high' and completed_at is null;
 if v_task_id is null then raise exception 'Failed premium did not create urgent task';end if;
 perform public.book_crm_carrier_status_save(v_policy_id,'initial_premium_failed','carrier_portal',current_date,'DEMO-1023','Same evidence',(r->>'updated_at')::timestamptz,r->'deal_version');
 if (select count(*) from private.book_crm_tasks where client_id=v_policy_id and source='carrier_status')<>1 then raise exception 'Repeated evidence duplicated task';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_agent_id,'aal','aal2','session_id',sid)::text,true);
 d:=public.book_crm_workspace(1,'__FLOW_DEMO__',v_agent_id,'',50,'tasks','open');
 if (d->>'task_count')::int<>1 or d->'tasks'->0->>'id'<>v_task_id::text or d->'tasks'->0->>'client_id'<>v_policy_id::text or d->'tasks'->0->>'priority'<>'high' then raise exception 'Assigned agent task or client link missing';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other_agent,'aal','aal2','session_id',sid)::text,true);
 if (public.book_crm_workspace(1,'__FLOW_DEMO__',null,'',50,'tasks','open')->>'task_count')::int<>0 then raise exception 'Task leaked to unrelated agent';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner_id,'aal','aal2','session_id',sid)::text,true);
 r:=public.book_crm_profile_detail(v_policy_id)->'client';
 perform public.book_crm_carrier_status_save(v_policy_id,'in_force','carrier_portal',current_date,'DEMO-1023-RESOLVED','Synthetic recovery evidence',(r->>'updated_at')::timestamptz,r->'deal_version');
 if not exists(select 1 from private.book_crm_tasks where id=v_task_id and completed_at is not null) then raise exception 'Resolved carrier status did not complete task';end if;
 if (select to_jsonb(c) from public.closed_business c where c.id=v_deal_id) is distinct from deal_before or (select count(*) from public.closed_business)<>production_before+1 then raise exception 'Carrier updates changed production';end if;
end;$$;
select 'PASS: lead closed, CRM client created in Approved, carrier Unverified, 80% comp / 75% advance / $720 estimate, separate In force stage, failed-premium task for assigned agent only, no duplicate task, resolved status completes task, production preserved; all simulation data rolled back' result;
rollback;
