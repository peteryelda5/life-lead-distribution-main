-- Recovery only. All account/payment fixtures roll back; no provider operations.
begin;
do $$
declare u uuid; sid uuid; owner uuid; test_id uuid:=gen_random_uuid(); result jsonb; leg uuid;
 account text:='AC'||repeat('d',32); caller text:='+12025550777'; other_phone text:='+12025550778';
begin
 select p.id,s.id into u,sid from public.dialer_at_cost b join public.profiles p on p.id=b.user_id join auth.sessions s on s.user_id=p.id where p.active and not p.archived and p.role::text=b.required_role limit 1;
 select id into owner from public.profiles where is_super_admin and active and not archived limit 1;
 if u is null then raise exception 'Missing actual-cost session fixture';end if;
 update public.dialer_at_cost set enabled=true,provider_sid=account,provider_secret_cipher='fixture' where user_id=u;
 insert into public.dialer_accounts(user_id,livemode,customer_id,subscription_status,period_start,period_end,verified_at) values(u,true,'cus_parallelfixture','at_cost',now()-interval '1 day',now()+interval '1 day',now())
 on conflict(user_id,livemode) do update set subscription_status='at_cost',subscription_id=null,period_start=excluded.period_start,period_end=excluded.period_end,verified_at=now();
 update public.dialer_calls set finished=true where user_id=u;
 update public.dialer_callbacks set completed_at=now() where user_id=u;
 delete from public.dialer_parallel_legs where session_id in(select id from public.dialer_parallel_sessions where user_id=u);
 delete from public.dialer_parallel_sessions where user_id=u;
 insert into public.dialer_numbers(user_id,livemode,slot,phone,state) values(u,true,3,caller,'active') on conflict(user_id,livemode,slot) do update set phone=excluded.phone,state='active';
 if not public.dialer_parallel_allowed(u) or not public.dialer_parallel_can_call(u,account) then raise exception 'Eligible account denied';end if;
 if public.dialer_parallel_can_call(u,'AC'||repeat('a',32)) then raise exception 'Wrong billing account authorized';end if;
 update public.dialer_accounts set subscription_status='at_cost_pending' where user_id=u and livemode;
 if not public.dialer_parallel_allowed(u) or public.dialer_parallel_can_call(u,account) then raise exception 'Missing payment gate bypassed';end if;
 update public.dialer_accounts set subscription_status='at_cost',subscription_id='sub_fixture' where user_id=u and livemode;
 if public.dialer_parallel_allowed(u) then raise exception 'Paid subscription included';end if;
 update public.dialer_accounts set subscription_id=null where user_id=u and livemode;
 update public.dialer_at_cost set required_role=case required_role when 'admin' then 'agent' else 'admin' end where user_id=u;
 if public.dialer_parallel_allowed(u) then raise exception 'Role mismatch included';end if;
 update public.dialer_at_cost set required_role=(select role::text from public.profiles where id=u),provider_secret_cipher=null where user_id=u;
 if public.dialer_parallel_can_call(u,account) then raise exception 'Unprovisioned account allowed';end if;
 update public.dialer_at_cost set provider_secret_cipher='fixture' where user_id=u;
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);execute 'set local role service_role';
 begin perform public.dialer_parallel_prepare(u,sid,test_id,account,other_phone,array[caller],array[0.014]);raise exception 'TEST Other caller ID allowed';exception when raise_exception then if sqlerrm<>'Select your active caller ID.' then raise;end if;end;
 perform public.dialer_parallel_prepare(u,sid,test_id,account,caller,array[other_phone],array[0.014]);
 perform public.dialer_parallel_event(test_id,'agent',null,'CA'||repeat('b',32));perform public.dialer_parallel_event(test_id,'ready',null,'CA'||repeat('b',32),'CF'||repeat('b',32));
 result:=public.dialer_parallel_event(test_id,'launch');if result->>'result'<>'launch' then raise exception 'Actual-cost launch failed';end if;
 select id into leg from public.dialer_parallel_legs where session_id=test_id;
 perform public.dialer_parallel_event(test_id,'claim',leg);
 execute 'reset role';update public.dialer_at_cost set enabled=false where user_id=u;execute 'set local role service_role';
 result:=public.dialer_parallel_event(test_id,'answer',leg,'CA'||repeat('e',32),'human');if result->>'result'<>'stopped' then raise exception 'Revoked account connected';end if;
 perform public.dialer_parallel_event(test_id,'stop');perform public.dialer_parallel_event(test_id,'complete');
 execute 'reset role';execute 'set local role authenticated';
 begin perform public.dialer_parallel_allowed(u);raise exception 'TEST Client access to authorization RPC';exception when insufficient_privilege then null;end;
 execute 'reset role';
end $$;
select 'PASS: actual-cost permission, payment, role, provider and caller-ID gates; revocation stops calls; service-only RPC.' result;
rollback;
