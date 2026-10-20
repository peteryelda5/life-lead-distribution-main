-- All fixtures are rolled back, including auth users and callback tasks.
do $$
declare u uuid:=gen_random_uuid(); leader uuid:=gen_random_uuid(); peer uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid(); master_id uuid;
 sess uuid:=gen_random_uuid(); browser uuid:=gen_random_uuid(); lid uuid; other_lead uuid; callback_id uuid; task uuid; scheduled uuid:=gen_random_uuid(); batch uuid:=gen_random_uuid(); leg uuid:=gen_random_uuid();
 division_id text:='fixture_'||replace(gen_random_uuid()::text,'-',''); due_time timestamptz:=now()+interval '2 hours'; result jsonb; rejected boolean; actor uuid;
begin
 begin
  perform set_config('request.jwt.claims','{}',true);
  -- Read the existing Master only for scope assertions. Never create or modify
  -- a Master fixture: only_peter_master deliberately permits exactly one owner.
  select id into strict master_id from public.profiles where is_super_admin and role='admin' and active and not coalesce(archived,false);
  insert into public.divisions(id,name) values(division_id,'Workspace isolation fixture');
  foreach actor in array array[u,leader,peer,outsider,admin_id] loop
   insert into auth.users(id,email) values(actor,actor||'@example.invalid');
   insert into public.profiles(id,email,full_name,role,active,division,is_team_leader,is_super_admin)
   values(actor,actor||'@example.invalid','Workspace fixture',case when actor=admin_id then 'admin'::public.user_role else 'agent'::public.user_role end,true,case when actor=outsider then division_id else 'vivid_life' end,actor=leader,false)
   on conflict(id) do update set role=excluded.role,active=true,archived=false,division=excluded.division,is_team_leader=excluded.is_team_leader,is_super_admin=excluded.is_super_admin;
  end loop;
  update public.profiles set team_leader_id=leader where id=u;
  insert into auth.sessions(id,user_id,aal,created_at) values(sess,u,'aal2',now());
  insert into public.dialer_accounts(user_id,livemode,customer_id,subscription_id,subscription_status,paid_invoice,period_start,period_end,verified_at)
  values(u,true,'cus_fixture'||replace(u::text,'-',''),'sub_fixture'||replace(u::text,'-',''),'active',true,now()-interval '1 day',now()+interval '29 days',now());
  insert into public.dialer_numbers(user_id,livemode,slot,phone,state) values(u,true,1,'+12025550198','active');
  insert into public.leads(first_name,phone,division,status,assigned_to,call_notes) values('Owned fixture','+12025550194','vivid_life','assigned',u,'Keep these notes') returning id into lid;
  insert into public.leads(first_name,phone,division,status,assigned_to) values('Other fixture','+12025550194','vivid_life','assigned',peer) returning id into other_lead;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);set local role service_role;
  result:=public.dialer_workspace_presence(u,true,sess,browser,'idle',true,null);
  if result->>'mode'<>'ready' or (result->>'supervisor')::boolean then raise exception 'Agent capability incorrect';end if;
  perform public.dialer_workspace_presence(u,true,sess,browser,'idle',true,'break');
  -- A refreshed or older browser cannot silently overwrite Break with Ready.
  result:=public.dialer_workspace_presence(u,true,sess,gen_random_uuid(),'idle',true,null);
  if result->>'mode'<>'break' then raise exception 'Heartbeat overwrote Break';end if;
  rejected:=false;begin insert into public.dialer_parallel_sessions(id,user_id,session_id,provider_sid,caller_id) values(gen_random_uuid(),u,sess,'AC'||repeat('a',32),'+12025550198');exception when raise_exception then if sqlerrm not like 'Set your agent status%' then raise;end if;rejected:=true;end;
  if not rejected then raise exception 'Break allowed a new batch';end if;
  -- Even an old client advertising incoming availability must not ring while on Break.
  perform public.dialer_callback_presence(u,true,sess,browser,true,false);
  result:=public.dialer_callback_start(u,true,'AC'||repeat('a',32),'CA'||replace(gen_random_uuid()::text,'-',''),'+12025550194','+12025550198');
  callback_id:=(result->>'id')::uuid;if result->>'identity' is not null then raise exception 'Break rang incoming call';end if;
  update public.dialer_callbacks set seen_at=now() where id=callback_id;
  result:=public.dialer_priority_list(u,true);
  if (result->>'total')::integer<>1 or jsonb_array_length(result->'tasks'->0->'matches')<>1 or result->'tasks'->0->'matches'->0->>'id'<>lid::text then raise exception 'Missed callback matching leaked or lost a lead';end if;
  task:=(result->'tasks'->0->>'id')::uuid;
  rejected:=false;begin perform public.dialer_priority_resolve(peer,true,task);exception when raise_exception then rejected:=true;end;if not rejected then raise exception 'Foreign task resolved';end if;
  perform public.dialer_priority_resolve(u,true,task);
  if (public.dialer_priority_list(u,true)->>'total')::integer<>0 then raise exception 'Resolved callback reappeared';end if;
  perform public.dialer_workspace_presence(u,true,sess,browser,'idle',true,'ready');
  insert into public.dialer_parallel_sessions(id,user_id,session_id,provider_sid,caller_id,state,kind) values(batch,u,sess,'AC'||repeat('a',32),'+12025550198','complete','leads');
  insert into public.dialer_parallel_legs(id,session_id,position,lead_id,phone,rate,state,outcome,terminal) values(leg,batch,1,lid,'+12025550194',.014,'completed','second_answer',true);
  result:=public.dialer_priority_list(u,true);if (result->>'due')::integer<>1 then raise exception 'Power follow-up absent';end if;
  perform public.dialer_priority_list(u,true);if (select count(*) from public.dialer_priority_tasks where user_id=u and source='power')<>1 then raise exception 'Repeated sync duplicated follow-up';end if;
  perform public.dialer_priority_schedule(u,true,scheduled,lid,due_time,'Call in two hours');
  perform public.dialer_priority_schedule(u,true,scheduled,lid,due_time,'Call in two hours');
  result:=public.dialer_priority_list(u,true);if (result->>'total')::integer<>2 or (result->>'due')::integer<>1 then raise exception 'Scheduled callback lost or due early';end if;
  rejected:=false;begin perform public.dialer_priority_schedule(u,true,gen_random_uuid(),other_lead,due_time,'Wrong owner');exception when raise_exception then rejected:=true;end;if not rejected then raise exception 'Foreign lead scheduled';end if;
  if (public.dialer_priority_list(u,false)->>'total')::integer<>0 then raise exception 'Test/live data mixed';end if;
  if exists(select 1 from private.dialer_workspace_scope(leader) x where x in(peer,outsider,admin_id,master_id)) or not exists(select 1 from private.dialer_workspace_scope(leader) x where x=u) then raise exception 'Leader scope incorrect';end if;
  if exists(select 1 from private.dialer_workspace_scope(admin_id) x where x=outsider) or not exists(select 1 from private.dialer_workspace_scope(master_id) x where x=outsider) then raise exception 'Admin/master scope incorrect';end if;
  rejected:=false;begin perform public.dialer_supervisor_workspace(u,true);exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Agent read supervisor view';end if;
  perform public.dialer_workspace_presence(u,true,sess,browser,'wrap',true,null);
  result:=public.dialer_supervisor_workspace(leader,true);
  if not exists(select 1 from jsonb_array_elements(result->'agents') a where a->>'id'=u::text and a->>'state'='wrap') then raise exception 'Wrap state absent';end if;
  update public.dialer_agent_presence set updated_at=now()-interval '1 minute' where user_id=u;
  result:=public.dialer_supervisor_workspace(leader,true);
  if not exists(select 1 from jsonb_array_elements(result->'agents') a where a->>'id'=u::text and a->>'state'='offline') then raise exception 'Stale presence shown online';end if;
  update public.leads set assigned_to=peer where id=lid;
  if (public.dialer_priority_list(u,true)->>'total')::integer<>0 then raise exception 'Transferred lead retained in old owner queue';end if;
  reset role;set local role authenticated;
  rejected:=false;begin perform 1 from public.dialer_priority_tasks;exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Task table exposed';end if;
  rejected:=false;begin perform public.dialer_supervisor_workspace(master_id,true);exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Client bypassed supervisor authentication';end if;
  reset role;raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id=u) or exists(select 1 from public.divisions where id=division_id) then raise exception 'Fixtures persisted';end if;
end $$;
select 'PASS: status persistence, stale presence, server Break guard, incoming voicemail routing, owned lead matching, callback persistence/idempotency, scheduled due times, reassignment, team/admin/master scope, private permissions, full rollback.' as result;
