-- Real RPC validation. All test records, audit and production events roll back.
begin;
do $$
declare a uuid; b uuid; owner uuid; sid uuid:=gen_random_uuid(); one uuid:=gen_random_uuid(); two uuid:=gen_random_uuid();
 r jsonb; before_row jsonb; version timestamptz; denied boolean; before_deals bigint;
begin
 select p.id into a from public.profiles p join public.divisions d on d.id=p.division where p.role='agent' and p.active and not coalesce(p.archived,false) and not d.archived and p.division='vivid_life' limit 1;
 select p.id into b from public.profiles p join public.divisions d on d.id=p.division where p.role='agent' and p.active and not coalesce(p.archived,false) and not d.archived and p.id<>a limit 1;
 select id into owner from public.profiles where is_super_admin and active limit 1;
 if a is null or b is null or owner is null then raise exception 'Test requires active roles';end if;
 insert into private.book_unlocks values(a,sid::text,now()+interval '15 minutes'),(b,sid::text,now()+interval '15 minutes'),(owner,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 select count(*) into before_deals from public.closed_business where agent_id=a;
 perform public.book_crm_save_v2(one,jsonb_build_object('agent_id',a,'client_name','__CARRIER_STATUS_TEST__','phone','2025550111','carrier','Ethos','policy_type','Term','monthly_payment',100,'application_date',current_date-10,'effective_date',current_date-5,'pipeline_stage','approved','policy_number','E-TEST'));
 perform public.book_crm_policy_save(one,two,jsonb_build_object('carrier','Aetna','policy_type','Final Expense','monthly_payment',50,'application_date',current_date-9,'effective_date',current_date-4,'pipeline_stage','submitted','policy_number','A-TEST'));
 r:=public.book_crm_profile_detail(one)->'client';before_row:=r;version:=(r->>'updated_at')::timestamptz;
 if r->>'carrier_status'<>'unverified' or (r->>'carrier_status_current')::boolean then raise exception 'Agent stage inferred carrier confirmation';end if;
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'in_force',null,current_date,'Ref','',version);exception when raise_exception then denied:=true;end;if not denied then raise exception 'Missing evidence accepted';end if;
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'in_force','carrier_portal',current_date+1,'Ref','',version);exception when raise_exception then denied:=true;end;if not denied then raise exception 'Future confirmation accepted';end if;
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'in_force','carrier_portal',current_date,' ','',version);exception when raise_exception then denied:=true;end;if not denied then raise exception 'Blank reference accepted';end if;
 perform public.book_crm_carrier_status_save(one,'in_force','carrier_portal',current_date,'Portal reference TEST-1','Evidence verified in test',version);
 r:=public.book_crm_profile_detail(one)->'client';
 if r->>'carrier_status'<>'in_force' or not (r->>'carrier_status_current')::boolean or r->>'carrier_status_recorded_by'<>a::text or r->>'carrier_confirmed_on'<>current_date::text then raise exception 'Carrier confirmation/provenance not returned';end if;
 if r->>'pipeline_stage'<>before_row->>'pipeline_stage' or r->>'status'<>before_row->>'status' or r->'deal_id' is distinct from before_row->'deal_id' or r->>'monthly_payment'<>before_row->>'monthly_payment' then raise exception 'Carrier status changed agent production or policy';end if;
 if (select count(*) from public.closed_business where agent_id=a)<>before_deals then raise exception 'Carrier confirmation created production';end if;
 if public.book_crm_profile_detail(two)->'client'->>'carrier_status'<>'unverified' then raise exception 'Sibling policy confirmation changed';end if;
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'lapsed','carrier_email',current_date,'Stale','',version);exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale carrier update accepted';end if;
 perform public.book_crm_save_v2(one,'{"pipeline_stage":"contacted"}',(r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';if r->>'pipeline_stage'<>'contacted' or r->>'carrier_status'<>'in_force' or not (r->>'carrier_status_current')::boolean then raise exception 'Agent move changed carrier status';end if;
 -- Pipeline still creates the agent-reported production record exactly once.
 perform public.book_crm_save_v2(one,'{"pipeline_stage":"in_force"}',(r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';if r->>'carrier_status'<>'in_force' or (select count(*) from public.closed_business where agent_id=a)<>before_deals+1 then raise exception 'Legacy accounting changed';end if;
 -- An external Closed Business edit may not update the CRM row version.
 update public.closed_business set notes=coalesce(notes,'')||' changed externally' where id=(r->>'deal_id')::uuid;
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'lapsed','carrier_statement',current_date,'Stale deal','',(r->>'updated_at')::timestamptz,r->'deal_version');exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale linked-deal confirmation accepted';end if;
 r:=public.book_crm_profile_detail(one)->'client';
 perform public.book_crm_carrier_status_save(one,'lapsed','carrier_statement',current_date,'Statement TEST-2','', (r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';if r->>'pipeline_stage'<>'in_force' or r->>'carrier_status'<>'lapsed' then raise exception 'Carrier lapse moved agent stage';end if;
 -- Both policy APIs and legacy production updates must not overwrite confirmation.
 perform public.book_crm_policy_save(one,one,'{"policy_number":"E-CHANGED"}',(r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';if (r->>'carrier_status_current')::boolean or r->>'carrier_status'<>'lapsed' or r->>'carrier_status_policy_number'<>'E-TEST' then raise exception 'Changed policy identity retained valid confirmation';end if;
 perform public.book_crm_carrier_status_save(one,'issued','carrier_email',current_date,'Email TEST-3','', (r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';if not (r->>'carrier_status_current')::boolean or r->>'carrier_status_policy_number'<>'E-CHANGED' then raise exception 'Recheck did not bind new identity';end if;
 if not exists(select 1 from jsonb_array_elements(public.book_crm_profiles_list(1,'__CARRIER_STATUS_TEST__')->'rows'->0->'policies')x where x->>'id'=one::text and x->>'carrier_status'='issued') then raise exception 'Grouped list missing status';end if;
 if not exists(select 1 from jsonb_array_elements(public.book_crm_pipeline('__CARRIER_STATUS_TEST__')->'pipeline')x where x->>'id'=one::text and x->>'carrier_status'='issued') then raise exception 'Pipeline missing status';end if;
 if not exists(select 1 from jsonb_array_elements(public.book_crm_profile_detail(one)->'activity')x where x->'metadata'->>'event'='carrier_status' and x->'metadata'->'before'->>'status'='lapsed' and x->'metadata'->'after'->>'status'='issued') then raise exception 'Status change history missing';end if;
 version:=(r->>'updated_at')::timestamptz;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'aal','aal2','session_id',sid)::text,true);
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'in_force','carrier_portal',current_date,'Foreign','',version,r->'deal_version');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign agent accepted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner,'aal','aal2','session_id',sid)::text,true);
 perform public.book_crm_carrier_status_save(one,'unverified',null,null,'Confirmation entered for wrong policy','',version,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';if r->>'carrier_status'<>'unverified' or r->>'carrier_confirmed_on' is not null or r->>'carrier_status_source' is not null or r->>'pipeline_stage'<>'in_force' then raise exception 'Reset invalid';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal1','session_id',sid)::text,true);
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'unverified',null,null,'No MFA','',(r->>'updated_at')::timestamptz,r->'deal_version');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'MFA bypass';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',gen_random_uuid())::text,true);
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'unverified',null,null,'No PIN','',(r->>'updated_at')::timestamptz,r->'deal_version');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'PIN bypass';end if;
 if has_table_privilege('authenticated','private.book_crm_carrier_status','select') or has_table_privilege('authenticated','private.book_crm_carrier_status','update') or has_function_privilege('anon','public.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz,jsonb)','execute') then raise exception 'Direct access leaked';end if;
 if (select count(*) from public.closed_business where agent_id=a)<>before_deals+1 then raise exception 'Carrier operations changed production';end if;
end;$$;
select 'PASS: independent agent/carrier states, per-policy evidence, history, identity recheck, validation, stale updates, agent/owner scope, PIN/MFA, and preserved production; rolled back' result;
rollback;
