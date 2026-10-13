-- Recovery only: rollback all fixtures; no provider operations.
begin;
do $$
declare u uuid; sid uuid; test_id uuid:=gen_random_uuid(); leg uuid; second_leg uuid; r jsonb;
 account text:='AC'||repeat('a',32); caller text:='+12025550666'; phones text[]:=array['+12025550667','+12025550668']; rates numeric[]:=array[0.014,0.014];
begin
 select p.id,s.id into u,sid from public.profiles p join auth.sessions s on s.user_id=p.id where p.is_super_admin and p.active and not p.archived limit 1;
 if u is null then raise exception 'Missing owner fixture';end if;
 update public.dialer_calls set finished=true where user_id=u;update public.dialer_callbacks set completed_at=now() where user_id=u;
 delete from public.dialer_parallel_legs where session_id in(select id from public.dialer_parallel_sessions where user_id=u);
 delete from public.dialer_parallel_sessions where user_id=u;
 insert into public.dialer_numbers(user_id,livemode,slot,phone,state) values(u,true,3,caller,'active') on conflict(user_id,livemode,slot) do update set phone=excluded.phone,state='active';
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);execute 'set local role service_role';
 perform public.dialer_parallel_prepare_mode(u,sid,test_id,account,caller,phones,rates,'fast');
 perform public.dialer_parallel_prepare_mode(u,sid,test_id,account,caller,phones,rates,'fast');
 if (select connect_mode from public.dialer_parallel_sessions where id=test_id)<>'fast' or (select count(*) from public.dialer_parallel_legs where session_id=test_id)<>2 then raise exception 'Preparation or mode persistence failed';end if;
 begin perform public.dialer_parallel_prepare_mode(u,sid,test_id,account,caller,phones,rates,'human');raise exception 'TEST Mode changed on retry';exception when raise_exception then if sqlerrm<>'Pilot preparation does not match this session.' then raise;end if;end;
 perform public.dialer_parallel_event(test_id,'agent',null,'CA'||repeat('b',32));perform public.dialer_parallel_event(test_id,'ready',null,'CA'||repeat('b',32),'CF'||repeat('b',32));perform public.dialer_parallel_event(test_id,'launch');
 select id into leg from public.dialer_parallel_legs where session_id=test_id and position=1;
 select id into second_leg from public.dialer_parallel_legs where session_id=test_id and position=2;
 perform public.dialer_parallel_event(test_id,'claim',leg);perform public.dialer_parallel_event(test_id,'claim',second_leg);
 r:=public.dialer_parallel_event(test_id,'answer',leg,'CA'||repeat('e',32),'human');if r->>'result'<>'ignored' then raise exception 'Fast mode accepted false human classification';end if;
 r:=public.dialer_parallel_event(test_id,'answer',leg,'CA'||repeat('e',32),'answered');if r->>'result'<>'winner' then raise exception 'First pickup was not connected';end if;
 r:=public.dialer_parallel_event(test_id,'answer',second_leg,'CA'||repeat('f',32),'answered');if r->>'result'<>'overflow' then raise exception 'Two callers connected';end if;
 perform public.dialer_parallel_event(test_id,'stop');r:=public.dialer_parallel_event(test_id,'answer',leg,'CA'||repeat('e',32),'answered');if r->>'result'<>'stopped' then raise exception 'Answer after stop';end if;
 perform public.dialer_parallel_event(test_id,'complete');
 test_id:=gen_random_uuid();perform public.dialer_parallel_prepare_mode(u,sid,test_id,account,caller,phones,rates,'human');
 perform public.dialer_parallel_event(test_id,'agent',null,'CA'||repeat('c',32));perform public.dialer_parallel_event(test_id,'ready',null,'CA'||repeat('c',32),'CF'||repeat('c',32));perform public.dialer_parallel_event(test_id,'launch');
 select id into leg from public.dialer_parallel_legs where session_id=test_id and position=1;perform public.dialer_parallel_event(test_id,'claim',leg);
 r:=public.dialer_parallel_event(test_id,'answer',leg,'CA'||repeat('d',32),'answered');if r->>'result'<>'ignored' then raise exception 'Filtering bypassed';end if;
 r:=public.dialer_parallel_event(test_id,'answer',leg,'CA'||repeat('d',32),'human',6226);if r->>'result'<>'winner' or (select detection_ms from public.dialer_parallel_legs where id=leg)<>6226 then raise exception 'Filtered result or timing lost';end if;
 execute 'reset role';execute 'set local role authenticated';
 begin perform public.dialer_parallel_prepare_mode(u,sid,test_id,account,caller,phones,rates,'fast');raise exception 'TEST Client access';exception when insufficient_privilege then null;end;
 execute 'reset role';
end $$;
select 'PASS: fast first-answer winner, mode isolation, replay safety, second-answer handling, stopped-call rejection, filtered timing and private RPC' result;
rollback;
