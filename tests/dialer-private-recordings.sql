begin;
do $$
declare actor uuid; sess uuid; other_user uuid; batch uuid:=gen_random_uuid(); rec uuid:=gen_random_uuid(); result jsonb;
begin
 select p.id,s.id into actor,sess from public.profiles p join auth.sessions s on s.user_id=p.id where p.role='agent' and not p.is_team_leader and p.active and not p.archived limit 1;
 select id into other_user from public.profiles where id<>actor and active and not archived limit 1;
 if actor is null or sess is null then raise exception 'Missing session fixture';end if;
 insert into public.dialer_parallel_sessions(id,user_id,session_id,provider_sid,caller_id,expires_at,state,kind)
 values(batch,other_user,gen_random_uuid(),'AC'||repeat('a',32),'+12025550123',now()+interval '10 minutes','complete','leads');
 insert into public.dialer_private_recordings(id,user_id,power_id,phone,client_name,provider_sid,call_sid,grant_hash)
 values(rec,other_user,batch,'+12025550123','Test','AC'||repeat('a',32),'CA'||repeat('b',32),repeat('0',64));
 perform set_config('role','service_role',true);
 result:=public.dialer_recordings_access(actor,sess);
 if result @> jsonb_build_array(jsonb_build_object('id',rec)) then raise exception 'Other agent audio leaked';end if;
 begin perform public.dialer_recordings_access(actor,sess,rec);raise exception 'Other agent playback allowed';exception when insufficient_privilege then null;end;
 begin perform public.dialer_recordings_access(actor,gen_random_uuid());raise exception 'Invalid session allowed';exception when insufficient_privilege then null;end;
 update public.dialer_private_recordings set user_id=actor where id=rec;
 result:=public.dialer_recordings_access(actor,sess,rec);if result->>'id'<>rec::text then raise exception 'Own recording unavailable';end if;
 perform set_config('role','postgres',true);
 if has_table_privilege('authenticated','public.dialer_private_recordings','select') or has_table_privilege('anon','public.dialer_recording_parts','select') or has_function_privilege('authenticated','public.dialer_recordings_access(uuid,uuid,uuid)','execute') then raise exception 'Browser can bypass audio authorization';end if;
 if exists(select 1 from storage.buckets where id='dialer-recordings' and public) then raise exception 'Public recording bucket';end if;
 if not exists(select 1 from pg_policies where schemaname='storage' and policyname='dialer_recordings_no_browser' and permissive='RESTRICTIVE') then raise exception 'Missing private storage guard';end if;
end $$;
rollback;
