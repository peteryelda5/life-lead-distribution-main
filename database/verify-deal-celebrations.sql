-- Transaction-only fixtures: no real deals, chat messages or signals are committed.
begin;
set local statement_timeout='30s';
do $$
declare a uuid:=gen_random_uuid(); legacy uuid:=gen_random_uuid(); deal_id uuid; legacy_deal uuid;
 original_at timestamptz; outbox jsonb; item jsonb; p public.profiles; counter integer:=0;
begin
 if has_function_privilege('anon','public.portal_notifications(text,jsonb)','execute') then raise exception 'Anonymous notification access';end if;
 if has_function_privilege('authenticated','private.portal_notification_items()','execute') then raise exception 'Raw notification source exposed';end if;
 insert into auth.users(id,email) values(a,'celebration-'||a||'@example.invalid'),(legacy,'celebration-'||legacy||'@example.invalid');
 insert into public.profiles(id,email,full_name,role,active,division)
 values(a,'celebration-'||a||'@example.invalid','Celebration Fixture','agent',true,'vivid_life'),
 (legacy,'celebration-'||legacy||'@example.invalid','Legacy Celebration Fixture','agent',true,'legacy_life')
 on conflict(id) do update set full_name=excluded.full_name,role='agent',active=true,division=excluded.division;
 insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date,policy_number,notes)
 values(a,'Test Carrier','Test Policy',120,current_date,'PRIVATE_FIXTURE_POLICY','PRIVATE_FIXTURE_NOTES') returning id,created_at into deal_id,original_at;
 insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date)
 values(legacy,'Test Carrier','Test Policy',100,current_date) returning id into legacy_deal;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal1','role','authenticated')::text,true);
 set local role authenticated;
 begin perform public.portal_notifications();raise exception 'Unverified session accepted';exception when insufficient_privilege then null;end;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','role','authenticated')::text,true);
 set local role authenticated;
 outbox:=public.portal_notifications('list','{"category":"deals"}');
 select value into item from jsonb_array_elements(outbox->'items') where value->>'key'='deal:'||deal_id;
 if item is null or (item->'target'->>'annual_premium')::numeric<>1440 then raise exception 'Real annual premium missing';end if;
 if item->'target'->>'agent_name'<>'Celebration Fixture' or nullif(item->'target'->>'agency_name','') is null or item->'target'->>'tab'<>'leaderboard' or item->'target'->>'celebration'<>'corner' then raise exception 'Celebration metadata missing';end if;
 if (select count(*) from jsonb_object_keys(item->'target'))<>5 or item::text like '%PRIVATE_FIXTURE%' then raise exception 'Private policy data exposed';end if;
 if exists(select 1 from jsonb_array_elements(outbox->'items') where value->>'key'='deal:'||legacy_deal) then raise exception 'Legacy deal exposed';end if;
 reset role;
 if exists(select 1 from private.portal_notification_items() where event_key='channel:deals' and occurred_at=original_at) then raise exception 'Automatic deal also creates generic chat alert';end if;
 update public.closed_business set monthly_premium=200 where id=deal_id;
 set local role authenticated;
 outbox:=public.portal_notifications('list','{"category":"deals"}');
 select value into item from jsonb_array_elements(outbox->'items') where value->>'key'='deal:'||deal_id;
 if (item->>'at')::timestamptz<>original_at or (item->'target'->>'annual_premium')::numeric<>2400 then raise exception 'Correction changed event identity or stale premium';end if;
 perform public.portal_notifications('read',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('key','deal:'||deal_id,'at',original_at))));
 outbox:=public.portal_notifications('list','{"category":"deals"}');
 if not exists(select 1 from jsonb_array_elements(outbox->'items') where value->>'key'='deal:'||deal_id and (value->>'read')::boolean) then raise exception 'Deal receipt failed';end if;
 outbox:=public.portal_notifications('preferences','{"muted_categories":["deals"],"toast_enabled":true,"category":"deals"}');
 if jsonb_array_length(outbox->'items')<>0 then raise exception 'Muted deals still returned';end if;
 perform public.portal_notifications('preferences','{"muted_categories":["leads","requests","calls","deals","chat","announcements","team","billing"]}');
 perform public.portal_notifications('preferences','{"muted_categories":[],"toast_enabled":true}');
 reset role;
 for p in select * from public.profiles where active and not coalesce(archived,false) and role in ('agent','admin') loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p.id,'aal','aal2','role','authenticated')::text,true);
  set local role authenticated;outbox:=public.portal_notifications('list','{"category":"deals"}');reset role;
  if exists(select 1 from private.portal_notification_items() n join public.closed_business cb on n.event_key='deal:'||cb.id join public.profiles seller on seller.id=cb.agent_id left join public.leads l on l.id=cb.lead_id where not coalesce(l.division,seller.division)=any(private.sales_board_divisions())) then raise exception 'Deal escaped leaderboard scope';end if;
  if p.id=legacy and (not exists(select 1 from jsonb_array_elements(outbox->'items') where value->>'key'='deal:'||legacy_deal) or exists(select 1 from jsonb_array_elements(outbox->'items') where value->>'key'='deal:'||deal_id)) then raise exception 'Legacy isolation failed';end if;
  counter:=counter+1;
 end loop;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','role','authenticated')::text,true);
 delete from public.closed_business where id=deal_id;
 set local role authenticated;outbox:=public.portal_notifications('list','{"category":"deals"}');reset role;
 if exists(select 1 from jsonb_array_elements(outbox->'items') where value->>'key'='deal:'||deal_id) then raise exception 'Withdrawn deal remains';end if;
 raise notice 'PASS: % active profiles; real premium, agency scope, Legacy isolation, no private details, no duplicate chat alert, stable corrections, withdrawal, preferences, receipts and MFA. All fixtures roll back.',counter;
end $$;
rollback;
select 'PASS: deal celebration transaction completed and rolled back' as result;
