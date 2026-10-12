-- Run only against recovery/test data. Every fixture and profile change rolls back.
begin;
do $$
declare master_id uuid; agent_id uuid; other_admin uuid; request_id uuid; missing_id uuid; done_id uuid;
  batch text:='__availability_'||gen_random_uuid()::text; result jsonb; rowdata jsonb; options jsonb; exact_count bigint;
begin
  select id into master_id from public.profiles where role='admin' and is_super_admin and active and not coalesce(archived,false) limit 1;
  select id into agent_id from public.profiles where role='agent' and division='vivid_life' and active and not coalesce(archived,false) limit 1;
  select id into other_admin from public.profiles where role='admin' and not is_super_admin and division not in ('owner','vivid_life') and active and not coalesce(archived,false) limit 1;
  if master_id is null or agent_id is null or other_admin is null then raise exception 'Missing test users';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal2')::text,true);
  insert into public.leads(division,lead_type,state) values
    ('vivid_life',batch,'TX'),('vivid_life',upper(batch),'FL'),('vivid_life',' '||batch||' ','TX'),
    ('owner',batch,'TX'),('owner',batch,'FL'),('vivid_life',batch||'_other','TX');
  insert into public.leads(division,lead_type,state,status,assigned_to) values('vivid_life',batch,'TX','assigned',agent_id);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',agent_id,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  insert into public.lead_requests(lead_type,quantity) values(batch,10) returning id into request_id;
  insert into public.lead_requests(lead_type,quantity) values(batch||'_missing',10) returning id into missing_id;
  insert into public.lead_requests(lead_type,quantity) values(batch,10) returning id into done_id;
  begin perform public.lead_request_availability(array[request_id]);raise exception 'TEST agent read admin stock';
  exception when insufficient_privilege then null;end;
  execute 'reset role';
  update public.lead_requests set fulfilled_quantity=2 where id=request_id;
  update public.lead_requests set status='completed' where id=done_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',other_admin,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  result:=public.lead_request_availability(array[request_id,missing_id,gen_random_uuid()]);
  if result<>'[]'::jsonb then raise exception 'Unauthorized request stock leaked';end if;
  execute 'reset role';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal1')::text,true);
  execute 'set local role authenticated';
  begin perform public.lead_request_availability(array[request_id]);raise exception 'TEST AAL1 read stock';
  exception when insufficient_privilege then null;end;
  execute 'reset role';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  result:=public.lead_request_availability(array[request_id,missing_id,done_id,gen_random_uuid()]);
  if jsonb_array_length(result)<>2 then raise exception 'Completed/unknown request included';end if;
  select x into rowdata from jsonb_array_elements(result) x where x->>'request_id'=request_id::text;
  if (rowdata->>'available')::int<>5 or (rowdata->>'remaining')::int<>8 or (rowdata->>'shortage')::int<>3
    or not (rowdata->>'can_deliver')::boolean or jsonb_array_length(rowdata->'sources')<>2 then
    raise exception 'Wrong normalized counts or partial shortage: %',rowdata;
  end if;
  if exists(select 1 from jsonb_array_elements(rowdata->'sources') x where x->>'source'='legacy_life') then raise exception 'Legacy stock leaked';end if;
  options:=public.lead_request_delivery_options(request_id);
  select sum((x->>'lead_count')::bigint) into exact_count from jsonb_array_elements(options->'inventory') x
    where lower(btrim(x->>'lead_type'))=lower(btrim(batch));
  if exact_count<>(rowdata->>'available')::bigint then raise exception 'Summary differs from delivery options';end if;
  select x into rowdata from jsonb_array_elements(result) x where x->>'request_id'=missing_id::text;
  if (rowdata->>'available')::int<>0 or (rowdata->>'shortage')::int<>10 then raise exception 'No-match shortage wrong';end if;
  if public.lead_request_availability('{}')<>'[]'::jsonb then raise exception 'Empty list failed';end if;
  begin perform public.lead_request_availability(array_fill(request_id,array[501]));raise exception 'TEST unbounded request list';
  exception when others then if sqlerrm<>'Check up to 500 requests at a time.' then raise;end if;end;
  execute 'reset role';
  update public.profiles set active=false where id=agent_id;
  execute 'set local role authenticated';
  rowdata:=public.lead_request_availability(array[request_id])->0;
  if (rowdata->>'can_deliver')::boolean or (rowdata->>'available')::int<>0 or rowdata->'sources'<>'[]'::jsonb then raise exception 'Inactive agent marked ready';end if;
  execute 'reset role';
  if has_function_privilege('anon','public.lead_request_availability(uuid[])','execute')
    or has_function_privilege('anon','private.lead_request_availability(uuid[])','execute') then raise exception 'Anonymous access enabled';end if;
end $$;
rollback;
select 'PASS: normalized matching, authorized sources, unassigned-only counts, partial shortages, missing/completed requests, inactive agents, MFA, role boundaries and bounded batch input' as result;
