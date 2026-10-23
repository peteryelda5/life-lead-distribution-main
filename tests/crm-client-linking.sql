-- Synthetic records, real public RPCs/triggers, all rolled back.
begin;
do $$
declare a uuid; b uuid; sid uuid:=gen_random_uuid(); lead_one uuid:=gen_random_uuid(); lead_two uuid:=gen_random_uuid();
 deal_one uuid:=gen_random_uuid(); deal_two uuid:=gen_random_uuid(); deal_three uuid:=gen_random_uuid(); policy_one uuid; policy_two uuid; policy_three uuid;
 request_id uuid:=gen_random_uuid(); chat_deal uuid; r jsonb; old_deal jsonb; denied boolean; total bigint; info jsonb;
begin
 select p.id into a from public.profiles p join public.divisions ag on ag.id=p.division where p.active and p.role='agent' and not coalesce(p.archived,false) and not ag.archived and p.division='vivid_life' limit 1;
 select p.id into b from public.profiles p join public.divisions ag on ag.id=p.division where p.active and p.role='agent' and not coalesce(p.archived,false) and not ag.archived and p.id<>a limit 1;
 if a is null or b is null then raise exception 'Active test agents missing';end if;
 insert into private.book_unlocks values(a,sid::text,now()+interval '15 minutes'),(b,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 insert into public.leads(id,first_name,last_name,phone,email,state,division,assigned_to,status,csv_headers,csv_values)
 values(lead_one,'','','','','','vivid_life',a,'assigned','["AgentName","FullName","Phone Number","Email","Address","City","Zip"]','["Not the client","CSV Client","2025550101","csv@example.invalid","123 Test St","Detroit","48000"]'),
 (lead_two,'','','2025550102','','MI','vivid_life',a,'assigned','["AgentName"]','["Do not use agent name"]');
 insert into public.closed_business(id,lead_id,agent_id,carrier,policy_type,monthly_premium,application_date)
 values(deal_one,lead_one,a,'Ethos','Term',100,current_date),(deal_two,lead_two,a,'Aetna','Final Expense',50,current_date),(deal_three,null,a,'Americo','Final Expense',25,current_date);
 select id into policy_one from private.book_crm_clients where deal_id=deal_one;
 select id into policy_two from private.book_crm_clients where deal_id=deal_two;
 select id into policy_three from private.book_crm_clients where deal_id=deal_three;
 r:=public.book_crm_profile_detail(policy_one)->'client';
 if r->>'client_name'<>'CSV Client' or r->>'phone'<>'2025550101' or r->>'email'<>'csv@example.invalid' or r->>'address_line1'<>'123 Test St' or r->>'city'<>'Detroit' then raise exception 'CSV contact extraction failed';end if;
 if not private.book_crm_missing_name((public.book_crm_profile_detail(policy_two)->'client')->>'client_name') then raise exception 'Agent name was used as client name';end if;
 select to_jsonb(d) into old_deal from public.closed_business d where id=deal_two;
 select count(*) into total from public.closed_business;
 update public.leads set first_name='Verified',last_name='Client',phone='2025550199' where id=lead_two;
 r:=public.book_crm_profile_detail(policy_two)->'client';
 if r->>'client_name'<>'Verified Client' or r->>'phone'<>'2025550102' then raise exception 'Late lead correction failed or overwritten existing contact';end if;
 if (select to_jsonb(d) from public.closed_business d where id=deal_two) is distinct from old_deal or (select count(*) from public.closed_business)<>total then raise exception 'Contact correction changed production';end if;
 update public.leads set first_name='Different' where id=lead_two;
 if (public.book_crm_profile_detail(policy_two)->'client')->>'client_name'<>'Verified Client' then raise exception 'Known contact overwritten';end if;
 -- Older Book contact API now completes the same CRM profile.
 perform public.book_client(deal_three,'Legacy Saved Client','2025550103','saved@example.invalid');
 r:=public.book_crm_profile_detail(policy_three)->'client';
 if r->>'client_name'<>'Legacy Saved Client' or r->>'phone'<>'2025550103' then raise exception 'Saved deal contact did not reach CRM';end if;
 denied:=false;begin perform public.book_crm_profile_save((r->>'profile_id')::uuid,'{"client_name":"Client not linked"}',(public.book_crm_profile_detail(policy_three)->'profile'->>'updated_at')::timestamptz);exception when others then denied:=true;end;if not denied then raise exception 'Placeholder accepted as client name';end if;
 -- New standalone deal entry captures the contact without requiring Book PIN.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',gen_random_uuid())::text,true);
 chat_deal:=public.chat_standalone_deal_with_client('vivid_life',a,request_id,'Ethos','Term',75,current_date,'Chat Client','2025550104','chat@example.invalid');
 if not exists(select 1 from private.book_crm_clients c join private.book_crm_profiles p on p.id=c.profile_id where c.deal_id=chat_deal and c.client_name='Chat Client' and p.details->>'client_name'='Chat Client' and c.phone='2025550104') then raise exception 'New chat deal missing client';end if;
 if public.chat_standalone_deal_with_client('vivid_life',a,request_id,'Ethos','Term',75,current_date,'Chat Client','2025550104','chat@example.invalid')<>chat_deal then raise exception 'Retry duplicated deal';end if;
 denied:=false;begin perform public.chat_standalone_deal_with_client('vivid_life',a,request_id,'Ethos','Term',75,current_date,'Different Client');exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Retry overwrote client';end if;
 denied:=false;begin perform public.chat_standalone_deal_with_client('vivid_life',a,gen_random_uuid(),'Ethos','Term',75,current_date,'');exception when others then denied:=true;end;if not denied then raise exception 'Empty client name accepted';end if;
 if (select count(*) from public.closed_business)<>total+1 then raise exception 'Standalone duplicate or failed validation left deal';end if;
 denied:=false;begin perform public.chat_standalone_deal_with_client('vivid_life',b,gen_random_uuid(),'Ethos','Term',75,current_date,'Unauthorized');exception when others then denied:=true;end;if not denied then raise exception 'Foreign agent write accepted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal1','session_id',sid)::text,true);
 denied:=false;begin perform public.chat_standalone_deal_with_client('vivid_life',a,gen_random_uuid(),'Ethos','Term',75,current_date,'Unverified');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'MFA bypass';end if;
 if has_function_privilege('authenticated','private.book_crm_fill_missing_contact(uuid,jsonb,uuid,text)','execute') or has_function_privilege('anon','public.chat_standalone_deal_with_client(text,uuid,uuid,text,text,numeric,date,text,text,text)','execute') then raise exception 'Internal helper or anonymous write exposed';end if;
 if private.book_crm_csv_value('{}','[]',array['name']) is not null or private.book_crm_csv_value('["Name"]','[null]',array['name']) is not null then raise exception 'Malformed CSV handling failed';end if;
end;$$;
select 'PASS: exact linked CSV contacts, late lead corrections, no agent-name guessing or known-contact overwrite, legacy contact sync, unchanged production, new chat client capture, retry/idempotency, input validation and authorization; rolled back' result;
rollback;
