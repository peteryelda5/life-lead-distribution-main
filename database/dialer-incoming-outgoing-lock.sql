-- Hold the same per-agent lock while the existing outgoing function reserves a call.
-- This prevents a second browser from starting an outgoing call during a callback.
create or replace function public.dialer_create_call_with_incoming_guard(p_user uuid,p_live boolean,p_session uuid,p_call uuid,p_slot integer,p_lead uuid,p_phone text)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 if exists(select 1 from public.dialer_callbacks where user_id=p_user and completed_at is null
  and ((status='ringing' and created_at>now()-interval '45 seconds') or (status='answered' and created_at>now()-interval '35 minutes'))) then
  raise exception 'Finish the incoming call before starting another call.';
 end if;
 if p_lead is not null and p_phone is null then
  return public.dialer_create_call(p_user=>p_user,p_session=>p_session,p_live=>p_live,p_lead=>p_lead,p_call=>p_call,p_slot=>p_slot);
 elsif p_lead is null and p_phone is not null then
  return public.dialer_create_manual_call(p_user=>p_user,p_session=>p_session,p_live=>p_live,p_phone=>p_phone,p_call=>p_call,p_slot=>p_slot);
 else raise exception 'Choose a lead or a phone number.';
 end if;
end $$;
revoke all on function public.dialer_create_call_with_incoming_guard(uuid,boolean,uuid,uuid,integer,uuid,text) from public,anon,authenticated;
grant execute on function public.dialer_create_call_with_incoming_guard(uuid,boolean,uuid,uuid,integer,uuid,text) to service_role;
