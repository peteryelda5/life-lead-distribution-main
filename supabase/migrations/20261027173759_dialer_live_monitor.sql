-- Browser roles never receive monitor grants or provider identifiers directly.
create table public.dialer_live_monitors (
 id uuid primary key default gen_random_uuid(), actor_id uuid not null references public.profiles(id),
 actor_session uuid not null, power_id uuid not null references public.dialer_parallel_sessions(id),
 created_at timestamptz not null default now(), heartbeat_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '60 seconds',
 call_sid text unique, stopped_at timestamptz, duration_seconds integer not null default 0
);
alter table public.dialer_live_monitors enable row level security;
revoke all on public.dialer_live_monitors from public,anon,authenticated;
grant select,insert,update on public.dialer_live_monitors to service_role;
create policy dialer_live_monitors_service on public.dialer_live_monitors for all to service_role using(true) with check(true);
create index dialer_live_monitors_open on public.dialer_live_monitors(heartbeat_at) where stopped_at is null;
create function private.dialer_monitor_allowed(p_actor uuid,p_session uuid,p_power uuid) returns boolean
language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.profiles a join public.dialer_parallel_sessions s on s.id=p_power
 where a.id=p_actor and a.role='admin' and a.active and not coalesce(a.archived,false)
 and private.dialer_session_active(a.id,p_session)
 and s.user_id<>a.id and s.user_id in(select private.dialer_workspace_scope(a.id))
 and s.kind='leads' and s.state='connected' and s.conference_sid is not null and s.winner_id is not null
 and s.expires_at>now() and s.heartbeat_at>now()-interval '90 seconds');
$$;
revoke all on function private.dialer_monitor_allowed(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function private.dialer_monitor_allowed(uuid,uuid,uuid) to service_role;
create function public.dialer_monitor_manage(p_action text,p_actor uuid default null,p_session uuid default null,p_power uuid default null,p_id uuid default null,p_sid text default null,p_seconds integer default 0)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.dialer_live_monitors; result jsonb;
begin
 if p_action='cleanup' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (select mon.id,mon.power_id,mon.call_sid from public.dialer_live_monitors mon where mon.stopped_at is null and (mon.heartbeat_at<now()-interval '50 seconds' or not private.dialer_monitor_allowed(mon.actor_id,mon.actor_session,mon.power_id)) limit 100)x;return result;
 end if;
 if p_action='finish' then
  update public.dialer_live_monitors set stopped_at=coalesce(stopped_at,now()),duration_seconds=greatest(duration_seconds,least(greatest(p_seconds,0),3600)) where id=p_id and (call_sid=p_sid or (call_sid is null and p_sid is null));return jsonb_build_object('ok',true);
 end if;
 if p_action='consume' then
  select * into m from public.dialer_live_monitors where id=p_id for update;
  if not found or m.stopped_at is not null or m.expires_at<=now() or not private.dialer_monitor_allowed(m.actor_id,m.actor_session,m.power_id) or p_sid!~'^CA[0-9a-fA-F]{32}$' or p_sid is null or (m.call_sid is not null and m.call_sid<>p_sid) then raise exception 'Listening authorization expired' using errcode='42501';end if;
  update public.dialer_live_monitors set call_sid=p_sid,heartbeat_at=now() where id=m.id;
  return to_jsonb(m)||jsonb_build_object('call_sid',p_sid);
 end if;
 if not exists(select 1 from public.profiles where id=p_actor and role='admin' and active and not coalesce(archived,false)) or not private.dialer_session_active(p_actor,p_session) then raise exception 'Admin access required' using errcode='42501';end if;
 if p_action='list' then
  select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'agent',p.full_name,'startedAt',s.created_at) order by s.created_at),'[]') into result from public.dialer_parallel_sessions s join public.profiles p on p.id=s.user_id where private.dialer_monitor_allowed(p_actor,p_session,s.id);return result;
 elsif p_action='prepare' then
  perform pg_advisory_xact_lock(hashtextextended(p_actor::text,99121));
  if not private.dialer_monitor_allowed(p_actor,p_session,p_power) then raise exception 'Call ended or outside your agency' using errcode='42501';end if;
  if exists(select 1 from public.dialer_live_monitors where actor_id=p_actor and stopped_at is null and heartbeat_at>now()-interval '50 seconds') then raise exception 'Stop listening to the other call first';end if;
  insert into public.dialer_live_monitors(actor_id,actor_session,power_id) values(p_actor,p_session,p_power) returning * into m;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(p_actor,'live_listen_requested','dialer_parallel_session',p_power::text,jsonb_build_object('monitor_id',m.id,'mode','listen_only'));
  return to_jsonb(m);
 elsif p_action in ('heartbeat','stop') then
  select * into m from public.dialer_live_monitors where id=p_id and actor_id=p_actor and actor_session=p_session for update;
  if not found then raise exception 'Listener unavailable' using errcode='42501';end if;
  if p_action='heartbeat' then
   if m.stopped_at is not null or not private.dialer_monitor_allowed(p_actor,p_session,m.power_id) then raise exception 'Call ended or access changed' using errcode='42501';end if;
   update public.dialer_live_monitors set heartbeat_at=now() where id=m.id;
  end if;
  return to_jsonb(m);
 end if;
 raise exception 'Unknown listening action';
end $$;
revoke all on function public.dialer_monitor_manage(text,uuid,uuid,uuid,uuid,text,integer) from public,anon,authenticated;
grant execute on function public.dialer_monitor_manage(text,uuid,uuid,uuid,uuid,text,integer) to service_role;
notify pgrst,'reload schema';
