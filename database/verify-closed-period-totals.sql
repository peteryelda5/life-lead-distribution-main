do $$
declare aid uuid:=gen_random_uuid(); m uuid; today date:=(now() at time zone 'America/Detroit')::date; r jsonb; k text; n integer; d date; denied boolean;
begin
 select id into m from public.profiles where is_super_admin and active;
 begin
 perform set_config('request.jwt.claims','{}',true);
 insert into auth.users(id,email) values(aid,aid||'@example.invalid');
 insert into public.profiles(id,email,full_name,role,active,division) values(aid,aid||'@example.invalid','Period Fixture','agent',true,'vivid_life') on conflict(id) do update set role='agent',active=true,division='vivid_life';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
 insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date)
 select aid,'Fixture Carrier','Term',100,day from unnest(array[today,today-1,today-8,today-40]) day;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',aid,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 r:=public.closed_period_totals(null);
 if (r->'all'->>'count')::int<>4 or (r->'all'->>'monthly_premium')::numeric<>400 then raise exception 'Agent totals or isolation failed';end if;
 foreach k in array array['today','week','month'] loop
 select count(*) into n from unnest(array[today,today-1,today-8,today-40]) day where day>=(r->k->>'start_date')::date and day<(r->k->>'end_date')::date;
 if (r->k->>'count')::int<>n then raise exception 'Period count failed: %',k;end if;
 end loop;
 if (r->'week'->>'start_date')::date<>date_trunc('week',today::timestamp)::date then raise exception 'Week boundary failed';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',aid,'role','authenticated','aal','aal1')::text,true);
 set local role authenticated;
 denied:=false;begin r:=public.closed_period_totals(null);exception when insufficient_privilege then denied:=true;end;if not denied and (r->'all'->>'count')::int<>0 then raise exception 'MFA bypass';end if;
 reset role;
 raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id=aid) then raise exception 'Fixture persisted';end if;
end $$;
