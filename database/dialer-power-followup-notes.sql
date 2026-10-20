-- One durable note per overflow call, written in the same transaction as its outcome.
alter table public.dialer_parallel_legs add column followup_noted_at timestamptz;

create function private.dialer_power_followup_note() returns trigger
language plpgsql security invoker set search_path='' as $$
declare stamped_at timestamptz:=clock_timestamp();
begin
 if new.outcome is distinct from 'second_answer' or old.followup_noted_at is not null
    or new.lead_id is null then return new;end if;
 update public.leads as lead
 set call_notes=coalesce(lead.call_notes,'')
   ||case when coalesce(lead.call_notes,'')='' then '' else E'\n\n' end
   ||'[Power Dialer — '||to_char(stamped_at at time zone 'America/New_York','MM/DD/YYYY HH12:MI AM')||' ET] '
   ||'Call answered while you were connected to another lead. This call was not connected to you. Follow-up needed.'
 from public.dialer_parallel_sessions as session
 where session.id=new.session_id and session.kind='leads'
   and session.winner_id is not null and session.winner_id<>new.id
   and lead.id=new.lead_id and lead.assigned_to=session.user_id and lead.status='assigned';
 if found then new.followup_noted_at:=stamped_at;end if;
 return new;
end $$;
revoke all on function private.dialer_power_followup_note() from public,anon,authenticated;
grant execute on function private.dialer_power_followup_note() to service_role;
create trigger dialer_power_followup_note before update of outcome on public.dialer_parallel_legs
for each row when(new.outcome='second_answer' and old.followup_noted_at is null)
execute function private.dialer_power_followup_note();
