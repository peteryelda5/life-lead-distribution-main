-- Full rollback, including generated deals, audit entries, announcements and notifications.
begin;
do $$
declare a uuid; b uuid; owner uuid; sid uuid:=gen_random_uuid(); one uuid:=gen_random_uuid(); two uuid:=gen_random_uuid(); tid uuid:=gen_random_uuid(); nid uuid:=gen_random_uuid();
 r jsonb; d jsonb; first_row jsonb; second_row jsonb; fields jsonb; version timestamptz; profile_version timestamptz; before_deals bigint; denied boolean;
begin
 select p.id into a from public.profiles p join public.divisions d on d.id=p.division where p.role='agent' and p.active and not coalesce(p.archived,false) and not d.archived and p.division='vivid_life' limit 1;
 select p.id into b from public.profiles p join public.divisions d on d.id=p.division where p.role='agent' and p.active and not coalesce(p.archived,false) and not d.archived and p.id<>a limit 1;
 select id into owner from public.profiles where is_super_admin and active limit 1;
 if a is null or b is null or owner is null then raise exception 'Test requires active roles';end if;
 insert into private.book_unlocks values(a,sid::text,now()+interval '15 minutes'),(b,sid::text,now()+interval '15 minutes'),(owner,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 select count(*) into before_deals from public.closed_business where agent_id=a;
 insert into private.book_comp_grid(agent_id,carrier,policy_type,comp_percent,advance_percent,effective_date,updated_by) values(a,'ethos','term',80,75,current_date-20,owner),(a,'aetna','final expense',90,50,current_date-20,owner)
 on conflict(agent_id,carrier,policy_type,effective_date) do update set comp_percent=excluded.comp_percent,advance_percent=excluded.advance_percent;
 perform public.book_crm_save_v2(one,jsonb_build_object('agent_id',a,'client_name','__MULTIPOLICY_TEST__','phone','2025550111','email','multi@example.invalid','carrier','Ethos','policy_type','Term','monthly_payment',100,'application_date',current_date-10,'effective_date',current_date-5,'pipeline_stage','submitted','notes','Ethos only'));
 d:=public.book_crm_profile_detail(one);first_row:=d->'client';profile_version:=(d->'profile'->>'updated_at')::timestamptz;
 if d->'profile'->>'id'<>one::text or jsonb_array_length(d->'policies')<>1 then raise exception 'Initial profile linkage failed';end if;
 fields:=jsonb_build_object('carrier','Aetna','policy_type','Final Expense','monthly_payment',50,'application_date',current_date-9,'effective_date',current_date-4,'pipeline_stage','approved','policy_number','TEST-AETNA','notes','Aetna only');
 perform public.book_crm_policy_save(one,two,fields);
 perform public.book_crm_policy_save(one,two,fields); -- exact retry must not duplicate
 d:=public.book_crm_profile_detail(two);second_row:=d->'client';
 if jsonb_array_length(d->'policies')<>2 or d->'profile'->>'id'<>one::text or second_row->>'id'<>two::text then raise exception 'Second policy not attached / duplicate retry';end if;
 if second_row->>'carrier'<>'Aetna' or second_row->>'effective_date'<>(current_date-4)::text or (second_row->>'estimated_advance')::numeric<>270 or (first_row->>'estimated_advance')::numeric<>720 then raise exception 'Independent policy fields/commission failed';end if;
 r:=public.book_crm_profiles_list(1,'__MULTIPOLICY_TEST__');
 if (r->>'count')::int<>1 or (r->>'policy_count')::int<>2 or (r->'rows'->0->>'policy_count')::int<>2 then raise exception 'Client list not grouped';end if;
 r:=public.book_crm_pipeline('__MULTIPOLICY_TEST__');if (r->>'count')::int<>2 or (r->'stage_counts'->>'submitted')::int<>1 or (r->'stage_counts'->>'approved')::int<>1 then raise exception 'Policy board independence failed';end if;
 if (select count(*) from public.closed_business where agent_id=a)<>before_deals then raise exception 'Unissued policy recorded production';end if;
 perform public.book_crm_policy_save(one,two,'{"monthly_payment":60,"pipeline_stage":"in_force"}',(second_row->>'updated_at')::timestamptz,second_row->'deal_version');
 d:=public.book_crm_profile_detail(one);select x into first_row from jsonb_array_elements(d->'policies')x where x->>'id'=one::text;select x into second_row from jsonb_array_elements(d->'policies')x where x->>'id'=two::text;
 if first_row->>'pipeline_stage'<>'submitted' or (first_row->>'monthly_payment')::numeric<>100 or second_row->>'pipeline_stage'<>'in_force' or (second_row->>'monthly_payment')::numeric<>60 or (second_row->>'estimated_advance')::numeric<>324 then raise exception 'Changing Aetna changed Ethos / commission wrong';end if;
 if (select count(*) from public.closed_business where agent_id=a)<>before_deals+1 then raise exception 'Production count incorrect after first in-force policy';end if;
 version:=(second_row->>'updated_at')::timestamptz;
 perform public.book_crm_policy_save(one,two,'{"notes":"Aetna revised"}',version,second_row->'deal_version');
 denied:=false;begin perform public.book_crm_policy_save(one,two,'{"monthly_payment":999}',version,second_row->'deal_version');exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale policy accepted';end if;
 if (select count(*) from public.closed_business where agent_id=a)<>before_deals+1 then raise exception 'Policy edit duplicated production';end if;
 perform public.book_crm_policy_save(one,one,'{"pipeline_stage":"in_force"}',(first_row->>'updated_at')::timestamptz,first_row->'deal_version');
 if (select count(*) from public.closed_business where agent_id=a)<>before_deals+2 then raise exception 'Second policy failed independent production';end if;
 r:=public.book_crm_profiles_list(1,'__MULTIPOLICY_TEST__');if (r->>'monthly_payment')::numeric<>160 or (r->>'estimated_advance')::numeric<>1044 then raise exception 'Portfolio totals wrong / double counted';end if;
 d:=public.book_crm_profile_detail(one);profile_version:=(d->'profile'->>'updated_at')::timestamptz;
 perform public.book_crm_profile_save(one,'{"phone":"2025550199","city":"Troy","date_of_birth":"1980-01-02"}',profile_version);
 d:=public.book_crm_profile_detail(two);
 if d->'profile'->>'phone'<>'2025550199' or exists(select 1 from jsonb_array_elements(d->'policies')j where j->>'phone'<>'2025550199' or j->>'city'<>'Troy') then raise exception 'Shared contact not synchronized';end if;
 if (select count(*) from private.book_clients b join private.book_crm_clients c on c.deal_id=b.deal_id where c.profile_id=one and b.phone='2025550199')<>2 then raise exception 'Deal contact snapshots not synchronized';end if;
 denied:=false;begin perform public.book_crm_profile_save(one,'{"phone":"bad"}',profile_version);exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale contact accepted';end if;
 -- An old open tab may still use the existing save API; its shared edit must not diverge.
 second_row:=d->'client';perform public.book_crm_save_v2(two,'{"phone":"2025550188"}',(second_row->>'updated_at')::timestamptz,second_row->'deal_version');
 d:=public.book_crm_profile_detail(one);if d->'profile'->>'phone'<>'2025550188' or exists(select 1 from jsonb_array_elements(d->'policies')j where j->>'phone'<>'2025550188') then raise exception 'Legacy edit broke shared contact';end if;
 perform public.book_crm_action(two,'note',nid,'',null,'Aetna follow-up');perform public.book_crm_action(two,'task',tid,'Aetna welcome',now()+interval '1 hour');
 d:=public.book_crm_profile_detail(one);if not exists(select 1 from jsonb_array_elements(d->'activity')x where x->>'id'=nid::text and x->>'carrier'='Aetna') or not exists(select 1 from jsonb_array_elements(d->'tasks')x where x->>'id'=tid::text and x->>'client_id'=two::text and x->>'carrier'='Aetna') then raise exception 'Policy task/history identity lost';end if;
 select x into second_row from jsonb_array_elements(d->'policies')x where x->>'id'=two::text;
 perform public.book_crm_policy_save(one,two,'{"pipeline_stage":"cancelled"}',(second_row->>'updated_at')::timestamptz,second_row->'deal_version');
 r:=public.book_crm_profiles_list(1,'__MULTIPOLICY_TEST__');if (r->>'monthly_payment')::numeric<>100 or (r->'rows'->0->>'policy_count')::int<>2 then raise exception 'Cancelled sibling hidden or active total wrong';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'aal','aal2','session_id',sid)::text,true);
 r:=public.book_crm_profiles_list(1,'__MULTIPOLICY_TEST__');if (r->>'count')::int<>0 then raise exception 'Cross-agent profile leaked';end if;
 denied:=false;begin perform public.book_crm_profile_detail(one);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign detail visible';end if;
 denied:=false;begin perform public.book_crm_policy_save(one,gen_random_uuid(),fields);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign add policy accepted';end if;
 denied:=false;begin perform public.book_crm_profile_save(one,'{"phone":"bad"}',null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign contact edit accepted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner,'aal','aal2','session_id',sid)::text,true);
 d:=public.book_crm_profile_detail(one);if jsonb_array_length(d->'policies')<>2 then raise exception 'Owner access failed';end if;
 denied:=false;begin perform public.book_crm_policy_save(gen_random_uuid(),two,fields);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Cross-profile policy reassignment accepted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal1','session_id',sid)::text,true);
 denied:=false;begin perform public.book_crm_profiles_list();exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'MFA gate bypass';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',gen_random_uuid())::text,true);
 denied:=false;begin perform public.book_crm_profile_detail(one);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'PIN gate bypass';end if;
 if has_table_privilege('authenticated','private.book_crm_profiles','select') or has_table_privilege('anon','private.book_crm_profiles','select') or has_function_privilege('anon','public.book_crm_policy_save(uuid,uuid,jsonb,timestamp with time zone,jsonb)','execute') then raise exception 'Direct or anonymous access leaked';end if;
end;$$;
select 'PASS: one client / two independent policies, commissions, production exactly once, concurrency, shared contact, old API compatibility, policy tasks/history, scope and PIN/MFA; rolled back' result;
rollback;
