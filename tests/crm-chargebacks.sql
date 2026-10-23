-- Real RPCs, synthetic policies, and no committed records or notifications.
begin;
do $$
declare a uuid; b uuid; sid uuid:=gen_random_uuid(); one uuid:=gen_random_uuid(); two uuid:=gen_random_uuid();
 r jsonb; before_row jsonb; d jsonb; deal_before jsonb; comp_before jsonb; v_deal_id uuid; total bigint; denied boolean;
begin
 select p.id into a from public.profiles p join public.divisions ag on ag.id=p.division where p.active and p.role='agent' and not coalesce(p.archived,false) and not ag.archived and p.division='vivid_life' limit 1;
 select p.id into b from public.profiles p join public.divisions ag on ag.id=p.division where p.active and p.role='agent' and not coalesce(p.archived,false) and not ag.archived and p.id<>a limit 1;
 if a is null or b is null then raise exception 'Active test agents missing';end if;
 insert into private.book_unlocks values(a,sid::text,now()+interval '15 minutes'),(b,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 perform public.book_crm_save_v2(one,jsonb_build_object('agent_id',a,'client_name','__CHARGEBACK_TEST__','phone','2025550111','carrier','Ethos','policy_type','Term','monthly_payment',100,'application_date',current_date,'effective_date',current_date,'pipeline_stage','in_force'));
 r:=public.book_crm_profile_detail(one)->'client';v_deal_id:=(r->>'deal_id')::uuid;
 select to_jsonb(c) into deal_before from public.closed_business c where c.id=v_deal_id;
 select to_jsonb(c) into comp_before from private.book_deal_comp c where c.deal_id=v_deal_id;
 select count(*) into total from public.closed_business;
 perform public.book_crm_carrier_status_save(one,'in_force','carrier_portal',current_date,'Synthetic confirmation','',(r->>'updated_at')::timestamptz,r->'deal_version');
 before_row:=public.book_crm_profile_detail(one)->'client';
 perform public.book_crm_save_v2(one,'{"pipeline_stage":"chargeback"}',(before_row->>'updated_at')::timestamptz,before_row->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';
 if r->>'pipeline_stage'<>'chargeback' or r->>'status'<>'chargeback' or r->>'carrier_status'<>'in_force' or not (r->>'carrier_status_current')::boolean then raise exception 'Agent chargeback persistence or carrier independence failed';end if;
 if exists(select 1 from private.book_crm_tasks where client_id=one) then raise exception 'Agent-only status created carrier task';end if;
 if not exists(select 1 from private.book_crm_activity where client_id=one and body='In force → Chargeback') then raise exception 'Chargeback activity label missing';end if;
 d:=public.book_crm_pipeline('__CHARGEBACK_TEST__',a,'','chargeback');
 if (d->>'count')::int<>1 or d->'pipeline'->0->>'id'<>one::text or (d->'stage_counts'->>'chargeback')::int<>1 then raise exception 'Chargeback board filtering/count failed';end if;
 d:=public.book_crm_pipeline('__CHARGEBACK_TEST__',a,'','chargeback',1,50,'list');
 if d->'rows'->0->>'pipeline_stage'<>'chargeback' then raise exception 'Chargeback pipeline list/CSV source failed';end if;
 d:=public.book_crm_profiles_list(1,'__CHARGEBACK_TEST__',a,'chargeback');
 if (d->>'count')::int<>1 or (d->>'monthly_payment')::numeric<>0 or (d->>'estimated_advance')::numeric<>0 then raise exception 'Chargeback profile filter or active totals failed';end if;
 d:=public.book_crm_workspace(1,'__CHARGEBACK_TEST__',a,'chargeback');
 if (d->>'count')::int<>1 or d->'rows'->0->>'pipeline_stage'<>'chargeback' then raise exception 'Legacy workspace filter failed';end if;
 denied:=false;begin perform public.book_crm_save_v2(one,'{"pipeline_stage":"chargeback"}',(before_row->>'updated_at')::timestamptz,before_row->'deal_version');exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale move accepted';end if;
 -- Restoring the stage never duplicates the existing deal; carrier chargeback remains independent.
 perform public.book_crm_save_v2(one,'{"pipeline_stage":"in_force"}',(r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';
 perform public.book_crm_carrier_status_save(one,'chargeback','carrier_statement',current_date,'Synthetic chargeback statement','',(r->>'updated_at')::timestamptz,r->'deal_version');
 r:=public.book_crm_profile_detail(one)->'client';
 if r->>'pipeline_stage'<>'in_force' or r->>'status'<>'active' or r->>'carrier_status'<>'chargeback' then raise exception 'Carrier chargeback moved agent stage';end if;
 if not exists(select 1 from private.book_crm_tasks where client_id=one and source='carrier_status' and carrier_status='chargeback' and priority='high' and title='Carrier follow-up: Chargeback' and completed_at is null) then raise exception 'Red chargeback task missing';end if;
 perform public.book_crm_carrier_status_save(one,'chargeback','carrier_statement',current_date,'Same statement','',(r->>'updated_at')::timestamptz,r->'deal_version');
 if (select count(*) from private.book_crm_tasks where client_id=one and source='carrier_status')<>1 then raise exception 'Duplicate chargeback task';end if;
 -- A historical chargeback policy can be entered without inventing an effective date or deal.
 perform public.book_crm_policy_save(one,two,jsonb_build_object('carrier','Aetna','policy_type','Final Expense','monthly_payment',50,'application_date',current_date,'pipeline_stage','chargeback'));
 d:=public.book_crm_profile_detail(two)->'client';
 if d->>'pipeline_stage'<>'chargeback' or d->>'effective_date' is not null or d->>'deal_id' is not null or d->>'carrier_status'<>'unverified' then raise exception 'New chargeback policy created coverage, carrier confirmation or production';end if;
 if (select to_jsonb(c) from public.closed_business c where c.id=v_deal_id) is distinct from deal_before or (select count(*) from public.closed_business)<>total or (select to_jsonb(c) from private.book_deal_comp c where c.deal_id=v_deal_id) is distinct from comp_before then raise exception 'Chargeback altered recorded financial data';end if;
 if private.book_crm_stage(null,'chargeback')<>'chargeback' or private.book_crm_stage_label('chargeback')<>'Chargeback' then raise exception 'Legacy chargeback mapping failed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'aal','aal2','session_id',sid)::text,true);
 d:=public.book_crm_profiles_list(1,'__CHARGEBACK_TEST__',null,'chargeback');if (d->>'count')::int<>0 then raise exception 'Foreign agent can read chargeback';end if;
 denied:=false;begin perform public.book_crm_save_v2(one,'{"pipeline_stage":"chargeback"}',now(),null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign agent can move chargeback';end if;
 denied:=false;begin perform public.book_crm_carrier_status_save(one,'chargeback','carrier_portal',current_date,'Unauthorized','',now(),null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign agent can confirm chargeback';end if;
end;$$;
select 'PASS: Chargeback persistence, board/list/client filters, activity labels, independent carrier confirmation, red task/deduplication, no invented dates, stale/scope protection, unchanged recorded production and commission; rolled back' result;
rollback;
