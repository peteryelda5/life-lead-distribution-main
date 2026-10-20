-- Preserve pickup evidence independently of asynchronous classification and cleanup.
alter table public.dialer_parallel_legs add column pickup_at timestamptz;
alter table public.dialer_parallel_legs add column confirm_requested_at timestamptz;
alter table public.dialer_parallel_legs add column confirmed_at timestamptz;

create or replace function private.dialer_power_followup_note() returns trigger
language plpgsql security invoker set search_path='' as $$
declare stamped_at timestamptz:=clock_timestamp(); note_text text;
begin
 if new.outcome not in ('second_answer','answer_unconfirmed','answered_not_connected') or old.followup_noted_at is not null or new.lead_id is null then return new;end if;
 note_text:=case new.outcome
  when 'second_answer' then 'Call answered while you were connected to another lead. This call was not connected to you. Follow-up needed.'
  when 'answered_not_connected' then 'Call answered, but ended before it could be connected to you. Follow-up needed.'
  else 'Call picked up, but a live person was not confirmed before it ended. This call was not connected to you. Follow-up needed.' end;
 update public.leads as lead set call_notes=coalesce(lead.call_notes,'')
  ||case when coalesce(lead.call_notes,'')='' then '' else E'\n\n' end
  ||'[Power Dialer — '||to_char(stamped_at at time zone 'America/New_York','MM/DD/YYYY HH12:MI AM')||' ET] '||note_text
 from public.dialer_parallel_sessions as session where session.id=new.session_id and session.kind='leads'
  and session.winner_id is distinct from new.id
  and (new.outcome<>'second_answer' or session.winner_id is not null)
  and lead.id=new.lead_id and lead.assigned_to=session.user_id and lead.status='assigned';
 if found then new.followup_noted_at:=stamped_at;end if;return new;
end $$;
drop trigger dialer_power_followup_note on public.dialer_parallel_legs;
create trigger dialer_power_followup_note before update of outcome on public.dialer_parallel_legs
for each row when(new.outcome in ('second_answer','answer_unconfirmed','answered_not_connected') and old.followup_noted_at is null)
execute function private.dialer_power_followup_note();
revoke all on function private.dialer_power_followup_note() from public,anon,authenticated;
grant execute on function private.dialer_power_followup_note() to service_role;

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
 if p_event='answer' and (l.terminal or s.state in ('stopping','complete')) then
  if l.confirmed_at is not null then return jsonb_build_object('result','hangup');end if;
  if p_sid is null or l.state='prepared' or p_value is null or p_value not in ('answered','human','machine','fax','unknown')
    or (s.connect_mode='fast' and p_value<>'answered') or (s.connect_mode='human' and p_value='answered')
    or (l.answer is not null and l.answer<>p_value) then return jsonb_build_object('result','ignored');end if;
  update public.dialer_parallel_legs set provider_sid=p_sid,answer=coalesce(answer,p_value),pickup_at=coalesce(pickup_at,clock_timestamp()),
   detection_ms=case when s.connect_mode='human' and p_seconds>0 then least(p_seconds,60000) else detection_ms end,
   outcome=case when s.winner_id=p_leg then outcome when p_value in ('human','answered') then
      case when s.winner_id is not null then 'second_answer' else 'answered_not_connected' end
     else p_value end where id=p_leg;
  return jsonb_build_object('result','hangup');
 end if;
 if p_event in ('agent','ready','launch','claim','answer','confirm') and (s.expires_at<=now() or s.heartbeat_at<now()-interval '35 seconds' or s.state in ('stopping','complete') or not private.dialer_session_active(s.user_id,s.session_id) or not public.dialer_parallel_can_call(s.user_id,s.provider_sid)) then return jsonb_build_object('result','stopped');end if;
 if p_event in ('claim','answer','confirm') and s.kind='leads' then
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
 when 'answer','confirm' then
  if p_sid is null or l.state='prepared' or l.terminal then return jsonb_build_object('result','ignored');end if;
  if p_event='confirm' then
   if p_value is distinct from '1' or s.kind<>'leads' or (l.outcome is distinct from 'awaiting_confirmation' and l.confirmed_at is null)
     or l.confirm_requested_at is null or l.confirm_requested_at<clock_timestamp()-interval '30 seconds' then return jsonb_build_object('result','ignored');end if;
   update public.dialer_parallel_legs set confirmed_at=coalesce(confirmed_at,clock_timestamp()) where id=p_leg;
  else
   if p_value is null or (s.connect_mode='fast' and p_value<>'answered') or (s.connect_mode='human' and p_value='answered')
      or p_value not in ('answered','human','machine','fax','unknown') or (l.answer is not null and l.answer<>p_value) then return jsonb_build_object('result','ignored');end if;
   -- A retried AMD webhook must not replace a subsequent keypress decision.
   if l.confirmed_at is not null then return jsonb_build_object('result','ignored');end if;
   update public.dialer_parallel_legs set provider_sid=p_sid,answer=coalesce(answer,p_value),pickup_at=coalesce(pickup_at,clock_timestamp()),
    detection_ms=case when s.connect_mode='human' and p_seconds>0 then least(p_seconds,60000) else detection_ms end where id=p_leg;
  end if;
  if p_event='confirm' or p_value in ('human','answered') then
   if (s.winner_id is null or s.winner_id=p_leg) and s.state in ('dialing','connected') then
    update public.dialer_parallel_sessions set winner_id=p_leg,state='connected' where id=p_id;
    update public.dialer_parallel_legs set outcome='connected' where id=p_leg;result:='winner';
   else update public.dialer_parallel_legs set outcome='second_answer' where id=p_leg;result:='overflow';end if;
  elsif s.kind='leads' and p_value in ('machine','unknown') then
   if l.confirm_requested_at is not null and l.outcome is distinct from 'awaiting_confirmation' then return jsonb_build_object('result','hangup');end if;
   update public.dialer_parallel_legs set outcome='awaiting_confirmation',confirm_requested_at=coalesce(confirm_requested_at,clock_timestamp()) where id=p_leg;result:='confirm';
  else update public.dialer_parallel_legs set outcome=p_value where id=p_leg;result:='hangup';end if;
 when 'confirm_timeout' then
  if p_sid is null or l.outcome is distinct from 'awaiting_confirmation' then return jsonb_build_object('result','ignored');end if;
  update public.dialer_parallel_legs set outcome=case when answer='machine' then 'machine' else 'answer_unconfirmed' end where id=p_leg;result:='hangup';
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
