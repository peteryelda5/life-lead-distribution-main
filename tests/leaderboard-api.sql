-- All temporary credential records and usage counters roll back.
begin;
insert into private.leaderboard_api_keys(key_hash,label,scope_name,allowed_divisions)
values(repeat('a',64),'Transactional test only','Vivid Life',array['vivid_life']);
do $$
declare actual jsonb;expected jsonb;actual_rows jsonb;expected_rows jsonb;period text;month_date date;admin_id uuid;
begin
 if has_function_privilege('anon','public.leaderboard_api_read(text,text,date)','execute') or
    has_function_privilege('authenticated','public.leaderboard_api_read(text,text,date)','execute') or
    has_function_privilege('anon','private.leaderboard_api_read(text,text,date)','execute') or
    has_function_privilege('authenticated','private.leaderboard_api_read(text,text,date)','execute') then raise exception 'Untrusted role can call API RPC';end if;
 if has_table_privilege('anon','private.leaderboard_api_keys','select') or has_table_privilege('authenticated','private.leaderboard_api_keys','select') then raise exception 'Credential registry exposed';end if;
 if has_column_privilege('service_role','private.leaderboard_api_keys','allowed_divisions','update') or has_table_privilege('service_role','private.leaderboard_api_keys','insert') then raise exception 'Backend can change credential scope';end if;
 if (select not relrowsecurity from pg_class where oid='private.leaderboard_api_keys'::regclass) then raise exception 'RLS missing';end if;
 if exists(select 1 from pg_proc where oid in ('public.leaderboard_api_read(text,text,date)'::regprocedure,'private.leaderboard_api_read(text,text,date)'::regprocedure) and prosecdef) then raise exception 'Unexpected elevated function';end if;
 select id into strict admin_id from public.profiles where is_super_admin and active and not coalesce(archived,false) and role='admin' limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated')::text,true);
 foreach period in array array['today','week','month','previous'] loop
  month_date:=case when period='previous' then (date_trunc('month',now() at time zone 'America/Detroit')-interval '1 month')::date end;
  expected:=private.leaderboard_period('vivid_life',period,month_date);
  set local role service_role;
  actual:=public.leaderboard_api_read(repeat('a',64),period,month_date);
  reset role;
  if actual->>'status'<>'200' then raise exception 'Valid machine access failed: %',period;end if;
  select jsonb_agg(jsonb_build_object('agent_name',r->'agent_name','ap',r->'annual_premium','deals',r->'deals') order by ord) into actual_rows from jsonb_array_elements(actual->'data'->'rankings') with ordinality x(r,ord);
  select jsonb_agg(jsonb_build_object('agent_name',r->'agent_name','ap',r->'ap','deals',r->'deals') order by ord) into expected_rows from jsonb_array_elements(expected->'rankings') with ordinality x(r,ord);
  if actual_rows is distinct from expected_rows or actual->'data'->'totals'->'annual_premium' is distinct from expected->'period'->'ap' or actual->'data'->'totals'->'deals' is distinct from expected->'period'->'deals' then raise exception 'Portal calculation mismatch: %',period;end if;
  if exists(select 1 from jsonb_array_elements(actual->'data'->'rankings') r where (r->>'annual_premium')::numeric<>(r->>'recorded_annual_premium')::numeric+(r->>'imported_annual_premium_adjustment')::numeric) then raise exception 'AP inputs mismatch';end if;
 end loop;
 if public.leaderboard_api_read(repeat('b',64))->>'status'<>'401' then raise exception 'Unknown key accepted';end if;
 if public.leaderboard_api_read(repeat('a',64),'all')->>'status'<>'400' then raise exception 'Invalid period accepted';end if;
 if public.leaderboard_api_read(repeat('a',64),'previous',current_date+31)->>'status'<>'400' then raise exception 'Future month accepted';end if;
 update private.leaderboard_api_keys set revoked_at=now() where key_hash=repeat('a',64);
 if public.leaderboard_api_read(repeat('a',64))->>'status'<>'401' then raise exception 'Revoked key accepted';end if;
 update private.leaderboard_api_keys set revoked_at=null,expires_at=now()-interval '1 second' where key_hash=repeat('a',64);
 if public.leaderboard_api_read(repeat('a',64))->>'status'<>'401' then raise exception 'Expired key accepted';end if;
 update private.leaderboard_api_keys set expires_at=now()+interval '1 year',window_start=now(),window_count=59 where key_hash=repeat('a',64);
 if public.leaderboard_api_read(repeat('a',64))->>'status'<>'200' then raise exception '60th request denied';end if;
 if public.leaderboard_api_read(repeat('a',64))->>'status'<>'429' then raise exception 'Rate limit not enforced';end if;
 update private.leaderboard_api_keys set window_start=now()-interval '2 minutes' where key_hash=repeat('a',64);
 if public.leaderboard_api_read(repeat('a',64))->>'status'<>'200' then raise exception 'Rate limit did not reset';end if;
end $$;
rollback;
select 'PASS: role grants, scope immutability, RLS, service-role execution, exact portal parity for all four periods, unknown/revoked/expired keys, and per-key rate limit.' as result;
