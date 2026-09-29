do $$
declare fixture_agent uuid:=gen_random_uuid(); fixture_lead uuid; fixture_deal uuid;
 master_id uuid; other_admin uuid; prior_at timestamptz; response jsonb;
 before_count bigint; denied boolean;
begin
 select id into master_id from public.profiles where role='admin' and is_super_admin and active limit 1;
 select id into other_admin from public.profiles where role='admin' and division='legacy_life' and active limit 1;
 if master_id is null or other_admin is null then raise exception 'Missing admin test roles';end if;
 begin
  perform set_config('request.jwt.claims','{}',true);
  insert into auth.users(id,email) values(fixture_agent,fixture_agent||'@example.invalid');
  insert into public.profiles(id,email,full_name,role,active,division)
   values(fixture_agent,fixture_agent||'@example.invalid','Correction Fixture','agent',true,'owner');
  insert into public.leads(first_name,last_name,phone,lead_type,division,status,assigned_to,
   csv_headers,csv_values,owner_admin_id,updated_at)
   values('Original','Client','1234567890','Batch A','owner','closed',fixture_agent,
   '["First Name","Phone","Custom Field"]','["Original","1234567890","Original detail"]',master_id,now()-interval '1 day')
   returning id,updated_at into fixture_lead,prior_at;
  insert into public.closed_business(lead_id,agent_id,carrier,policy_type,monthly_premium,application_date)
   values(fixture_lead,fixture_agent,'Fixture Carrier','Term',100,current_date) returning id into fixture_deal;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  response:=public.correct_closed_lead(fixture_deal,prior_at,
   '{"first_name":"Corrected","phone":"2345678901","csv_values":["Corrected","2345678901","Updated detail"]}'::jsonb,
   'Corrected client contact information');
  if response->>'changed'<>'true' then raise exception 'Correction was not applied';end if;
  if not exists(select 1 from public.leads where id=fixture_lead and first_name='Corrected' and status='closed' and assigned_to=fixture_agent)
   or not exists(select 1 from public.closed_business where id=fixture_deal and monthly_premium=100)
   then raise exception 'Closed lead/deal was lost';end if;
  select count(*) into before_count from public.lead_corrections where lead_id=fixture_lead;
  if before_count<>1 or not exists(select 1 from public.lead_corrections
   where lead_id=fixture_lead and before_data->>'first_name'='Original'
   and before_data->'csv_values'->>2='Original detail'
   and after_data->>'first_name'='Corrected'
   and actor_id=master_id and reason='Corrected client contact information')
   then raise exception 'Original values, actor, or reason not preserved';end if;
  response:=public.correct_closed_lead(fixture_deal,(response->>'updated_at')::timestamptz,
   '{"first_name":"Corrected"}'::jsonb,'No change requested');
  select count(*) into before_count from public.lead_corrections where lead_id=fixture_lead;
  if before_count<>1 or response->>'changed'<>'false' then raise exception 'No-op generated a correction';end if;
  denied:=false;
  begin perform public.correct_closed_lead(fixture_deal,prior_at,'{"first_name":"Stale"}'::jsonb,'Stale update');
  exception when sqlstate 'PT409' then denied:=true;end;
  if not denied then raise exception 'Stale editor overwrote correction';end if;
  reset role;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',other_admin,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  denied:=false;
  begin perform public.correct_closed_lead(fixture_deal,(response->>'updated_at')::timestamptz,
    '{"first_name":"Wrong division"}'::jsonb,'Wrong division');
  exception when insufficient_privilege then denied:=true;end;
  if not denied then raise exception 'Legacy admin corrected Master lead';end if;
  reset role;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal1')::text,true);
  set local role authenticated;
  denied:=false;
  begin perform public.correct_closed_lead(fixture_deal,prior_at,'{"first_name":"Weak MFA"}'::jsonb,'Weak MFA');
  exception when insufficient_privilege then denied:=true;end;
  if not denied then raise exception 'Password-only admin corrected lead';end if;
  reset role;
  raise sqlstate 'ZX001' using message='Rollback correction fixtures';
 exception when sqlstate 'ZX001' then reset role;
 end;
 if exists(select 1 from auth.users where id=fixture_agent) then raise exception 'Fixture persisted';end if;
end $$;
