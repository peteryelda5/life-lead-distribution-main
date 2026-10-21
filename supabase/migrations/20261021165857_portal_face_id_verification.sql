-- Optional WebAuthn second factor. Supabase tokens are never minted or relabelled.
-- Only a server-verified signature creates a proof for an existing Auth session.
create table private.portal_passkeys (
 id text primary key check(length(id) between 16 and 2048),
 user_id uuid not null references public.profiles(id) on delete cascade,
 public_key text not null check(length(public_key) between 20 and 4096),
 counter bigint not null default 0 check(counter>=0),
 transports text[] not null default '{}',
 name text not null default 'My device' check(length(name) between 1 and 80),
 created_at timestamptz not null default now(),last_used_at timestamptz
);
create index portal_passkeys_user on private.portal_passkeys(user_id);
create table private.portal_passkey_challenges (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 session_id uuid not null references auth.sessions(id) on delete cascade,
 kind text not null check(kind in ('register','authenticate')),
 challenge text not null check(length(challenge) between 32 and 256),
 created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '5 minutes',
 used_at timestamptz,completed_at timestamptz
);
create index portal_passkey_challenges_user on private.portal_passkey_challenges(user_id,created_at);
create index portal_passkey_challenges_session on private.portal_passkey_challenges(session_id);
create table private.portal_passkey_sessions (
 session_id uuid primary key references auth.sessions(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 credential_id text not null references private.portal_passkeys(id) on delete cascade,
 verified_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '12 hours'
);
create index portal_passkey_sessions_user on private.portal_passkey_sessions(user_id);
create index portal_passkey_sessions_credential on private.portal_passkey_sessions(credential_id);
alter table private.portal_passkeys enable row level security;
alter table private.portal_passkey_challenges enable row level security;
alter table private.portal_passkey_sessions enable row level security;
revoke all on private.portal_passkeys,private.portal_passkey_challenges,private.portal_passkey_sessions from public,anon,authenticated,service_role;

create function private.portal_passkey_session_valid(p_user uuid,p_session uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.portal_passkey_sessions v
 join auth.sessions s on s.id=v.session_id and s.user_id=v.user_id
 join private.portal_passkeys k on k.id=v.credential_id and k.user_id=v.user_id
 join public.profiles p on p.id=v.user_id
 where v.user_id=p_user and v.session_id=p_session and v.expires_at>now()
 and (s.not_after is null or s.not_after>now()) and p.active and not coalesce(p.archived,false) and p.role in ('admin','agent'));
$$;
revoke all on function private.portal_passkey_session_valid(uuid,uuid) from public,anon,authenticated;

-- Maintain the original TOTP path and all agency/ownership policies.
create or replace function private.verified_portal_session()
returns boolean language sql stable security definer set search_path='' as $$
 select (coalesce(auth.jwt()->>'aal'='aal2',false)
 or private.portal_passkey_session_valid(auth.uid(),nullif(auth.jwt()->>'session_id','')::uuid))
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and not coalesce(p.archived,false) and p.role in ('admin','agent'));
$$;

-- Service-only persistence. p_user/session/aal come from a JWT already verified
-- by Supabase Auth. Never expose these calls directly to the browser.
create function private.portal_passkey_manage(p_user uuid,p_session uuid,p_aal text,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare c private.portal_passkey_challenges; k private.portal_passkeys; verified boolean; result jsonb; cid uuid;
begin
 if not exists(select 1 from auth.sessions s join public.profiles p on p.id=s.user_id
 where s.id=p_session and s.user_id=p_user and (s.not_after is null or s.not_after>now())
 and p.active and not coalesce(p.archived,false) and p.role in ('admin','agent')) then
 raise exception 'Sign in again to use Face ID' using errcode='42501';end if;
 verified:=coalesce(p_aal='aal2',false) or private.portal_passkey_session_valid(p_user,p_session);
 if p_action='status' then
  return jsonb_build_object('verified',verified,'expires_at',(select expires_at from private.portal_passkey_sessions where session_id=p_session),
   'credentials',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'created_at',created_at,'last_used_at',last_used_at)),'[]') from private.portal_passkeys where user_id=p_user));
 end if;
 if p_action in ('register_options','register_finish','remove') and not verified then
 raise exception 'Verify your authenticator code before setting up Face ID' using errcode='42501';end if;
 if p_action in ('register_options','authenticate_options') then
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,8292));
  delete from private.portal_passkey_challenges where created_at<now()-interval '1 day';
  if (select count(*) from private.portal_passkey_challenges where user_id=p_user and created_at>now()-interval '10 minutes')>=20 then
   raise exception 'Too many Face ID attempts. Wait a few minutes and try again';end if;
  if p_action='register_options' and (select count(*) from private.portal_passkeys where user_id=p_user)>=10 then raise exception 'Remove an old passkey before adding another';end if;
  insert into private.portal_passkey_challenges(user_id,session_id,kind,challenge)
   values(p_user,p_session,case when p_action='register_options' then 'register' else 'authenticate' end,p_data->>'challenge') returning id into cid;
  return jsonb_build_object('id',cid,'credentials',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'transports',transports)),'[]') from private.portal_passkeys where user_id=p_user));
 elsif p_action='take' then
  update private.portal_passkey_challenges set used_at=now() where id=(p_data->>'id')::uuid and user_id=p_user and session_id=p_session
   and kind=p_data->>'kind' and used_at is null and expires_at>now() returning * into c;
  if c.id is null then raise exception 'Face ID request expired. Try again' using errcode='42501';end if;
  if c.kind='register' and not verified then raise exception 'Verify your authenticator code before setting up Face ID' using errcode='42501';end if;
  if c.kind='authenticate' then
   select * into k from private.portal_passkeys where id=p_data->>'credential' and user_id=p_user;
   if k.id is null then raise exception 'This passkey does not belong to your account' using errcode='42501';end if;
  end if;
  return jsonb_build_object('challenge',c.challenge,'credential',case when k.id is not null then jsonb_build_object('id',k.id,'public_key',k.public_key,'counter',k.counter,'transports',k.transports) else null end);
 elsif p_action in ('register_finish','authenticate_finish') then
  select * into c from private.portal_passkey_challenges where id=(p_data->>'id')::uuid and user_id=p_user and session_id=p_session
   and kind=case when p_action='register_finish' then 'register' else 'authenticate' end and used_at is not null and completed_at is null and expires_at>now() for update;
  if c.id is null then raise exception 'Face ID request expired. Try again' using errcode='42501';end if;
  if p_action='register_finish' then
   perform pg_advisory_xact_lock(hashtextextended(p_user::text,8292));
   if (select count(*) from private.portal_passkeys where user_id=p_user)>=10 then raise exception 'Remove an old passkey before adding another';end if;
   insert into private.portal_passkeys(id,user_id,public_key,counter,transports,name)
    values(p_data->>'credential',p_user,p_data->>'public_key',(p_data->>'counter')::bigint,
     array(select jsonb_array_elements_text(coalesce(p_data->'transports','[]'))),left(coalesce(nullif(p_data->>'name',''),'My device'),80));
  else
   select * into k from private.portal_passkeys where id=p_data->>'credential' and user_id=p_user for update;
   if k.id is null or k.counter<>(p_data->>'previous_counter')::bigint or
    ((k.counter<>0 or (p_data->>'counter')::bigint<>0) and (p_data->>'counter')::bigint<=k.counter) then
    raise exception 'Passkey changed. Try Face ID again' using errcode='42501';end if;
   update private.portal_passkeys set counter=(p_data->>'counter')::bigint,last_used_at=now() where id=k.id;
   insert into private.portal_passkey_sessions(session_id,user_id,credential_id) values(p_session,p_user,k.id)
   on conflict(session_id) do update set credential_id=excluded.credential_id,verified_at=now(),expires_at=now()+interval '12 hours';
  end if;
  update private.portal_passkey_challenges set completed_at=now() where id=c.id;
  return jsonb_build_object('ok',true);
 elsif p_action='remove' then
  delete from private.portal_passkeys where id=p_data->>'credential' and user_id=p_user;
  return jsonb_build_object('ok',true);
 end if;
 raise exception 'Invalid Face ID action';
end $$;
create function public.portal_passkey_manage(p_user uuid,p_session uuid,p_aal text,p_action text,p_data jsonb default '{}')
returns jsonb language sql security invoker set search_path='' as $$select private.portal_passkey_manage(p_user,p_session,p_aal,p_action,p_data)$$;
revoke all on function private.portal_passkey_manage(uuid,uuid,text,text,jsonb),public.portal_passkey_manage(uuid,uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function private.portal_passkey_manage(uuid,uuid,text,text,jsonb),public.portal_passkey_manage(uuid,uuid,text,text,jsonb) to service_role;

-- Revoke registered Face ID methods when an agency administrator resets MFA.
-- This is invoked by the existing reset function with a service credential.
create function private.portal_passkey_reset(p_user uuid) returns void language sql security definer set search_path='' as $$
 delete from private.portal_passkeys where user_id=p_user;
 delete from private.portal_passkey_challenges where user_id=p_user;
$$;
create function public.portal_passkey_reset(p_user uuid) returns void language sql security invoker set search_path='' as $$select private.portal_passkey_reset(p_user)$$;
revoke all on function private.portal_passkey_reset(uuid),public.portal_passkey_reset(uuid) from public,anon,authenticated;
grant execute on function private.portal_passkey_reset(uuid),public.portal_passkey_reset(uuid) to service_role;

-- Route the remaining explicit second-factor gates through the same verifier.
CREATE OR REPLACE FUNCTION private.leaderboard_divisions()
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.profiles%rowtype;
begin
 select * into p from public.profiles where id=auth.uid() and active and not coalesce(archived,false);
 if not found then return array[]::text[]; end if;
 if p.role='admin' then return private.my_admin_divisions(); end if;
 if p.role='agent' and private.verified_portal_session() then return array[p.division]::text[]; end if;
 return array[]::text[];
end $function$
;
CREATE OR REPLACE FUNCTION public.is_active_agent()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role = 'agent'
      and p.active = true
      and coalesce(p.archived,false) = false
      and private.verified_portal_session()
  );
$function$
;
CREATE OR REPLACE FUNCTION public.my_lead_folders()
 RETURNS TABLE(lead_type text, lead_count bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select l.lead_type,count(*) from public.leads l where l.assigned_to=(select auth.uid()) and l.status='assigned' and (select private.can_work_assigned_leads()) and (select private.verified_portal_session()) group by l.lead_type order by l.lead_type nulls last $function$
;
CREATE OR REPLACE FUNCTION public.open_agent_support(p_agent uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not private.verified_portal_session() or not exists (
   select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'
   and p.is_super_admin and p.active and not coalesce(p.archived,false)) then
   raise exception 'Verified Master account required' using errcode='42501';
 end if;
 if not exists (select 1 from public.profiles p where p.id=p_agent and p.role='agent'
 and p.active and not coalesce(p.archived,false)) then
   raise exception 'Active agent not found' using errcode='22023';
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values (auth.uid(),'agent_support_view','profile',p_agent::text,jsonb_build_object('mode','read_only'));
 return true;
end $function$
;
CREATE OR REPLACE FUNCTION private.sales_board_divisions()
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.profiles%rowtype;
begin
 select * into p from public.profiles where id=auth.uid() and active and not coalesce(archived,false);
 if not found or p.role not in ('admin','agent') then return array[]::text[];end if;
 if p.role='agent' and not private.verified_portal_session() then return array[]::text[];end if;
 if p.division='legacy_life' and not p.is_super_admin then return array['legacy_life'];end if;
 return array(select id from public.divisions where id<>'legacy_life' order by created_at,id);
end $function$
;

alter policy "agent mfa required leads" on public.leads using((select public.is_admin()) or (select private.verified_portal_session())) with check((select public.is_admin()) or (select private.verified_portal_session()));
alter policy "agent mfa required closed business" on public.closed_business using((select public.is_admin()) or (select private.verified_portal_session())) with check((select public.is_admin()) or (select private.verified_portal_session()));
alter policy onboarding_read_own on public.portal_onboarding_receipts using(user_id=(select auth.uid()) and (select private.verified_portal_session()));
alter policy onboarding_acknowledge_own on public.portal_onboarding_receipts with check(user_id=(select auth.uid()) and completion_kind='acknowledged' and (select private.verified_portal_session()) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.role in ('agent','admin')));
notify pgrst,'reload schema';

