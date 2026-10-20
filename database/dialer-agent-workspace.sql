-- Agent operations are service-only. The endpoint authenticates an active MFA session.
create table public.dialer_agent_preferences (
 user_id uuid not null references public.profiles(id),livemode boolean not null,
 mode text not null default 'ready' check(mode in ('ready','break','offline')),
 updated_at timestamptz not null default now(),primary key(user_id,livemode)
);
create table public.dialer_agent_presence (
 user_id uuid not null references public.profiles(id),livemode boolean not null,browser_id uuid not null,session_id uuid not null,
 activity text not null check(activity in ('idle','dialing','on_call','wrap')),
 visible boolean not null,updated_at timestamptz not null default now(),primary key(user_id,livemode,browser_id)
);
create table public.dialer_priority_tasks (
 id uuid primary key default gen_random_uuid(),user_id uuid not null references public.profiles(id),livemode boolean not null,
 source text not null check(source in ('incoming','power','scheduled')),source_id uuid not null,
 lead_id uuid references public.leads(id) on delete set null,phone text,
 reason text not null,note text not null default '',due_at timestamptz not null,created_at timestamptz not null default now(),resolved_at timestamptz,
 unique(user_id,livemode,source,source_id)
);
create index dialer_priority_open on public.dialer_priority_tasks(user_id,livemode,due_at,id) where resolved_at is null;
create index dialer_presence_recent on public.dialer_agent_presence(user_id,livemode,updated_at desc);
create index dialer_parallel_followups on public.dialer_parallel_legs(session_id) where outcome in ('second_answer','answer_unconfirmed','answered_not_connected');
do $$ declare t text;begin
 foreach t in array array['dialer_agent_preferences','dialer_agent_presence','dialer_priority_tasks'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select,insert,update,delete on public.%I to service_role',t);
  execute format('create policy %I on public.%I for all to service_role using(true) with check(true)',t||'_service',t);
 end loop;
end $$;

-- The authenticated server reads explicit agency grants when scoping supervisors.
-- Keep browser roles excluded and preserve SECURITY INVOKER on the scope helper.
grant select on private.admin_division_access to service_role;
create function private.dialer_workspace_scope(p_user uuid) returns setof uuid language sql stable security invoker set search_path='' as $$
 select p.id from public.profiles actor join public.profiles p on p.active and not coalesce(p.archived,false) and p.role in ('admin','agent')
 where actor.id=p_user and actor.active and not coalesce(actor.archived,false) and (
  p.id=actor.id or
  (actor.role='admin' and (actor.is_super_admin or exists(select 1 from public.divisions d where d.id=p.division and not d.archived
    and (p.division=actor.division or exists(select 1 from private.admin_division_access g where g.user_id=actor.id and g.division=p.division))))) or
  (actor.role='agent' and actor.is_team_leader and p.role='agent' and p.team_leader_id=actor.id and p.division=actor.division)
 );
$$;
create function public.dialer_workspace_presence(p_user uuid,p_live boolean,p_session uuid,p_browser uuid,p_activity text,p_visible boolean,p_mode text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare chosen text; supervisor boolean;
begin
 if not private.dialer_session_active(p_user,p_session) or p_browser is null or p_activity is null or p_activity not in ('idle','dialing','on_call','wrap') or p_visible is null or (p_mode is not null and p_mode not in ('ready','break','offline')) then raise exception 'Invalid agent status or expired session';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 insert into public.dialer_agent_preferences(user_id,livemode) values(p_user,p_live) on conflict do nothing;
 if p_mode is not null then
  update public.dialer_agent_preferences set mode=p_mode,updated_at=now() where user_id=p_user and livemode=p_live;
  if p_mode<>'ready' then update public.dialer_incoming_presence set busy=true,ready_until=now() where user_id=p_user and livemode=p_live;end if;
 end if;
 select mode into chosen from public.dialer_agent_preferences where user_id=p_user and livemode=p_live;
 insert into public.dialer_agent_presence(user_id,livemode,browser_id,session_id,activity,visible)
 values(p_user,p_live,p_browser,p_session,p_activity,p_visible)
 on conflict(user_id,livemode,browser_id) do update set session_id=excluded.session_id,activity=excluded.activity,visible=excluded.visible,updated_at=now();
 delete from public.dialer_agent_presence where user_id=p_user and updated_at<now()-interval '1 day';
 select role='admin' or is_team_leader into supervisor from public.profiles where id=p_user and active and not coalesce(archived,false);
 return jsonb_build_object('mode',chosen,'supervisor',coalesce(supervisor,false),'updatedAt',now());
end $$;

-- Serialize against Ready/Break changes and existing inbound/outbound locks.
create function private.dialer_agent_start_guard() returns trigger language plpgsql security invoker set search_path='' as $$
declare live boolean;
begin
 live:=case when tg_table_name='dialer_calls' then (to_jsonb(new)->>'livemode')::boolean else true end;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||new.user_id::text,0));
 if exists(select 1 from public.dialer_agent_preferences where user_id=new.user_id and livemode=live and mode<>'ready') then
  raise exception 'Set your agent status to Ready before placing a call.' using errcode='P0001';
 end if;
 return new;
end $$;
create trigger dialer_agent_start_guard before insert on public.dialer_calls for each row execute function private.dialer_agent_start_guard();
create trigger dialer_agent_start_guard before insert on public.dialer_parallel_sessions for each row execute function private.dialer_agent_start_guard();

create function private.dialer_priority_sync(p_user uuid,p_live boolean) returns void language plpgsql security invoker set search_path='' as $$
begin
 insert into public.dialer_priority_tasks(user_id,livemode,source,source_id,phone,reason,due_at,created_at)
 select c.user_id,c.livemode,'incoming',c.id,c.caller_phone,case when c.status='voicemail' then 'Voicemail callback' else 'Missed inbound call' end,c.created_at,c.created_at
 from public.dialer_callbacks c where c.user_id=p_user and c.livemode=p_live
 and (c.status in ('missed','voicemail') or (c.status='ringing' and c.created_at<now()-interval '45 seconds'))
 on conflict(user_id,livemode,source,source_id) do update set reason=excluded.reason where dialer_priority_tasks.reason is distinct from excluded.reason;
 -- If a delayed provider event confirms an incoming call was answered, it is not a missed callback.
 update public.dialer_priority_tasks t set resolved_at=now() from public.dialer_callbacks c
 where t.user_id=p_user and t.livemode=p_live and t.source='incoming' and t.source_id=c.id and c.status='answered' and t.resolved_at is null;
 if p_live then
  insert into public.dialer_priority_tasks(user_id,livemode,source,source_id,lead_id,phone,reason,due_at,created_at)
  select s.user_id,true,'power',l.id,l.lead_id,l.phone,
   case l.outcome when 'answer_unconfirmed' then 'Pickup unconfirmed — review and follow up' else 'Answered without agent — follow-up needed' end,
   s.created_at,s.created_at
  from public.dialer_parallel_sessions s join public.dialer_parallel_legs l on l.session_id=s.id
  where s.user_id=p_user and s.kind='leads' and l.outcome in ('second_answer','answer_unconfirmed','answered_not_connected')
  on conflict(user_id,livemode,source,source_id) do nothing;
 end if;
end $$;
create function public.dialer_priority_list(p_user uuid,p_live boolean) returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 perform private.dialer_priority_sync(p_user,p_live);
 with eligible as (
  select t.* from public.dialer_priority_tasks t where t.user_id=p_user and t.livemode=p_live and t.resolved_at is null
  and (t.source='incoming' or exists(select 1 from public.leads l where l.id=t.lead_id and l.assigned_to=p_user and l.status='assigned'))
 ), page as (select * from eligible order by (due_at<=now()) desc,due_at,id limit 50)
 select jsonb_build_object('total',(select count(*) from eligible),'due',(select count(*) from eligible where due_at<=now()),'tasks',coalesce((select jsonb_agg(to_jsonb(x) order by x.due_at,x.id) from (
  select p.id,p.source,p.source_id,p.phone,p.reason,p.note,p.due_at,p.created_at,
   coalesce((select jsonb_agg(to_jsonb(l)) from (
    select l.id,l.first_name,l.last_name,l.phone,l.email,l.state,l.lead_type,l.agent_status,l.call_notes,l.csv_headers,l.csv_values
    from public.leads l where l.assigned_to=p_user and l.status='assigned' and (
     (p.source<>'incoming' and l.id=p.lead_id) or (p.source='incoming' and private.dialer_callback_phone(l.phone,to_jsonb(l.csv_headers),to_jsonb(l.csv_values))=p.phone))
    order by l.id limit 20) l),'[]'::jsonb) matches
  from page p) x),'[]'::jsonb)) into result;
 return result;
end $$;
create function public.dialer_priority_schedule(p_user uuid,p_live boolean,p_id uuid,p_lead uuid,p_due timestamptz,p_note text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare phone text; existing public.dialer_priority_tasks%rowtype;
begin
 if p_due is null or p_due<now()-interval '1 minute' or p_due>now()+interval '366 days' or p_note is null or length(p_note)>1000 or p_id is null then raise exception 'Choose a callback time within the next year.';end if;
 select private.dialer_callback_phone(l.phone,to_jsonb(l.csv_headers),to_jsonb(l.csv_values)) into phone from public.leads l where id=p_lead and assigned_to=p_user and status='assigned' for share;
 if not found then raise exception 'This lead is no longer assigned to you.';end if;
 insert into public.dialer_priority_tasks(id,user_id,livemode,source,source_id,lead_id,phone,reason,note,due_at)
 values(p_id,p_user,p_live,'scheduled',p_id,p_lead,phone,'Scheduled callback',p_note,p_due) on conflict(id) do nothing;
 select * into existing from public.dialer_priority_tasks where id=p_id;
 if existing.user_id<>p_user or existing.livemode<>p_live or existing.source<>'scheduled' or existing.lead_id is distinct from p_lead or existing.due_at<>p_due or existing.note<>p_note then raise exception 'This callback request has already been used. Refresh and try again.';end if;
 return jsonb_build_object('saved',true,'id',p_id);
end $$;
create function public.dialer_priority_resolve(p_user uuid,p_live boolean,p_id uuid) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 update public.dialer_priority_tasks t set resolved_at=coalesce(resolved_at,now()) where t.id=p_id and t.user_id=p_user and t.livemode=p_live
 and (t.source='incoming' or exists(select 1 from public.leads l where l.id=t.lead_id and l.assigned_to=p_user and l.status='assigned'));
 if not found then raise exception 'This callback is no longer available to you.';end if;
 return jsonb_build_object('saved',true);
end $$;

create function public.dialer_supervisor_workspace(p_user uuid,p_live boolean) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; day_start timestamptz:=(date_trunc('day',now() at time zone 'America/New_York') at time zone 'America/New_York');
begin
 if not exists(select 1 from public.profiles where id=p_user and active and not coalesce(archived,false) and (role='admin' or (role='agent' and is_team_leader))) then raise exception 'Supervisor access required' using errcode='42501';end if;
 select jsonb_build_object('updatedAt',now(),'dayStart',day_start,'agents',coalesce(jsonb_agg(to_jsonb(x) order by x.full_name,x.id),'[]'::jsonb)) into result from (
  select p.id,p.full_name,coalesce(agency.name,'Unknown agency') as division,
   case when coalesce(live_power.state,'')='connected' or inbound.active then 'on_call'
    when live_power.state is not null or calls.active then 'dialing'
    when presence.browser_id is null then 'offline'
    when presence.activity in ('on_call','dialing','wrap') then presence.activity
    when coalesce(prefs.mode,'ready')<>'ready' then prefs.mode else 'ready' end state,
   prefs.mode requested_mode,presence.updated_at last_seen,
   coalesce(calls.attempts,0) attempts,coalesce(calls.seconds,0) call_seconds,coalesce(calls.errors,0) errors,
   coalesce(power.conversations,0) power_conversations,coalesce(inbound.missed,0) missed_callbacks
  from private.dialer_workspace_scope(p_user) scoped(id) join public.profiles p on p.id=scoped.id
  left join public.divisions agency on agency.id=p.division
  left join public.dialer_agent_preferences prefs on prefs.user_id=p.id and prefs.livemode=p_live
  left join lateral (select a.* from public.dialer_agent_presence a where a.user_id=p.id and a.livemode=p_live and a.visible
   and a.updated_at>now()-interval '50 seconds' and private.dialer_session_active(a.user_id,a.session_id)
   order by case a.activity when 'on_call' then 0 when 'dialing' then 1 when 'wrap' then 2 else 3 end,a.updated_at desc limit 1) presence on true
  left join lateral (select s.state from public.dialer_parallel_sessions s where p_live and s.user_id=p.id and s.state<>'complete' and s.expires_at>now() order by s.created_at desc limit 1) live_power on true
  left join lateral (select count(*) filter(where c.parent_sid is not null and c.created_at>=day_start) attempts,
   coalesce(sum(c.duration_seconds) filter(where c.created_at>=day_start),0) seconds,
   count(*) filter(where c.call_status='failed' and c.created_at>=day_start) errors,
   coalesce(bool_or(not c.finished and ((c.parent_sid is not null and c.created_at>now()-interval '35 minutes') or c.expires_at>now())),false) active
   from public.dialer_calls c where c.user_id=p.id and c.livemode=p_live and c.created_at>=least(day_start,now()-interval '40 minutes')) calls on true
  left join lateral (select count(*) conversations from public.dialer_parallel_sessions s where p_live and s.user_id=p.id and s.kind='leads' and s.created_at>=day_start and s.winner_id is not null) power on true
  left join lateral (select count(*) filter(where (c.status in ('missed','voicemail') or (c.status='ringing' and c.created_at<now()-interval '45 seconds'))
    and not exists(select 1 from public.dialer_priority_tasks t where t.user_id=p.id and t.livemode=p_live and t.source='incoming' and t.source_id=c.id and t.resolved_at is not null)) missed,
    coalesce(bool_or(c.status='answered' and c.completed_at is null and c.created_at>now()-interval '35 minutes'),false) active
   from public.dialer_callbacks c where c.user_id=p.id and c.livemode=p_live) inbound on true
 ) x;
 return result;
end $$;
do $$ declare f record;begin
 for f in select oid::regprocedure fn from pg_proc where pronamespace in ('public'::regnamespace,'private'::regnamespace) and proname in
 ('dialer_workspace_scope','dialer_workspace_presence','dialer_agent_start_guard','dialer_priority_sync','dialer_priority_list','dialer_priority_schedule','dialer_priority_resolve','dialer_supervisor_workspace') loop
  execute 'revoke all on function '||f.fn||' from public,anon,authenticated';
  execute 'grant execute on function '||f.fn||' to service_role';
 end loop;
end $$;
