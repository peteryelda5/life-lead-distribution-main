-- Recovery only. Synthetic data and all number changes roll back. No provider calls.
begin;
do $$
declare u uuid:=gen_random_uuid(); other_user uuid:=gen_random_uuid(); auth_session uuid:=gen_random_uuid(); batch uuid:=gen_random_uuid();
 lead_ids uuid[]:='{}'; l uuid; n integer; pool uuid:=gen_random_uuid(); chosen text[]; before_choice text; result jsonb; rejected boolean;
 phones text[]:=array['+12025550194','+12025550195','+12025550196']; caller text:='+12025550198'; account text:='AC'||repeat('a',32);
begin
  perform set_config('request.jwt.claims','{}',true);
  insert into auth.users(id,email) values(u,u||'@example.invalid'),(other_user,other_user||'@example.invalid');
  insert into public.profiles(id,email,full_name,role,active,division) values(u,u||'@example.invalid','Power Fixture','agent',true,'vivid_life'),(other_user,other_user||'@example.invalid','Other Fixture','admin',true,'vivid_life') on conflict(id) do update set role=excluded.role,active=true,archived=false,division=excluded.division;
  insert into auth.sessions(id,user_id,aal,created_at) values(auth_session,u,'aal2',now());
  insert into public.dialer_accounts(user_id,livemode,customer_id,subscription_id,subscription_status,paid_invoice,period_start,period_end,verified_at)
  values(u,true,'cus_fixture'||replace(u::text,'-',''),'sub_fixture'||replace(u::text,'-',''),'active',true,now()-interval '1 day',now()+interval '29 days',now());
  insert into public.dialer_periods(user_id,livemode,starts_at,ends_at,subscription_id,customer_id) select user_id,livemode,period_start,period_end,subscription_id,customer_id from public.dialer_accounts where user_id=u;
  insert into public.dialer_numbers(user_id,livemode,slot,phone,state) values(u,true,1,caller,'active');
  for n in 1..3 loop
   insert into public.leads(first_name,phone,division,status,assigned_to,call_notes,lead_type,agent_status) values('Power lead '||n,phones[n],'vivid_life','assigned',u,'Preserve original notes','Followup Fixture',case when n=2 then 'appointment_follow_up' else 'none' end) returning id into l;lead_ids:=array_append(lead_ids,l);
  end loop;

 insert into public.dialer_accounts(user_id,livemode,customer_id,subscription_status) values(other_user,true,'cus_fixture'||replace(other_user::text,'-',''),'active');
 insert into public.dialer_numbers(user_id,livemode,slot,phone,state) values(other_user,true,1,'+12025550199','active');
 insert into public.dialer_caller_pools(id,division,provider_sid,fallback_user,enabled) values(pool,'vivid_life',account,other_user,true);
 for n in 1..20 loop
  insert into public.dialer_pool_numbers(pool_id,slot,phone,provider_number_sid,state)
  values(pool,n,'+12025550'||lpad((100+n)::text,3,'0'),'PN'||lpad(n::text,32,'a'),'active');
 end loop;
 begin insert into public.dialer_pool_numbers(pool_id,slot,requested_area) values(pool,21,'202');raise exception '21st number allowed';exception when check_violation then null;end;
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);set local role service_role;
 result:=public.dialer_pool_options(u);if (result->>'count')::int<>20 then raise exception 'Pool count';end if;
 perform public.dialer_power_prepare_pool(u,auth_session,batch,account,caller,lead_ids,phones,array[.014,.014,.014],'human',pool);
 select array_agg(caller_id order by position) into chosen from public.dialer_parallel_legs where session_id=batch;
 if (select count(distinct x) from unnest(chosen)x)<>3 then raise exception 'Batch did not rotate';end if;
 if exists(select 1 from public.dialer_parallel_legs l join public.dialer_calls c on c.id=l.id where l.session_id=batch and l.caller_id<>c.caller_id) then raise exception 'Usage caller ID mismatch';end if;
 perform public.dialer_power_prepare_pool(u,auth_session,batch,account,caller,lead_ids,phones,array[.014,.014,.014],'human',pool);
 if chosen is distinct from (select array_agg(caller_id order by position) from public.dialer_parallel_legs where session_id=batch) then raise exception 'Retry rotated caller IDs';end if;
 if (select count(*) from public.dialer_pool_routes where user_id=u)<>3 then raise exception 'Duplicate routes';end if;
 result:=public.dialer_pool_callback_route(account,chosen[1],phones[1]);if result->>'userId'<>u::text or result->>'phone'<>caller then raise exception 'Wrong agent callback';end if;
 result:=public.dialer_pool_callback_route(account,chosen[1],'+12025550999');if result->>'userId'<>other_user::text then raise exception 'Unknown callback fallback';end if;
 rejected:=false;begin perform public.dialer_power_prepare_pool(other_user,auth_session,gen_random_uuid(),account,caller,lead_ids,phones,array[.014,.014,.014],'human',pool);exception when others then rejected:=true;end;if not rejected then raise exception 'Foreign session accepted';end if;
 update public.leads set assigned_to=other_user where id=lead_ids[1];
 result:=public.dialer_pool_callback_route(account,chosen[1],phones[1]);if result->>'userId'<>other_user::text then raise exception 'Reassigned lead leaked to old agent';end if;
 update public.leads set assigned_to=u where id=lead_ids[1];
 update public.dialer_caller_pools set enabled=false where id=pool;
 if public.dialer_pool_options(u) is not null then raise exception 'Disabled pool advertised';end if;
 result:=public.dialer_pool_callback_route(account,chosen[1],phones[1]);if result->>'userId'<>u::text then raise exception 'Disabling outbound broke callbacks';end if;
 update public.dialer_caller_pools set enabled=true where id=pool;
 perform public.dialer_parallel_event(batch,'stop');perform public.dialer_parallel_event(batch,'complete');
 before_choice:=chosen[1];batch:=gen_random_uuid();
 perform public.dialer_power_prepare_pool(u,auth_session,batch,account,caller,lead_ids[1:1],phones[1:1],array[.014],'human',pool);
 if (select caller_id from public.dialer_parallel_legs where session_id=batch)=before_choice then raise exception 'Repeat lead reused previous caller ID';end if;
 reset role;
 if has_table_privilege('authenticated','public.dialer_pool_routes','SELECT') or has_function_privilege('authenticated','public.dialer_pool_callback_route(text,text,text)','EXECUTE') then raise exception 'Browser has shared routing access';end if;
end $$;
select 'PASS: 20-number cap, agency selection, per-leg rotation, retry idempotency, ledger caller IDs, callback ownership/fallback/reassignment, disabled-pool callbacks, session isolation and private routes' result;
rollback;
