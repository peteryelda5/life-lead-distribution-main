CREATE OR REPLACE FUNCTION public.dialer_callback_start(p_user uuid, p_live boolean, p_account text, p_parent text, p_from text, p_to text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare c public.dialer_callbacks%rowtype; endpoint text;
begin
 if not exists(select 1 from public.profiles where id=p_user and active and not archived and role in ('agent','admin'))
 or not (exists(select 1 from public.dialer_numbers where user_id=p_user and livemode=p_live and state='active' and phone=p_to)
 or (p_live and exists(select 1 from public.master_dialer_numbers where user_id=p_user and state='active' and phone_number=p_to))) then
 raise exception 'Number is unavailable';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 select * into c from public.dialer_callbacks where parent_sid=p_parent;
 if found then
  if c.user_id<>p_user or c.provider_sid<>p_account or c.dialed_phone<>p_to then raise exception 'Call ownership mismatch';end if;
  return jsonb_build_object('id',c.id,'identity',case when c.status='ringing' and c.created_at>now()-interval '40 seconds' then c.ring_identity end);
 end if;
 if not exists(select 1 from public.dialer_callbacks where user_id=p_user and completed_at is null
   and ((status='ringing' and created_at>now()-interval '45 seconds') or (status='answered' and created_at>now()-interval '35 minutes')))
 and not exists(select 1 from public.dialer_parallel_sessions where user_id=p_user and state<>'complete' and expires_at>now())
 and not exists(select 1 from public.dialer_calls where user_id=p_user and not finished
   and ((parent_sid is not null and created_at>now()-interval '35 minutes') or expires_at>now())) then
  select p.identity into endpoint from public.dialer_incoming_presence p
   where p.user_id=p_user and p.livemode=p_live and p.ready_until>now() and not p.busy
    and private.dialer_session_active(p.user_id,p.session_id)
    and not exists(select 1 from public.dialer_agent_preferences a where a.user_id=p_user and a.livemode=p_live and a.mode<>'ready')
   order by p.ready_until desc limit 1;
 end if;
 insert into public.dialer_callbacks(user_id,livemode,provider_sid,parent_sid,caller_phone,dialed_phone,ring_identity,status)
 values(p_user,p_live,p_account,p_parent,left(p_from,64),p_to,endpoint,case when endpoint is null then 'missed' else 'ringing' end) returning * into c;
 return jsonb_build_object('id',c.id,'identity',endpoint);
end $function$
