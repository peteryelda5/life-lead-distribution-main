-- Preserve old sessions/clients in human-filter mode. New UI explicitly opts into fast connection.
alter table public.dialer_parallel_sessions add column connect_mode text not null default 'human' check(connect_mode in ('fast','human'));
alter table public.dialer_parallel_legs drop constraint dialer_parallel_legs_answer_check;
alter table public.dialer_parallel_legs add constraint dialer_parallel_legs_answer_check check(answer in ('answered','human','machine','fax','unknown'));
create function public.dialer_parallel_prepare_mode(p_user uuid,p_session uuid,p_id uuid,p_account text,p_caller text,p_phones text[],p_rates numeric[],p_mode text)
returns uuid language plpgsql security invoker set search_path='' as $$
declare existing public.dialer_parallel_sessions%rowtype; existed boolean; result uuid;
begin
 if p_mode is null or p_mode not in ('fast','human') then raise exception 'Choose a connection mode.';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 select * into existing from public.dialer_parallel_sessions where id=p_id;existed:=found;
 if existed and (existing.user_id<>p_user or existing.session_id<>p_session or existing.connect_mode<>p_mode) then raise exception 'Pilot preparation does not match this session.';end if;
 result:=public.dialer_parallel_prepare(p_user,p_session,p_id,p_account,p_caller,p_phones,p_rates);
 if not existed then update public.dialer_parallel_sessions set connect_mode=p_mode where id=result;end if;
 return result;
end $$;
revoke all on function public.dialer_parallel_prepare_mode(uuid,uuid,uuid,text,text,text[],numeric[],text) from public,anon,authenticated;
grant execute on function public.dialer_parallel_prepare_mode(uuid,uuid,uuid,text,text,text[],numeric[],text) to service_role;
do $$
declare definition text; old_check text;
begin
 definition:=pg_get_functiondef('public.dialer_parallel_event(uuid,text,uuid,text,text,integer)'::regprocedure);
 old_check:='if p_sid is null or l.state=''prepared'' or l.terminal or p_value not in (''human'',''machine'',''fax'',''unknown'')';
 if position(old_check in definition)=0 or position('if p_value=''human'' and' in definition)=0 then raise exception 'Pilot answer handling changed; review migration.';end if;
 definition:=replace(definition,old_check,'if p_sid is null or l.state=''prepared'' or l.terminal or p_value is null or (s.connect_mode=''fast'' and p_value<>''answered'') or (s.connect_mode=''human'' and p_value=''answered'') or p_value not in (''answered'',''human'',''machine'',''fax'',''unknown'')');
 definition:=replace(definition,'answer=coalesce(answer,p_value) where id=p_leg','answer=coalesce(answer,p_value),detection_ms=case when s.connect_mode=''human'' and p_seconds>0 then least(p_seconds,60000) else detection_ms end where id=p_leg');
 definition:=replace(definition,'if p_value=''human'' and','if p_value in (''human'',''answered'') and');
 definition:=replace(definition,'elsif p_value=''human'' then','elsif p_value in (''human'',''answered'') then');
 execute definition;
end $$;
