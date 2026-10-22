-- Rollback-only integration test: no changes, tasks or notifications are retained.
begin;
do $$
declare a uuid; b uuid; owner uuid; sid uuid:=gen_random_uuid(); ids uuid[]:='{}'; cid uuid; tid uuid:=gen_random_uuid(); r jsonb; d jsonb; denied boolean; i int;
 day_start timestamptz:='2026-11-01 04:00:00+00'; day_end timestamptz:='2026-11-02 05:00:00+00';
begin
 select p.id into a from public.profiles p join public.divisions d on d.id=p.division where p.role='agent' and p.active and not coalesce(p.archived,false) and not d.archived and p.division='vivid_life' limit 1;
 select p.id into b from public.profiles p join public.divisions d on d.id=p.division where p.role='agent' and p.active and not coalesce(p.archived,false) and not d.archived and p.id<>a limit 1;
 select id into owner from public.profiles where is_super_admin and active limit 1;
 if a is null or b is null or owner is null then raise exception 'Need active test roles';end if;
 insert into private.book_unlocks values(a,sid::text,now()+interval '15 minutes'),(b,sid::text,now()+interval '15 minutes'),(owner,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 for i in 1..29 loop
  cid:=gen_random_uuid();ids:=array_append(ids,cid);
  insert into private.book_crm_clients(id,agent_id,client_name,carrier,policy_type,monthly_payment,application_date,status,pipeline_stage)
   values(cid,a,'__PIPELINE_BOARD_TEST__ '||i,case when i=29 then '__Exact carrier plus__' else '__Exact carrier__' end,'Term',100,current_date,'draft','new');
 end loop;
 -- Deliberately place a match beyond the initial 25-card cap.
 update private.book_crm_clients set created_at=now()-interval '1 year' where id=ids[1];
 insert into private.book_crm_tasks(id,client_id,title,due_at,created_by) values(tid,ids[1],'__Today follow-up__',day_end-interval '1 minute',a);
 insert into private.book_crm_tasks(client_id,title,due_at,created_by) values(ids[1],'__Tomorrow__',day_end,a),(ids[1],'__Yesterday__',day_start-interval '1 minute',a);
 r:=public.book_crm_pipeline('__PIPELINE_BOARD_TEST__',a,'__Exact carrier__','',1,50,'board',day_start,day_end);
 if (r->>'count')::int<>28 or (r->'stage_counts'->>'new')::int<>28 or jsonb_array_length(r->'pipeline')<>25 then raise exception 'Carrier counts or board cap wrong';end if;
 if (r->>'today_task_count')::int<>1 or r->'today_tasks'->0->>'id'<>tid::text then raise exception 'Today task missing outside board cap / local-day boundary incorrect';end if;
 if not (r->'carriers' ? '__Exact carrier plus__') then raise exception 'Carrier option lost when selected';end if;
 r:=public.book_crm_pipeline('__PIPELINE_BOARD_TEST__',a,'__Exact carrier__','new',1,20,'list',day_start,day_end);
 if jsonb_array_length(r->'rows')<>20 or jsonb_array_length(r->'pipeline')<>0 or (r->>'count')::int<>28 then raise exception 'List paging failed';end if;
 r:=public.book_crm_pipeline('__PIPELINE_BOARD_TEST__',a,'__Exact carrier__','new',2,20,'list',day_start,day_end);
 if jsonb_array_length(r->'rows')<>8 then raise exception 'Second list page failed';end if;
 d:=public.book_crm_detail(ids[1]);
 perform public.book_crm_save_v2(ids[1],'{"pipeline_stage":"contacted"}',(d->'client'->>'updated_at')::timestamptz,d->'client'->'deal_version');
 r:=public.book_crm_pipeline('__PIPELINE_BOARD_TEST__',a,'__Exact carrier__','',1,50,'board',day_start,day_end);
 if (r->'stage_counts'->>'contacted')::int<>1 or not exists(select 1 from jsonb_array_elements(r->'pipeline')j where j->>'id'=ids[1]::text and j->>'pipeline_stage'='contacted') then raise exception 'Saved move missing after fresh read';end if;
 perform public.book_crm_action(ids[1],'complete',tid,'',null,'',(select updated_at from private.book_crm_tasks where id=tid));
 r:=public.book_crm_pipeline('__PIPELINE_BOARD_TEST__',a,'__Exact carrier__','',1,50,'board',day_start,day_end);
 if (r->>'today_task_count')::int<>0 then raise exception 'Completed task still in Today';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'aal','aal2','session_id',sid)::text,true);
 r:=public.book_crm_pipeline('__PIPELINE_BOARD_TEST__',a,'__Exact carrier__','',1,50,'board',day_start,day_end);
 if (r->>'count')::int<>0 or jsonb_array_length(r->'carriers')<>0 or (r->>'today_task_count')::int<>0 then raise exception 'Cross-agent data leaked';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner,'aal','aal2','session_id',sid)::text,true);
 r:=public.book_crm_pipeline('__PIPELINE_BOARD_TEST__',a,'__Exact carrier__','',1,50,'board',day_start,day_end);
 if (r->>'count')::int<>28 then raise exception 'Owner view failed';end if;
 denied:=false;begin perform public.book_crm_pipeline(p_today_start=>day_start,p_today_end=>day_start);exception when others then denied:=true;end;if not denied then raise exception 'Invalid day accepted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal1','session_id',sid)::text,true);
 denied:=false;begin perform public.book_crm_pipeline();exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'MFA gate bypass';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',gen_random_uuid())::text,true);
 denied:=false;begin perform public.book_crm_pipeline();exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'PIN gate bypass';end if;
 if has_function_privilege('anon','public.book_crm_pipeline(text,uuid,text,text,integer,integer,text,timestamp with time zone,timestamp with time zone)','execute') then raise exception 'Anonymous execute leaked';end if;
 if not has_function_privilege('authenticated','public.book_crm_pipeline(text,uuid,text,text,integer,integer,text,timestamp with time zone,timestamp with time zone)','execute') then raise exception 'Authenticated wrapper missing';end if;
end;$$;
select 'PASS: pipeline filters, board cap, list paging, persisted move, local DST day, task completion, scope, MFA/PIN and grants; rolled back' result;
rollback;
