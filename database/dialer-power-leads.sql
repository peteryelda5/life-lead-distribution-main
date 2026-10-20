-- Lead-based Power Dialer. Service-only orchestration; ordinary lead RLS is unchanged.
alter table public.dialer_parallel_sessions add column kind text not null default 'test' check(kind in ('test','leads'));
alter table public.dialer_parallel_sessions add column max_seconds integer not null default 90 check(max_seconds between 60 and 1800);
alter table public.dialer_parallel_legs add column lead_id uuid references public.leads(id) on delete set null;
alter table public.dialer_parallel_legs add column error_code integer;
alter table public.dialer_parallel_legs drop constraint dialer_parallel_legs_duration_seconds_check;
alter table public.dialer_parallel_legs add constraint dialer_parallel_legs_duration_seconds_check check(duration_seconds between 0 and 7200);
alter table public.dialer_calls drop constraint dialer_calls_call_kind_check;
alter table public.dialer_calls add constraint dialer_calls_call_kind_check check(call_kind in ('lead','manual','power'));

create or replace function public.dialer_parallel_allowed(p_user uuid)
returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.profiles where id=p_user and active and not archived and role in ('admin','agent'));
$$;
create or replace function public.dialer_parallel_can_call(p_user uuid,p_account text)
returns boolean language sql stable security invoker set search_path='' as $$
 select public.dialer_parallel_allowed(p_user) and public.dialer_entitled(p_user,true) and (
  exists(select 1 from public.dialer_at_cost where user_id=p_user and enabled and provider_sid=p_account and provider_secret_cipher is not null)
  or not exists(select 1 from public.dialer_at_cost where user_id=p_user and enabled)
 );
$$;

create function public.dialer_power_prepare(p_user uuid,p_session uuid,p_id uuid,p_account text,p_caller text,p_leads uuid[],p_phones text[],p_rates numeric[],p_mode text)
returns uuid language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype; s public.dialer_parallel_sessions%rowtype; n integer; leg uuid; available integer; seconds integer;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 select * into a from public.dialer_accounts where user_id=p_user and livemode for update;
 if not found or not private.dialer_session_active(p_user,p_session) or not public.dialer_parallel_can_call(p_user,p_account) then raise exception 'Complete your calling setup in Numbers & billing first.';end if;
 if p_mode is null or p_mode not in ('fast','human') or coalesce(cardinality(p_leads),0) not between 1 and 3
 or cardinality(p_phones) is distinct from cardinality(p_leads) or cardinality(p_rates) is distinct from cardinality(p_leads)
 or (select count(distinct x) from unnest(p_leads) x)<>cardinality(p_leads)
 or (select count(distinct x) from unnest(p_phones) x)<>cardinality(p_leads)
 or exists(select 1 from unnest(p_rates) x where x is null or x<=0 or x>0.014) then raise exception 'Choose one to three distinct leads with standard US numbers.';end if;
 if not exists(select 1 from public.dialer_numbers where user_id=p_user and livemode and state='active' and phone=p_caller) then raise exception 'Activate a caller ID in Numbers & billing first.';end if;
 for n in 1..cardinality(p_leads) loop
  if p_leads[n] is null or p_phones[n] is null or public.dialer_lead_phone(p_user,p_leads[n]) is distinct from p_phones[n] or p_phones[n]=p_caller then raise exception 'A lead changed or cannot be called. Reload your queue.';end if;
 end loop;
 select * into s from public.dialer_parallel_sessions where id=p_id;
 if found then
  if s.user_id<>p_user or s.session_id<>p_session or s.kind<>'leads' or s.provider_sid<>p_account or s.caller_id<>p_caller or s.connect_mode<>p_mode
   or (select array_agg(lead_id order by position) from public.dialer_parallel_legs where session_id=p_id) is distinct from p_leads
   or (select array_agg(phone order by position) from public.dialer_parallel_legs where session_id=p_id) is distinct from p_phones then raise exception 'This batch does not match its original request.';end if;
  return p_id;
 end if;
 if exists(select 1 from public.dialer_parallel_sessions where user_id=p_user and state<>'complete')
 or exists(select 1 from public.dialer_calls where user_id=p_user and livemode and not finished and ((parent_sid is not null and created_at>now()-interval '40 minutes') or expires_at>now()))
 or exists(select 1 from public.dialer_callbacks where user_id=p_user and completed_at is null and ((status='ringing' and created_at>now()-interval '45 seconds') or (status='answered' and created_at>now()-interval '35 minutes'))) then raise exception 'Finish the current call or end the previous batch first.';end if;
 select 5000+a.overage_limit_cents/3-coalesce(sum(used_minutes),0)-coalesce(sum(case when not finished and (parent_sid is not null or expires_at>now()) then (max_seconds+59)/60 else 0 end),0)
 into available from public.dialer_calls where user_id=p_user and livemode and period_start=a.period_start;
 if available<cardinality(p_leads) then raise exception 'Your calling-minute limit has been reached. Check Numbers & billing.';end if;
 seconds:=least(1800,(available/cardinality(p_leads))*60);
 insert into public.dialer_parallel_sessions(id,user_id,session_id,provider_sid,caller_id,kind,connect_mode,max_seconds,expires_at)
 values(p_id,p_user,p_session,p_account,p_caller,'leads',p_mode,seconds,now()+interval '35 minutes');
 for n in 1..cardinality(p_leads) loop
  leg:=gen_random_uuid();
  insert into public.dialer_calls(id,user_id,livemode,period_start,lead_id,session_id,phone,caller_id,max_seconds,call_kind,expires_at)
  values(leg,p_user,true,a.period_start,p_leads[n],p_session,p_phones[n],p_caller,seconds,'power',now()+interval '35 minutes');
  insert into public.dialer_parallel_legs(id,session_id,position,lead_id,phone,rate) values(leg,p_id,n,p_leads[n],p_phones[n],p_rates[n]);
 end loop;
 return p_id;
end $$;
revoke all on function public.dialer_power_prepare(uuid,uuid,uuid,text,text,uuid[],text[],numeric[],text) from public,anon,authenticated;
grant execute on function public.dialer_power_prepare(uuid,uuid,uuid,text,text,uuid[],text[],numeric[],text) to service_role;

-- Each outbound phone leg has exactly one usage row. Repeated callbacks cannot double-charge it.
create function private.dialer_power_usage() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 update public.dialer_calls set parent_sid=coalesce(parent_sid,new.provider_sid),
  finished=finished or new.terminal,duration_seconds=greatest(duration_seconds,new.duration_seconds),
  call_status=case when finished then call_status else new.state end,
  finished_at=case when new.terminal then coalesce(finished_at,now()) else finished_at end
 where id=new.id and call_kind='power';
 return new;
end $$;
revoke all on function private.dialer_power_usage() from public,anon,authenticated;
create trigger dialer_power_usage after update on public.dialer_parallel_legs for each row execute function private.dialer_power_usage();
create or replace function public.dialer_parallel_event(p_id uuid,p_event text,p_leg uuid default null,p_sid text default null,p_value text default null,p_seconds integer default 0)
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
 if p_event in ('agent','ready','launch','claim','answer') and (s.expires_at<=now() or s.heartbeat_at<now()-interval '35 seconds' or s.state in ('stopping','complete') or not private.dialer_session_active(s.user_id,s.session_id) or not public.dialer_parallel_can_call(s.user_id,s.provider_sid)) then return jsonb_build_object('result','stopped');end if;
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
  if p_sid is null or l.state='prepared' or l.terminal or p_value is null or (s.connect_mode='fast' and p_value<>'answered') or (s.connect_mode='human' and p_value='answered') or p_value not in ('answered','human','machine','fax','unknown') then return jsonb_build_object('result','ignored');end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,answer=coalesce(answer,p_value),detection_ms=case when s.connect_mode='human' and p_seconds>0 then least(p_seconds,60000) else detection_ms end where id=p_leg;
  if l.answer is not null and l.answer<>p_value then return jsonb_build_object('result','ignored');end if;
  if p_value in ('human','answered') and (s.winner_id is null or s.winner_id=p_leg) and s.state in ('dialing','connected') then
   update public.dialer_parallel_sessions set winner_id=p_leg,state='connected' where id=p_id;
   update public.dialer_parallel_legs set outcome='connected' where id=p_leg;result:='winner';
  elsif p_value in ('human','answered') then update public.dialer_parallel_legs set outcome='second_answer' where id=p_leg;result:='overflow';
  else update public.dialer_parallel_legs set outcome=p_value where id=p_leg;result:='hangup';end if;
 when 'status' then
  if p_value not in ('queued','ringing','in-progress','completed','busy','failed','no-answer','canceled') or p_sid is null then raise exception 'Invalid status event.';end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,
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

-- A Power Dialer leg is consumed only by the parallel bridge, never by a single-call token.
do $$ declare definition text; begin
 definition:=pg_get_functiondef('public.dialer_consume_call(uuid,text)'::regprocedure);
 if position('if not found or c.finished' in definition)=0 then raise exception 'Call guard changed; review migration.';end if;
 execute replace(definition,'if not found or c.finished','if not found or c.call_kind=''power'' or c.finished');
end $$;
