begin;
do $$
declare admin_id uuid; admin_session uuid; master_id uuid; master_session uuid; agent_id uuid; outsider uuid; batch uuid:=gen_random_uuid(); foreign_batch uuid:=gen_random_uuid(); m jsonb; ids jsonb; sid text:='CA'||replace(gen_random_uuid()::text,'-','');
begin
 perform set_config('request.jwt.claims','{}',true);
 select p.id,s.id into admin_id,admin_session from public.profiles p join auth.sessions s on s.user_id=p.id where p.role='admin' and not p.is_super_admin and p.active and not p.archived limit 1;
 select p.id,s.id into master_id,master_session from public.profiles p join auth.sessions s on s.user_id=p.id where p.is_super_admin and p.active and not p.archived limit 1;
 select p.id into agent_id from public.profiles p where p.role='agent' and p.id in(select private.dialer_workspace_scope(admin_id)) limit 1;
 select p.id into outsider from public.profiles p where p.role='agent' and p.active and not p.archived and p.id not in(select private.dialer_workspace_scope(admin_id)) limit 1;
 if agent_id is null or outsider is null then raise exception 'Missing scope fixtures';end if;
 insert into public.dialer_parallel_sessions(id,user_id,session_id,provider_sid,caller_id,expires_at,heartbeat_at,state,conference_sid,winner_id,kind)
 values(batch,agent_id,gen_random_uuid(),'AC'||repeat('a',32),'+12025550123',now()+interval '10 minutes',now(),'connected','CF'||replace(batch::text,'-',''),gen_random_uuid(),'leads'),
 (foreign_batch,outsider,gen_random_uuid(),'AC'||repeat('b',32),'+12025550124',now()+interval '10 minutes',now(),'connected','CF'||replace(foreign_batch::text,'-',''),gen_random_uuid(),'leads');
 perform set_config('role','service_role',true);
 ids:=public.dialer_monitor_manage('list',admin_id,admin_session);
 if not ids @> jsonb_build_array(jsonb_build_object('id',batch)) or ids @> jsonb_build_array(jsonb_build_object('id',foreign_batch)) then raise exception 'Agency scope leak';end if;
 ids:=public.dialer_monitor_manage('list',master_id,master_session);
 if not ids @> jsonb_build_array(jsonb_build_object('id',foreign_batch)) then raise exception 'Owner scope missing';end if;
 begin perform public.dialer_monitor_manage('prepare',admin_id,admin_session,foreign_batch);raise exception 'Foreign call allowed';exception when insufficient_privilege then null;end;
 begin perform public.dialer_monitor_manage('list',agent_id,admin_session);raise exception 'Agent allowed';exception when insufficient_privilege then null;end;
 m:=public.dialer_monitor_manage('prepare',admin_id,admin_session,batch);
 perform public.dialer_monitor_manage('consume',p_id:=(m->>'id')::uuid,p_sid:=sid);
 begin perform public.dialer_monitor_manage('consume',p_id:=(m->>'id')::uuid,p_sid:='CA'||repeat('f',32));raise exception 'Replay allowed';exception when insufficient_privilege then null;end;
 perform public.dialer_monitor_manage('heartbeat',admin_id,admin_session,p_id:=(m->>'id')::uuid);
 update public.dialer_live_monitors set heartbeat_at=now()-interval '60 seconds' where id=(m->>'id')::uuid;
 ids:=public.dialer_monitor_manage('cleanup');if not ids @> jsonb_build_array(jsonb_build_object('id',m->>'id')) then raise exception 'Abandoned listener not cleaned';end if;
 update public.dialer_parallel_sessions set state='complete' where id=batch;
 begin perform public.dialer_monitor_manage('heartbeat',admin_id,admin_session,p_id:=(m->>'id')::uuid);raise exception 'Ended call allowed';exception when insufficient_privilege then null;end;
 perform public.dialer_monitor_manage('finish',p_id:=(m->>'id')::uuid,p_sid:=sid);
 if not exists(select 1 from public.dialer_live_monitors where id=(m->>'id')::uuid and stopped_at is not null) then raise exception 'Listener not stopped';end if;
 perform set_config('role','postgres',true);
 if has_function_privilege('authenticated','public.dialer_monitor_manage(text,uuid,uuid,uuid,uuid,text,integer)','execute') or has_table_privilege('authenticated','public.dialer_live_monitors','select') then raise exception 'Browser can access listener grants';end if;
end $$;
rollback;
