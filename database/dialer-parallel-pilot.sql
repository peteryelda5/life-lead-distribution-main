-- Owner-only, controlled-phone pilot. No lead campaigns or subscription changes.
create table public.dialer_parallel_sessions (
 id uuid primary key, user_id uuid not null references public.profiles(id), session_id uuid not null,
 provider_sid text not null check(provider_sid ~ '^AC[0-9a-fA-F]{32}$'), caller_id text not null,
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '4 minutes',
 heartbeat_at timestamptz not null default now(), stopped_at timestamptz,
 state text not null default 'prepared' check(state in ('prepared','ready','dialing','connected','stopping','complete')),
 agent_sid text unique check(agent_sid ~ '^CA[0-9a-fA-F]{32}$'), conference_sid text check(conference_sid ~ '^CF[0-9a-fA-F]{32}$'),
 winner_id uuid, reserved_cents integer not null default 50 check(reserved_cents=50), agent_seconds integer not null default 0
);
create table public.dialer_parallel_legs (
 id uuid primary key default gen_random_uuid(), session_id uuid not null references public.dialer_parallel_sessions(id),
 position integer not null check(position between 1 and 3), phone text not null, rate numeric not null check(rate>0 and rate<=0.014),
 provider_sid text unique check(provider_sid ~ '^CA[0-9a-fA-F]{32}$'),
 state text not null default 'prepared' check(state in ('prepared','creating','queued','ringing','in-progress','completed','busy','failed','no-answer','canceled')),
 answer text check(answer in ('human','machine','fax','unknown')), outcome text,
 duration_seconds integer not null default 0 check(duration_seconds between 0 and 600),
 price_usd numeric, detection_ms integer, terminal boolean not null default false,
 unique(session_id,position), unique(session_id,phone)
);
create index dialer_parallel_owner_created on public.dialer_parallel_sessions(user_id,created_at desc);
create index dialer_parallel_cleanup on public.dialer_parallel_sessions(expires_at) where state<>'complete';
alter table public.dialer_parallel_sessions enable row level security;
alter table public.dialer_parallel_legs enable row level security;
revoke all on public.dialer_parallel_sessions,public.dialer_parallel_legs from public,anon,authenticated;
grant select,insert,update,delete on public.dialer_parallel_sessions,public.dialer_parallel_legs to service_role;
create policy parallel_sessions_service on public.dialer_parallel_sessions for all to service_role using(true) with check(true);
create policy parallel_legs_service on public.dialer_parallel_legs for all to service_role using(true) with check(true);

create function public.dialer_parallel_prepare(p_user uuid,p_session uuid,p_id uuid,p_account text,p_caller text,p_phones text[],p_rates numeric[])
returns uuid language plpgsql security invoker set search_path='' as $$
declare n integer; existing public.dialer_parallel_sessions%rowtype;
begin
 if not private.dialer_session_active(p_user,p_session) or not exists(select 1 from public.profiles where id=p_user and is_super_admin and active and not archived and role='admin') then raise exception 'Owner pilot access required.';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 select * into existing from public.dialer_parallel_sessions where id=p_id;
 if found then
  if existing.user_id<>p_user or existing.session_id<>p_session then raise exception 'Pilot ownership mismatch.';end if;
  return p_id;
 end if;
 if coalesce(cardinality(p_phones),0) not between 1 and 3 or cardinality(p_rates) is distinct from cardinality(p_phones)
 or (select count(distinct phone) from unnest(p_phones) phone)<>cardinality(p_phones)
 or exists(select 1 from unnest(p_phones) phone where phone is null or phone !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$' or phone=p_caller)
 or exists(select 1 from unnest(p_rates) rate where rate is null or rate<=0 or rate>0.014) then raise exception 'Choose one to three distinct, standard-rate US test phones.';end if;
 if not (exists(select 1 from public.dialer_numbers where user_id=p_user and livemode and state='active' and phone=p_caller)
 or exists(select 1 from public.master_dialer_numbers where user_id=p_user and state='active' and phone_number=p_caller)) then raise exception 'Select an active owner caller ID.';end if;
 if exists(select 1 from public.dialer_parallel_sessions where user_id=p_user and state<>'complete' and expires_at>now())
 or exists(select 1 from public.dialer_calls where user_id=p_user and not finished and ((parent_sid is not null and created_at>now()-interval '35 minutes') or expires_at>now()))
 or exists(select 1 from public.dialer_callbacks where user_id=p_user and completed_at is null and ((status='ringing' and created_at>now()-interval '45 seconds') or (status='answered' and created_at>now()-interval '35 minutes'))) then raise exception 'Finish the current call or pilot first.';end if;
 if (select coalesce(sum(reserved_cents),0) from public.dialer_parallel_sessions where user_id=p_user and created_at>now()-interval '24 hours')+50>500 then raise exception 'Pilot allowance reached: ten tests per rolling 24 hours.';end if;
 insert into public.dialer_parallel_sessions(id,user_id,session_id,provider_sid,caller_id) values(p_id,p_user,p_session,p_account,p_caller);
 for n in 1..cardinality(p_phones) loop
  insert into public.dialer_parallel_legs(session_id,position,phone,rate) values(p_id,n,p_phones[n],p_rates[n]);
 end loop;
 return p_id;
end $$;

-- All events serialize on the session row: exactly one human can claim the browser.
create function public.dialer_parallel_event(p_id uuid,p_event text,p_leg uuid default null,p_sid text default null,p_value text default null,p_seconds integer default 0)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare s public.dialer_parallel_sessions%rowtype; l public.dialer_parallel_legs%rowtype; result text:='ignored';
begin
 select * into strict s from public.dialer_parallel_sessions where id=p_id for update;
 if p_event in ('claim','bind','answer','status') and p_leg is null then raise exception 'Pilot line required.';end if;
 if p_sid is not null and p_sid !~ '^CA[0-9a-fA-F]{32}$' then raise exception 'Invalid call identifier.';end if;
 if p_leg is not null then
  select * into strict l from public.dialer_parallel_legs where id=p_leg and session_id=p_id for update;
  if l.provider_sid is not null and p_sid is not null and l.provider_sid<>p_sid then raise exception 'Call identifier mismatch.';end if;
 end if;
 if p_event in ('agent','ready','launch','claim','answer') and (s.expires_at<=now() or s.heartbeat_at<now()-interval '35 seconds' or s.state in ('stopping','complete') or not private.dialer_session_active(s.user_id,s.session_id)) then return jsonb_build_object('result','stopped');end if;
 case p_event
 when 'agent' then
  if p_sid is null or (s.agent_sid is not null and s.agent_sid<>p_sid) or (s.agent_sid is null and s.created_at<now()-interval '60 seconds') then raise exception 'Pilot connection expired.';end if;
  update public.dialer_parallel_sessions set agent_sid=p_sid where id=p_id;result:='agent';
 when 'ready' then
  if p_sid is null or s.agent_sid is distinct from p_sid or p_value is null or p_value !~ '^CF[0-9a-fA-F]{32}$' or (s.conference_sid is not null and s.conference_sid<>p_value) then raise exception 'Conference ownership mismatch.';end if;
  if s.state='prepared' then update public.dialer_parallel_sessions set state='ready',conference_sid=p_value where id=p_id;end if;result:='ready';
 when 'launch' then
  if s.state='ready' then update public.dialer_parallel_sessions set state='dialing' where id=p_id;result:='launch';end if;
 when 'claim' then
  if s.state='dialing' and s.winner_id is null and l.state='prepared' then update public.dialer_parallel_legs set state='creating' where id=p_leg;result:='create';end if;
 when 'bind' then
  if p_sid is null then raise exception 'Call identifier required.';end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,state=case when state='creating' then 'queued' else state end where id=p_leg;result:='bound';
 when 'answer' then
  if p_sid is null or l.state='prepared' or l.terminal or p_value not in ('human','machine','fax','unknown') then return jsonb_build_object('result','ignored');end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,answer=coalesce(answer,p_value) where id=p_leg;
  if l.answer is not null and l.answer<>p_value then return jsonb_build_object('result','ignored');end if;
  if p_value='human' and (s.winner_id is null or s.winner_id=p_leg) and s.state in ('dialing','connected') then
   update public.dialer_parallel_sessions set winner_id=p_leg,state='connected' where id=p_id;
   update public.dialer_parallel_legs set outcome='connected' where id=p_leg;result:='winner';
  elsif p_value='human' then update public.dialer_parallel_legs set outcome='second_answer' where id=p_leg;result:='overflow';
  else update public.dialer_parallel_legs set outcome=p_value where id=p_leg;result:='hangup';end if;
 when 'status' then
  if p_value not in ('queued','ringing','in-progress','completed','busy','failed','no-answer','canceled') or p_sid is null then raise exception 'Invalid status event.';end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,
   state=case when terminal then state when p_value in ('completed','busy','failed','no-answer','canceled') then p_value
    when state='in-progress' then state when state='ringing' and p_value='queued' then state else p_value end,
   terminal=terminal or p_value in ('completed','busy','failed','no-answer','canceled'),
   duration_seconds=greatest(duration_seconds,least(greatest(p_seconds,0),600)) where id=p_leg;result:='status';
 when 'stop' then
  update public.dialer_parallel_sessions set state=case when state='complete' then state else 'stopping' end,stopped_at=coalesce(stopped_at,now()) where id=p_id;
  update public.dialer_parallel_legs set state='canceled',terminal=true,outcome=coalesce(outcome,'stopped') where session_id=p_id and state='prepared';result:='stopped';
 when 'complete' then
  update public.dialer_parallel_sessions set state='complete',stopped_at=coalesce(stopped_at,now()) where id=p_id;result:='complete';
 else raise exception 'Unknown pilot event.';
 end case;
 return jsonb_build_object('result',result);
end $$;
revoke all on function public.dialer_parallel_prepare(uuid,uuid,uuid,text,text,text[],numeric[]),public.dialer_parallel_event(uuid,text,uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.dialer_parallel_prepare(uuid,uuid,uuid,text,text,text[],numeric[]),public.dialer_parallel_event(uuid,text,uuid,text,text,integer) to service_role;

-- Preserve both existing functions exactly, adding the pilot to their busy checks.
do $$
declare definition text;
begin
 definition:=pg_get_functiondef('public.dialer_create_call_with_incoming_guard(uuid,boolean,uuid,uuid,integer,uuid,text)'::regprocedure);
 if position('if exists(select 1 from public.dialer_callbacks' in definition)=0 then raise exception 'Outgoing guard changed; review migration.';end if;
 definition:=replace(definition,'if exists(select 1 from public.dialer_callbacks',
 'if exists(select 1 from public.dialer_parallel_sessions where user_id=p_user and state<>''complete'' and expires_at>now()) then raise exception ''Finish the parallel pilot first.'';end if;
 if exists(select 1 from public.dialer_callbacks');execute definition;
 definition:=pg_get_functiondef('public.dialer_callback_start(uuid,boolean,text,text,text,text)'::regprocedure);
 if position('and not exists(select 1 from public.dialer_calls' in definition)=0 then raise exception 'Incoming guard changed; review migration.';end if;
 definition:=replace(definition,'and not exists(select 1 from public.dialer_calls',
 'and not exists(select 1 from public.dialer_parallel_sessions where user_id=p_user and state<>''complete'' and expires_at>now())
 and not exists(select 1 from public.dialer_calls');execute definition;
end $$;
