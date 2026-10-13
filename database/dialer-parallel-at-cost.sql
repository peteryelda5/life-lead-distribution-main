-- Extend the controlled-phone pilot to existing actual-cost exemptions only.
-- No new exemptions, subscription changes, invoices or provider purchases.
create function public.dialer_parallel_allowed(p_user uuid)
returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.profiles p where p.id=p_user and p.active and not p.archived and (
  (p.is_super_admin and p.role='admin')
  or exists(select 1 from public.dialer_at_cost b where b.user_id=p.id and b.enabled and b.required_role=p.role::text
   and not exists(select 1 from public.dialer_accounts a where a.user_id=p.id and a.livemode and a.subscription_id is not null))
 ));
$$;
create function public.dialer_parallel_can_call(p_user uuid,p_account text)
returns boolean language sql stable security invoker set search_path='' as $$
 select public.dialer_parallel_allowed(p_user) and (
  exists(select 1 from public.profiles where id=p_user and is_super_admin and role='admin')
  or (public.dialer_entitled(p_user,true) and exists(select 1 from public.dialer_at_cost where user_id=p_user and enabled and provider_sid=p_account and provider_secret_cipher is not null))
 );
$$;
revoke all on function public.dialer_parallel_allowed(uuid),public.dialer_parallel_can_call(uuid,text) from public,anon,authenticated;
grant execute on function public.dialer_parallel_allowed(uuid),public.dialer_parallel_can_call(uuid,text) to service_role;
do $$
declare definition text; old_check text;
begin
 definition:=pg_get_functiondef('public.dialer_parallel_prepare(uuid,uuid,uuid,text,text,text[],numeric[])'::regprocedure);
 old_check:='if not private.dialer_session_active(p_user,p_session) or not exists(select 1 from public.profiles where id=p_user and is_super_admin and active and not archived and role=''admin'') then raise exception ''Owner pilot access required.'';end if;';
 if position(old_check in definition)=0 then raise exception 'Pilot preparation changed; review migration.';end if;
 definition:=replace(definition,old_check,'if not private.dialer_session_active(p_user,p_session) or not public.dialer_parallel_can_call(p_user,p_account) then raise exception ''Active $0 calling access required. Complete Numbers & billing setup first.'';end if;');
 definition:=replace(definition,'Select an active owner caller ID.','Select your active caller ID.');
 execute definition;
 definition:=pg_get_functiondef('public.dialer_parallel_event(uuid,text,uuid,text,text,integer)'::regprocedure);
 old_check:='or not private.dialer_session_active(s.user_id,s.session_id))';
 if position(old_check in definition)=0 then raise exception 'Pilot event guard changed; review migration.';end if;
 definition:=replace(definition,old_check,'or not private.dialer_session_active(s.user_id,s.session_id) or not public.dialer_parallel_can_call(s.user_id,s.provider_sid))');
 execute definition;
end $$;
