-- Run inside BEGIN/ROLLBACK; test keys and counters must never persist.
insert into private.leaderboard_api_keys(key_hash,label,scope_name,allowed_divisions,expires_at,revoked_at) values
 (repeat('a',64),'transaction test','Test',array['vivid_life'],now()+interval '1 hour',null),
 (repeat('b',64),'transaction expired','Test',array['vivid_life'],now()-interval '1 hour',null),
 (repeat('c',64),'transaction revoked','Test',array['vivid_life'],now()+interval '1 hour',now()),
 (repeat('d',64),'transaction empty scope','Test',array['__nonexistent_test_division__'],now()+interval '1 hour',null);
do $$begin
 assert not has_function_privilege('anon','public.submitted_deals_api_read(text,text,date,uuid,integer)','execute');
 assert not has_function_privilege('authenticated','public.submitted_deals_api_read(text,text,date,uuid,integer)','execute');
 assert not has_function_privilege('anon','private.submitted_deals_api_read(text,text,date,uuid,integer)','execute');
 assert not has_function_privilege('authenticated','private.submitted_deals_api_read(text,text,date,uuid,integer)','execute');
end $$;
set local role service_role;
do $$
declare r jsonb; row_data jsonb; cursor_id uuid; previous_id uuid; seen uuid[]:='{}';expected bigint; amount_month numeric;amount_year numeric;
begin
 assert (public.submitted_deals_api_read(null)->>'status')::int=401;
 assert (public.submitted_deals_api_read(repeat('b',64))->>'status')::int=401;
 assert (public.submitted_deals_api_read(repeat('c',64))->>'status')::int=401;
 assert (public.submitted_deals_api_read(repeat('a',64),'all')->>'status')::int=400;
 assert (public.submitted_deals_api_read(repeat('a',64),'month',null,null,501)->>'status')::int=400;
 assert (public.submitted_deals_api_read(repeat('a',64),'previous',current_date)->>'status')::int=400;
 assert (public.submitted_deals_api_read(repeat('d',64))->'data'->'deals')='[]'::jsonb;
 loop
  r:=public.submitted_deals_api_read(repeat('a',64),'month',null,cursor_id,500);
  assert (r->>'status')::int=200;
  for row_data in select value from jsonb_array_elements(r->'data'->'deals') loop
   assert (select array_agg(key order by key) from jsonb_object_keys(row_data) key)=array['agency','agent_id','agent_name','annual_premium','deal_id','monthly_premium','submitted_at'];
   assert row_data->>'agency'='Vivid Life Advisors';
   assert not (row_data->>'deal_id')::uuid=any(seen);
   assert previous_id is null or (row_data->>'deal_id')::uuid>previous_id;
   previous_id:=(row_data->>'deal_id')::uuid;
   seen:=array_append(seen,previous_id);
   assert exists(select 1 from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id
    where cb.id=previous_id and coalesce(l.division,p.division)='vivid_life'
     and cb.agent_id=(row_data->>'agent_id')::uuid
     and cb.monthly_premium is not distinct from (row_data->>'monthly_premium')::numeric
     and cb.annual_premium is not distinct from (row_data->>'annual_premium')::numeric
     and cb.created_at=(row_data->>'submitted_at')::timestamptz);
  end loop;
  cursor_id:=(r->'data'->>'next_after')::uuid;
  exit when cursor_id is null;
  assert cursor_id=previous_id;
 end loop;
 select count(*) into expected from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id
 where coalesce(l.division,p.division)='vivid_life' and cb.created_at>=date_trunc('month',now() at time zone 'America/Detroit') at time zone 'America/Detroit' and cb.created_at<now();
 assert cardinality(seen)=expected;
 r:=public.submitted_deals_api_read(repeat('a',64),'month',null,null,1);
 if expected>1 then
  assert jsonb_array_length(r->'data'->'deals')=1;
  cursor_id:=(r->'data'->>'next_after')::uuid;
  assert cursor_id=(r->'data'->'deals'->0->>'deal_id')::uuid;
  r:=public.submitted_deals_api_read(repeat('a',64),'month',null,cursor_id,1);
  assert (r->'data'->'deals'->0->>'deal_id')::uuid>cursor_id;
 end if;
 update private.leaderboard_api_keys set window_start=now(),window_count=60 where key_hash=repeat('a',64);
 assert (public.submitted_deals_api_read(repeat('a',64))->>'status')::int=429;
end $$;
reset role;
select 'PASS: scoped records, exact seven fields, recorded values, paging, expiry, revocation, no public execution, rate limit' as test_result;
