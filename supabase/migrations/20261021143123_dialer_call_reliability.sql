-- Browser reports are diagnostic evidence, never authoritative call outcomes.
create table public.dialer_client_health (
 kind text not null check(kind in ('call','parallel')),
 target_id uuid not null,
 user_id uuid not null references public.profiles(id) on delete cascade,
 call_id uuid references public.dialer_calls(id) on delete cascade,
 parallel_id uuid references public.dialer_parallel_sessions(id) on delete cascade,
 events jsonb not null default '[]'::jsonb check(jsonb_typeof(events)='array' and jsonb_array_length(events)<=400 and octet_length(events::text)<=200000),
 updated_at timestamptz not null default now(),
 primary key(kind,target_id),
 check((kind='call' and call_id=target_id and call_id is not null and parallel_id is null) or (kind='parallel' and parallel_id=target_id and parallel_id is not null and call_id is null))
);
alter table public.dialer_client_health enable row level security;
revoke all on public.dialer_client_health from public,anon,authenticated;
grant select,insert,update,delete on public.dialer_client_health to service_role;
create index dialer_client_health_user_updated on public.dialer_client_health(user_id,updated_at desc);
create unique index dialer_client_health_call on public.dialer_client_health(call_id) where call_id is not null;
create unique index dialer_client_health_parallel on public.dialer_client_health(parallel_id) where parallel_id is not null;

create function public.dialer_record_client_health(p_user uuid,p_session uuid,p_kind text,p_target uuid,p_events jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare existing jsonb; combined jsonb;
begin
 if p_kind is null or p_kind not in ('call','parallel') or p_events is null or jsonb_typeof(p_events)<>'array' or jsonb_array_length(p_events) not between 1 and 20 or octet_length(p_events::text)>16000 then raise exception 'Invalid call diagnostics';end if;
 if not private.dialer_session_active(p_user,p_session) then raise exception 'Session unavailable';end if;
 -- Lock the owned target so concurrent batches cannot bypass the bound or lose events.
 if p_kind='call' then
  perform 1 from public.dialer_calls where id=p_target and user_id=p_user and session_id=p_session and livemode and created_at>now()-interval '24 hours' for update;
 else
  perform 1 from public.dialer_parallel_sessions where id=p_target and user_id=p_user and session_id=p_session and created_at>now()-interval '24 hours' for update;
 end if;
 if not found then raise exception 'Call unavailable';end if;
 select events into existing from public.dialer_client_health where kind=p_kind and target_id=p_target;
 select coalesce(jsonb_agg(item order by position),'[]'::jsonb) into combined from (
  select distinct on(item->>'id') item,position from jsonb_array_elements(coalesce(existing,'[]'::jsonb)||p_events) with ordinality as e(item,position)
  order by item->>'id',position
 ) dedup;
 if jsonb_array_length(combined)>400 then return jsonb_build_object('accepted',false,'reason','limit');end if;
 insert into public.dialer_client_health(kind,target_id,user_id,call_id,parallel_id,events)
 values(p_kind,p_target,p_user,case when p_kind='call' then p_target end,case when p_kind='parallel' then p_target end,combined)
 on conflict(kind,target_id) do update set events=excluded.events,updated_at=now();
 return jsonb_build_object('accepted',true);
end $$;
revoke all on function public.dialer_record_client_health(uuid,uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.dialer_record_client_health(uuid,uuid,text,uuid,jsonb) to service_role;


-- An uncertain first pickup connects without claiming it is a confirmed human.
-- Remove recipient keypress confirmation; retain pickup recovery and atomic follow-up notes.
create or replace function public.dialer_parallel_event(p_id uuid,p_event text,p_leg uuid default null,p_sid text default null,p_value text default null,p_seconds integer default 0)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare s public.dialer_parallel_sessions%rowtype; l public.dialer_parallel_legs%rowtype; result text:='ignored';
begin
 select * into strict s from public.dialer_parallel_sessions where id=p_id for update;
 if p_event in ('claim','bind','answer','confirm','confirm_timeout','status') and p_leg is null then raise exception 'Pilot line required.';end if;
 if p_sid is not null and p_sid !~ '^CA[0-9a-fA-F]{32}$' then raise exception 'Invalid call identifier.';end if;
 if p_leg is not null then
  select * into strict l from public.dialer_parallel_legs where id=p_leg and session_id=p_id for update;
  if l.provider_sid is not null and p_sid is not null and l.provider_sid<>p_sid then raise exception 'Call identifier mismatch.';end if;
 end if;
 -- Retired keypress callbacks may still arrive from a call started before this release.
 if p_event in ('confirm','confirm_timeout') then
  if l.outcome='awaiting_confirmation' then
   update public.dialer_parallel_legs set outcome=case when answer='machine' then 'machine' else 'answer_unconfirmed' end where id=p_leg;
  end if;
  return jsonb_build_object('result','hangup');
 end if;
 if p_event='answer' and (l.terminal or s.state in ('stopping','complete')) then
  if l.confirmed_at is not null then return jsonb_build_object('result','hangup');end if;
  if p_sid is null or l.state='prepared' or p_value is null or p_value not in ('answered','human','machine','fax','unknown')
    or (s.connect_mode='fast' and p_value<>'answered') or (s.connect_mode='human' and p_value='answered')
    or (l.answer is not null and l.answer<>p_value) then return jsonb_build_object('result','ignored');end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,answer=coalesce(answer,p_value),pickup_at=coalesce(pickup_at,clock_timestamp()),
   detection_ms=case when s.connect_mode='human' and p_seconds>0 then least(p_seconds,60000) else detection_ms end,
   outcome=case when s.winner_id=p_leg then outcome when p_value in ('human','answered') then
      case when s.winner_id is not null then 'second_answer' else 'answered_not_connected' end
     when s.kind='leads' and p_value='unknown' then 'answer_unconfirmed' else p_value end where id=p_leg;
  return jsonb_build_object('result','hangup');
 end if;
 if p_event in ('agent','ready','launch','claim','answer') and (s.expires_at<=now() or s.heartbeat_at<now()-case when s.state='connected' then interval '90 seconds' else interval '35 seconds' end or s.state in ('stopping','complete') or not private.dialer_session_active(s.user_id,s.session_id) or not public.dialer_parallel_can_call(s.user_id,s.provider_sid)) then return jsonb_build_object('result','stopped');end if;
 if p_event in ('claim','answer') and s.kind='leads' then
  begin
   if l.lead_id is null or public.dialer_lead_phone(s.user_id,l.lead_id) is distinct from l.phone then raise exception 'Lead changed';end if;
  exception when others then
   update public.dialer_parallel_legs set state='canceled',terminal=true,outcome='lead_changed',provider_sid=coalesce(provider_sid,p_sid) where id=p_leg;
   return jsonb_build_object('result','stopped');
  end;
 end if;
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
 when 'reject' then
  if l.provider_sid is not null or l.state<>'creating' then return jsonb_build_object('result','ignored');end if;
  update public.dialer_parallel_legs set state='failed',terminal=true,outcome='number_rejected',error_code=p_seconds where id=p_leg;result:='rejected';
 when 'bind' then
  if p_sid is null then raise exception 'Call identifier required.';end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,state=case when state='creating' then 'queued' else state end where id=p_leg;result:='bound';
 when 'answer' then
  if p_sid is null or l.state='prepared' or l.terminal then return jsonb_build_object('result','ignored');end if;
  if p_value is null or (s.connect_mode='fast' and p_value<>'answered') or (s.connect_mode='human' and p_value='answered')
     or p_value not in ('answered','human','machine','fax','unknown') or (l.answer is not null and l.answer<>p_value) then return jsonb_build_object('result','ignored');end if;
  -- Preserve historical confirmed calls if a pre-release webhook is retried.
  if l.confirmed_at is not null then return jsonb_build_object('result','ignored');end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,answer=coalesce(answer,p_value),pickup_at=coalesce(pickup_at,clock_timestamp()),
   detection_ms=case when s.connect_mode='human' and p_seconds>0 then least(p_seconds,60000) else detection_ms end where id=p_leg;
  if p_value in ('human','answered','unknown') then
   if (s.winner_id is null or s.winner_id=p_leg) and s.state in ('dialing','connected') then
    update public.dialer_parallel_sessions set winner_id=p_leg,state='connected' where id=p_id;
    update public.dialer_parallel_legs set outcome='connected' where id=p_leg;result:='winner';
   else update public.dialer_parallel_legs set outcome=case when p_value='unknown' then 'answer_unconfirmed' else 'second_answer' end where id=p_leg;result:='overflow';end if;
  else
   update public.dialer_parallel_legs set outcome=case when s.kind='leads' and p_value='unknown' then 'answer_unconfirmed' else p_value end where id=p_leg;result:='hangup';
  end if;
 when 'status' then
  if p_value not in ('queued','ringing','in-progress','completed','busy','failed','no-answer','canceled') or p_sid is null then raise exception 'Invalid status event.';end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,
   pickup_at=case when p_value in ('in-progress','completed') then coalesce(pickup_at,clock_timestamp()) else pickup_at end,
   outcome=case when outcome='awaiting_confirmation' and p_value in ('completed','busy','failed','no-answer','canceled') then case when answer='machine' then 'machine' else 'answer_unconfirmed' end
    when s.kind='leads' and s.winner_id is distinct from p_leg and answer is null and (outcome is null or outcome='stopped')
    and (terminal or p_value in ('completed','busy','failed','no-answer','canceled'))
    and (pickup_at is not null or p_value in ('in-progress','completed')) then 'answer_unconfirmed' else outcome end,
   state=case when terminal then state when p_value in ('completed','busy','failed','no-answer','canceled') then p_value
    when state='in-progress' then state when state='ringing' and p_value='queued' then state else p_value end,
   terminal=terminal or p_value in ('completed','busy','failed','no-answer','canceled'),
   duration_seconds=greatest(duration_seconds,least(greatest(p_seconds,0),7200)) where id=p_leg;result:='status';
 when 'stop' then
  update public.dialer_parallel_sessions set state=case when state='complete' then state else 'stopping' end,stopped_at=coalesce(stopped_at,now()) where id=p_id;
  update public.dialer_parallel_legs set state='canceled',terminal=true,outcome=coalesce(outcome,'stopped') where session_id=p_id and state='prepared';result:='stopped';
 when 'complete' then
  update public.dialer_parallel_sessions set state='complete',stopped_at=coalesce(stopped_at,now()) where id=p_id;result:='complete';
 else raise exception 'Unknown pilot event.';
 end case;
 return jsonb_build_object('result',result);
end $$;


revoke all on function public.dialer_parallel_event(uuid,text,uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.dialer_parallel_event(uuid,text,uuid,text,text,integer) to service_role;
