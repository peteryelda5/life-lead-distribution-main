-- Synthetic records only; no phone delivery occurs. Everything rolls back.
begin;
set local statement_timeout='45s';
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 sa uuid:=gen_random_uuid(); sb uuid:=gen_random_uuid(); da uuid; db uuid; chat uuid; hidden_chat uuid; deal uuid; hidden_deal uuid;
 r jsonb; jobs jsonb; job jsonb; job_id uuid; lease_id uuid; mid bigint; count_before integer; at_time timestamptz; prior_claims text;
begin
 if has_function_privilege('anon','public.portal_push_manage(uuid,uuid,text,jsonb)','execute') or has_function_privilege('authenticated','public.portal_push_batch(uuid)','execute') or has_function_privilege('authenticated','private.portal_push_items(uuid,uuid)','execute') then raise exception 'Push worker privilege exposed';end if;
 if has_table_privilege('authenticated','private.portal_push_devices','select') or has_table_privilege('service_role','private.portal_push_devices','select') then raise exception 'Push device table exposed';end if;
 if not has_function_privilege('service_role','public.portal_push_manage(uuid,uuid,text,jsonb)','execute') then raise exception 'Missing server access';end if;
 insert into auth.users(id,email) values(a,a||'@example.invalid'),(b,b||'@example.invalid'),(outsider,outsider||'@example.invalid');
 insert into public.profiles(id,email,full_name,role,active,division)
  values(a,a||'@example.invalid','Push Agent Fixture','agent',true,'vivid_life'),(b,b||'@example.invalid','Push Peer Fixture','agent',true,'vivid_life'),(outsider,outsider||'@example.invalid','Private Agency Fixture','agent',true,'legacy_life')
  on conflict(id) do update set full_name=excluded.full_name,role='agent',active=true,archived=false,division=excluded.division;
 insert into auth.sessions(id,user_id,aal,created_at) values(sa,a,'aal2',now()),(sb,b,'aal2',now());
 begin perform public.portal_push_manage(a,sb,'sync','{"endpoint":"https://web.push.apple.com/fixture"}');raise exception 'Wrong session accepted' using errcode='XX000';exception when insufficient_privilege then null;end;
 r:=public.portal_push_manage(a,sa,'subscribe',jsonb_build_object('subscription',jsonb_build_object('endpoint','https://web.push.apple.com/fixture-'||a,'keys',jsonb_build_object('p256dh',repeat('A',87),'auth',repeat('A',22)))));
 da:=(r->'device'->>'id')::uuid;
 if da is null or not(r->'device'->'categories' ? 'deals') or not(r->'device'->'categories' ? 'chat') or r::text like '%endpoint%' or r::text like '%auth_key%' then raise exception 'Unsafe device response/defaults';end if;
 r:=public.portal_push_manage(b,sb,'subscribe',jsonb_build_object('subscription',jsonb_build_object('endpoint','https://web.push.apple.com/fixture-'||b,'keys',jsonb_build_object('p256dh',repeat('B',87),'auth',repeat('B',22)))));
 db:=(r->'device'->>'id')::uuid;
 begin perform public.portal_push_manage(b,sb,'disable',jsonb_build_object('id',da));raise exception 'Foreign device disabled' using errcode='XX000';exception when insufficient_privilege then null;end;
 begin perform public.portal_push_manage(b,sb,'subscribe',jsonb_build_object('subscription',jsonb_build_object('endpoint','https://web.push.apple.com/fixture-'||a,'keys',jsonb_build_object('p256dh',repeat('B',87),'auth',repeat('B',22)))));raise exception 'Endpoint ownership stolen' using errcode='XX000';exception when insufficient_privilege then null;end;
 begin perform public.portal_push_manage(a,sa,'subscribe','{"subscription":{"endpoint":"https://127.0.0.1/admin"}}');raise exception 'Internal endpoint accepted' using errcode='XX000';exception when raise_exception then null;end;
 update private.portal_push_devices set started_at=now()-interval '1 second' where id in (da,db);
 -- Only subscribed users' currently visible records enter the queue.
 insert into private.portal_conversations(name,kind,owner_id,members) values('Push fixture','group',a,array[a,b]) returning id into chat;
 insert into private.portal_conversation_messages(conversation_id,author_id,body,request_id) values(chat,b,'PRIVATE_MESSAGE_MUST_NOT_PUSH',gen_random_uuid()) returning id into mid;
 insert into private.portal_conversations(name,kind,owner_id,members) values('Private fixture','group',outsider,array[outsider]) returning id into hidden_chat;
 insert into private.portal_conversation_messages(conversation_id,author_id,body,request_id) values(hidden_chat,outsider,'PRIVATE_OTHER_AGENCY',gen_random_uuid());
 insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date,policy_number,notes)
  values(b,'Fixture','Fixture',120,current_date,'PRIVATE_POLICY','PRIVATE_NOTES') returning id,created_at into deal,at_time;
 insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date)
  values(outsider,'Fixture','Fixture',90,current_date) returning id into hidden_deal;
 prior_claims:='{"sub":"'||b||'","aal":"aal1"}';perform set_config('request.jwt.claims',prior_claims,true);perform set_config('request.jwt.claim.sub','',true);
 jobs:=public.portal_push_batch();
 if current_setting('request.jwt.claims')<>prior_claims or current_setting('request.jwt.claim.sub')<>'' then raise exception 'Claims were not restored';end if;
 if jobs::text like '%PRIVATE_%' then raise exception 'Private client/message data in push payload';end if;
 if not exists(select 1 from private.portal_push_deliveries where device_id=da and event_key='deal:'||deal and state='sending') or not exists(select 1 from private.portal_push_deliveries where device_id=da and event_key='group:'||chat and state='sending') then raise exception 'Deal/chat missing';end if;
 if exists(select 1 from private.portal_push_deliveries where device_id in (da,db) and event_key in ('deal:'||hidden_deal,'group:'||hidden_chat)) then raise exception 'Cross-agency/private chat leak';end if;
 select value into job from jsonb_array_elements(jobs) where value->'subscription'->>'endpoint'='https://web.push.apple.com/fixture-'||a and value->>'category'='deals';
 if job->>'title'<>'Push Peer Fixture closed a deal' or job->>'body' not like '%1,440%' then raise exception 'Deal display wrong';end if;
 job_id:=(job->>'id')::uuid;lease_id:=(job->>'lease')::uuid;
 if public.portal_push_finish(job_id,gen_random_uuid(),201) then raise exception 'Wrong lease accepted';end if;
 if not public.portal_push_finish(job_id,lease_id,201) then raise exception 'Valid acknowledgement rejected';end if;
 if public.portal_push_finish(job_id,lease_id,201) then raise exception 'Acknowledgement replay accepted';end if;
 select count(*) into count_before from private.portal_push_deliveries where device_id=da;
 perform public.portal_push_batch();
 if (select count(*) from private.portal_push_deliveries where device_id=da)<>count_before then raise exception 'Duplicate notifications';end if;
 update public.closed_business set monthly_premium=180 where id=deal;
 perform public.portal_push_batch();
 if (select count(*) from private.portal_push_deliveries where device_id=da and event_key='deal:'||deal)<>1 then raise exception 'Edited deal replayed';end if;
 r:=public.portal_push_manage(a,sa,'open',jsonb_build_object('id',job_id));
 if r->'item'->'target'->>'tab'<>'leaderboard' then raise exception 'Deep link target missing';end if;
 r:=public.portal_push_manage(b,sb,'open',jsonb_build_object('id',job_id));
 if r->'item'<>'null'::jsonb then raise exception 'Foreign delivery deep link exposed';end if;
 -- Current access is rechecked immediately before retry/send and on opening.
 update public.profiles set division='legacy_life' where id=a;
 r:=public.portal_push_manage(a,sa,'open',jsonb_build_object('id',job_id));if r->'item'<>'null'::jsonb then raise exception 'Old agency deep link accessible';end if;
 update public.profiles set division='vivid_life' where id=a;
 update private.portal_conversations set members=array[b] where id=chat;
 update private.portal_push_deliveries set next_attempt=now() where device_id=da and event_key='group:'||chat;
 perform public.portal_push_batch();
 if exists(select 1 from private.portal_push_deliveries where device_id=da and event_key='group:'||chat and state<>'skipped') then raise exception 'Removed chat member still notified';end if;
 -- Test is per-device, throttled, and expired endpoints stop further attempts.
 r:=public.portal_push_manage(a,sa,'test',jsonb_build_object('id',da));job_id:=(r->>'job')::uuid;
 begin perform public.portal_push_manage(a,sa,'test',jsonb_build_object('id',da));raise exception 'Test throttle failed' using errcode='XX000';exception when raise_exception then null;end;
 jobs:=public.portal_push_batch(job_id);if jsonb_array_length(jobs)<>1 then raise exception 'Test dispatch escaped target';end if;
 perform public.portal_push_finish(job_id,(jobs->0->>'lease')::uuid,410);
 if (select enabled from private.portal_push_devices where id=da) then raise exception 'Expired endpoint still enabled';end if;
 -- Preferences and existing mute/read state are respected for later events.
 perform public.portal_push_manage(b,sb,'preferences',jsonb_build_object('id',db,'categories',jsonb_build_array('leads')));
 insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date) values(b,'Fixture','Fixture',33,current_date) returning id into deal;
 perform public.portal_push_batch();if exists(select 1 from private.portal_push_deliveries where device_id=db and event_key='deal:'||deal) then raise exception 'Disabled category delivered';end if;
 update public.profiles set active=false where id=b;
 jobs:=public.portal_push_batch();if (select enabled from private.portal_push_devices where id=db) then raise exception 'Disabled user still enabled';end if;
 update public.profiles set active=true where id=b;
 delete from auth.sessions where id=sa;
 if exists(select 1 from private.portal_push_devices where id=da) then raise exception 'Signed-out session device retained';end if;
end $$;
rollback;
select 'PASS: push opt-in, private keys, current access, chat/deal scope, safe payloads, dedupe, claims restoration, leases, preferences, logout and endpoint expiry; all fixtures rolled back.' as result;
