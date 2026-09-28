do $$
declare m uuid; scoped uuid; a uuid:=gen_random_uuid(); l uuid; o uuid; d uuid; r jsonb; denied boolean; t timestamptz;
begin
 select id into m from public.profiles where is_super_admin and active;
 select id into scoped from public.profiles where role='admin' and division='legacy_life' and active and not is_super_admin limit 1;
 begin
 perform set_config('request.jwt.claims','{}',true);
 insert into auth.users(id,email) values(a,'transfer-'||a||'@example.invalid');
 insert into public.profiles(id,email,full_name,role,active,division) values(a,'transfer-'||a||'@example.invalid','Transfer Fixture','agent',true,'legacy_life') on conflict(id) do update set role='agent',active=true,division='legacy_life';
 insert into public.leads(first_name,division,status,assigned_to) values('Closed Fixture','legacy_life','closed',a) returning id into l;
 insert into public.leads(first_name,division,status,assigned_to) values('Open Fixture','legacy_life','assigned',a) returning id into o;
 insert into public.closed_business(lead_id,agent_id,carrier,policy_type,monthly_premium,application_date) values(l,a,'Test','Term',100,current_date) returning id,created_at into d,t;
 insert into private.leaderboard_monthly_import(month,division,entry_key,agent_id,display_name,snapshot_ap,ap_adjustment) values(date '2026-09-01','legacy_life',a::text,a,'Transfer Fixture',1200,0);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',scoped,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 denied:=false;begin perform public.transfer_agent_division(a,'owner','legacy_life');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Scoped transfer escaped division';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 r:=public.transfer_agent_division(a,'owner','legacy_life');
 if (r->>'closed_leads_moved')::int<>1 or (r->>'reclaimed')::int<>1 or (r->>'deals_moved')::int<>1 then raise exception 'Incorrect counts %',r;end if;
 if not exists(select 1 from public.leads where id=l and division='owner' and status='closed' and assigned_to=a) then raise exception 'Closed lead not moved';end if;
 if not exists(select 1 from public.leads where id=o and division='legacy_life' and status='unassigned' and assigned_to is null) then raise exception 'Open lead did not stay';end if;
 if not exists(select 1 from public.closed_business where id=d and agent_id=a and created_at=t and annual_premium=1200) then raise exception 'Deal changed';end if;
 if not exists(select 1 from public.chat_messages where source_deal_id=d and division='owner') then raise exception 'Deal chat not moved';end if;
 reset role;
 if not exists(select 1 from private.leaderboard_monthly_import where agent_id=a and division='owner') then raise exception 'Import did not move';end if;
 raise exception using errcode='ZX001',message='Rollback verification';
 exception when sqlstate 'ZX001' then null;
 end;
 reset role;
 if exists(select 1 from auth.users where id=a) then raise exception 'Fixtures persisted';end if;
end $$;
