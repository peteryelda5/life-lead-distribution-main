-- Execute inside BEGIN / ROLLBACK. Every lead/account below is synthetic.
do $test$
declare master uuid; session uuid; agent uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid();
 folder text:='Whole-folder fixture '||gen_random_uuid(); other_folder text:='Other fixture '||gen_random_uuid();
 profile_id uuid:=gen_random_uuid(); policy_id uuid:=gen_random_uuid(); deal_id uuid:=gen_random_uuid(); protected_lead uuid:=gen_random_uuid(); closed_lead uuid:=gen_random_uuid();
 changed uuid; newly_closed uuid; later_lead uuid:=gen_random_uuid(); other_lead uuid:=gen_random_uuid(); foreign_lead uuid:=gen_random_uuid();
 fixture_uploader uuid; before_leads jsonb; before_client jsonb; before_deal jsonb; before_agent jsonb; result jsonb; job jsonb; job_id uuid; first_result jsonb; expired_id uuid; stopped_id uuid; denied boolean;
begin
 select p.id,s.id into master,session from public.profiles p join auth.sessions s on s.user_id=p.id
 where p.is_super_admin and p.role='admin' and p.active and not p.archived and (s.not_after is null or s.not_after>now()) limit 1;
 if master is null then raise exception 'A live Master session is required for this rollback-only test';end if;
 perform set_config('request.jwt.claims','{}',true);
 insert into auth.users(id,email) values(agent,agent||'@example.invalid'),(admin_id,admin_id||'@example.invalid');
 insert into public.profiles(id,full_name,role,active,division) values(agent,'Synthetic recall agent','agent',true,'vivid_life'),(admin_id,'Synthetic recall admin','admin',true,'vivid_life');
 insert into auth.sessions(id,user_id,aal,created_at) values(agent,agent,'aal2',now()),(admin_id,admin_id,'aal2',now());
 insert into private.portal_onboarding_waivers(user_id,reason,granted_by) values(agent,'Rollback-only fixture',master);
 insert into public.leads(first_name,last_name,division,lead_type,state,assigned_to,status,updated_at,notes,call_notes,agent_status,owner_admin_id,uploaded_by,csv_headers,csv_values)
 select 'Synthetic',i::text,'vivid_life',folder,case when i%2=0 then 'OH' else ' mi ' end,
 case when i%2=0 then agent else null end,case when i%2=0 then 'assigned'::public.lead_status else 'unassigned'::public.lead_status end,
 now()-interval '1 day','Original note','Keep call notes','appointment_follow_up',master,master,'["Example"]','["Synthetic"]'
 from generate_series(1,1003) i;
 select id into changed from public.leads where lead_type=folder and last_name='1';
 select uploaded_by into fixture_uploader from public.leads where id=changed;
 select id into newly_closed from public.leads where lead_type=folder and last_name='2';
 insert into public.leads(id,first_name,division,lead_type,state,status,assigned_to) values
 (closed_lead,'Synthetic closed','vivid_life',folder,'MI','closed',agent),
 (protected_lead,'Synthetic deal','vivid_life',folder,'MI','assigned',agent),
 (other_lead,'Synthetic other folder','vivid_life',other_folder,'MI','unassigned',null),
 (foreign_lead,'Synthetic other agency','legacy_life',folder,'MI','unassigned',null);
 insert into private.book_crm_profiles(id,agent_id,details) values(profile_id,agent,'{"client_name":"Synthetic client"}');
 insert into private.book_crm_clients(id,profile_id,agent_id,client_name,phone,carrier,policy_type,monthly_payment)
 values(policy_id,profile_id,agent,'Synthetic client','2025550101','Fixture carrier','term',100);
 perform set_config('lld.crm_client_id',policy_id::text,true);
 insert into public.closed_business(id,agent_id,lead_id,carrier,policy_type,monthly_premium,application_date) values(deal_id,agent,protected_lead,'Fixture carrier','term',100,current_date);
 perform set_config('lld.crm_client_id','',true);
 select jsonb_agg(to_jsonb(l) order by id) into before_leads from public.leads l where id=any(array[closed_lead,protected_lead,other_lead,foreign_lead]);
 select to_jsonb(c) into before_client from private.book_crm_clients c where id=policy_id;
 select to_jsonb(d) into before_deal from public.closed_business d where id=deal_id;
 select to_jsonb(p) into before_agent from public.profiles p where id=agent;
 if has_function_privilege('anon','public.agency_recall_bulk_prepare(text,text,text,text[],text)','execute')
 or has_function_privilege('anon','private.agency_recall_bulk_step(text,uuid,integer)','execute')
 or has_table_privilege('authenticated','private.agency_recall_jobs','select,insert,update,delete')
 or has_table_privilege('authenticated','private.agency_recall_items','select,insert,update,delete') then raise exception 'Recall snapshots exposed';end if;
 set local role authenticated;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'session_id',admin_id,'role','authenticated','aal','aal2')::text,true);
 denied:=false;begin perform public.agency_recall_bulk_prepare('vivid_life',folder,'all',null,'folder');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Scoped admin prepared a recall';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',master,'session_id',session,'role','authenticated','aal','aal1')::text,true);
 denied:=false;begin perform public.agency_recall_bulk_status('vivid_life');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Password-only recall admitted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',master,'session_id',session,'role','authenticated','aal','aal2')::text,true);
 denied:=false;begin perform public.agency_recall_bulk_prepare('vivid_life',null,'all',null,'folder');exception when raise_exception then denied:=true;end;if not denied then raise exception 'Whole folder accepted all folders';end if;
 denied:=false;begin perform public.agency_recall_bulk_prepare('vivid_life',folder,'all',array['MI'],'folder');exception when raise_exception then denied:=true;end;if not denied then raise exception 'Whole folder accepted partial states';end if;
 result:=public.agency_recall_bulk_prepare('vivid_life',folder,'all','{}','matching');if (result->>'total')::int<>0 then raise exception 'Empty states broadened';end if;
 result:=public.agency_recall_bulk_prepare('vivid_life',folder,'pool',array[' mi '],'matching');
 if (result->>'total')::int<>502 or (result->>'assigned')::int<>0 or result->'states'<>'["MI"]' then raise exception 'State/pool filtering incorrect';end if;
 job:=public.agency_recall_bulk_prepare('vivid_life',folder,'all',null,'folder');job_id:=(job->>'id')::uuid;
 if (job->>'total')::int<>1003 or (job->>'assigned')::int<>501 or jsonb_array_length(job->'summary')<>2 then raise exception 'Whole folder truncated or counts incorrect';end if;
 if exists(select 1 from public.leads where lead_type=folder and division='owner') then raise exception 'Preview moved leads';end if;
 denied:=false;begin perform public.agency_recall_bulk_step('legacy_life',job_id,0);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Job moved through wrong agency';end if;
 denied:=false;begin perform public.agency_recall_bulk_step('vivid_life',job_id,1000);exception when raise_exception then denied:=true;end;if not denied then raise exception 'Future offset accepted';end if;
 reset role;
 update public.leads set notes='Changed after preview' where id=changed;
 update public.leads set status='closed' where id=newly_closed;
 insert into public.leads(id,first_name,division,lead_type,state) values(later_lead,'Synthetic later upload','vivid_life',folder,'MI');
 set local role authenticated;
 first_result:=public.agency_recall_bulk_step('vivid_life',job_id,0);
 if (first_result->>'processed')::int<>1000 or first_result->>'finished_at' is not null then raise exception 'Step bound incorrect';end if;
 if public.agency_recall_bulk_step('vivid_life',job_id,0) is distinct from first_result then raise exception 'Retry repeated a step';end if;
 if public.agency_recall_bulk_status('vivid_life')->>'id'<>job_id::text then raise exception 'Pending recall cannot resume';end if;
 denied:=false;begin perform public.agency_recall_bulk_prepare('vivid_life',folder,'all',null,'folder');exception when raise_exception then denied:=sqlerrm like '%Resume or stop%';end;if not denied then raise exception 'Overlapping whole-folder recall accepted';end if;
 result:=public.agency_recall_bulk_step('vivid_life',job_id,1000);
 if (result->>'processed')::int<>1003 or (result->>'returned')::int<>1001 or (result->>'skipped')::int<>2 or result->>'finished_at' is null then raise exception 'Whole-folder result incorrect';end if;
 if public.agency_recall_bulk_step('vivid_life',job_id,0) is distinct from result then raise exception 'Completed replay changed result';end if;
 reset role;
 if (select count(*) from public.leads where lead_type=folder and division='owner' and status='unassigned' and assigned_to is null and notes='Original note' and call_notes='Keep call notes' and agent_status='appointment_follow_up' and owner_admin_id=master and uploaded_by is not distinct from fixture_uploader and csv_values='["Synthetic"]'::jsonb)<>1001 then raise exception 'Recall lost content or assignments remain';end if;
 if not exists(select 1 from public.leads where id=changed and division='vivid_life' and notes='Changed after preview') or not exists(select 1 from public.leads where id=newly_closed and division='vivid_life' and status='closed' and assigned_to=agent) or not exists(select 1 from public.leads where id=later_lead and division='vivid_life') then raise exception 'Changed/new/closed leads moved';end if;
 if before_leads is distinct from (select jsonb_agg(to_jsonb(l) order by id) from public.leads l where id=any(array[closed_lead,protected_lead,other_lead,foreign_lead]))
 or before_client is distinct from (select to_jsonb(c) from private.book_crm_clients c where id=policy_id)
 or before_deal is distinct from (select to_jsonb(d) from public.closed_business d where id=deal_id)
 or before_agent is distinct from (select to_jsonb(p) from public.profiles p where id=agent) then raise exception 'Unrelated records/deals/clients/account changed';end if;
 if (select count(*) from public.audit_logs where action='agency_bulk_recall_completed' and entity_id=job_id::text)<>1 then raise exception 'Duplicate or missing completion audit';end if;
 set local role authenticated;
 result:=public.agency_recall_bulk_prepare('vivid_life',other_folder,'all',null,'folder');stopped_id:=(result->>'id')::uuid;
 perform public.agency_recall_bulk_stop('vivid_life',stopped_id);
 denied:=false;begin perform public.agency_recall_bulk_step('vivid_life',stopped_id,0);exception when raise_exception then denied:=true;end;if not denied then raise exception 'Stopped job proceeded';end if;
 result:=public.agency_recall_bulk_prepare('vivid_life',other_folder,'all',null,'folder');expired_id:=(result->>'id')::uuid;
 reset role;update private.agency_recall_jobs set expires_at=now()-interval '1 second' where id=expired_id;set local role authenticated;
 denied:=false;begin perform public.agency_recall_bulk_step('vivid_life',expired_id,0);exception when serialization_failure then denied:=true;end;if not denied then raise exception 'Expired preview proceeded';end if;
 denied:=false;begin perform public.agency_recall_bulk_prepare('vivid_life',other_folder,'all',null,'folder');exception when raise_exception then denied:=sqlerrm like '%wait a minute%';end;if not denied then raise exception 'Preview rate bound missing';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',agent,'session_id',agent,'role','authenticated','aal','aal2')::text,true);
 denied:=false;begin perform public.agency_recall_bulk_step('vivid_life',job_id,0);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Agent can execute/replay recall';end if;
 if exists(select 1 from public.leads where lead_type=folder and division='owner') then raise exception 'Former agent still sees recalled leads';end if;
 reset role;
end $test$;
select 'PASS: 1,003-lead whole folder, state/scope filters, exact snapshot, 1K steps, safe retry/resume, changed/closed skips, source isolation, preserved records, access checks, stop/expiry/rate bounds' as result;
