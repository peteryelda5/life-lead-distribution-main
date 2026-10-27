-- Agency-owned caller IDs. Disabled until numbers and controlled calls are verified.
create table public.dialer_caller_pools (
 id uuid primary key default gen_random_uuid(), division text not null unique,
 provider_sid text not null check(provider_sid ~ '^AC[0-9a-fA-F]{32}$'),
 fallback_user uuid not null references public.profiles(id),
 enabled boolean not null default false, created_at timestamptz not null default now()
);
create table public.dialer_pool_numbers (
 pool_id uuid not null references public.dialer_caller_pools(id),
 slot integer not null check(slot between 1 and 20), phone text not null unique check(phone ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),
 provider_number_sid text unique, state text not null default 'planned' check(state in ('planned','purchasing','active','paused')),
 purchase_key uuid not null unique default gen_random_uuid(), last_used_at timestamptz,
 primary key(pool_id,slot)
);
create table public.dialer_pool_routes (
 caller_id text not null references public.dialer_pool_numbers(phone), phone text not null,
 user_id uuid not null references public.profiles(id), lead_id uuid references public.leads(id) on delete set null,
 created_at timestamptz not null default now(), last_used_at timestamptz not null default now(),
 primary key(caller_id,phone)
);
create index dialer_pool_routes_user on public.dialer_pool_routes(user_id);
create index dialer_pool_routes_lead on public.dialer_pool_routes(lead_id);
alter table public.dialer_parallel_sessions add column caller_pool_id uuid references public.dialer_caller_pools(id);
alter table public.dialer_parallel_legs add column caller_id text;
create index dialer_parallel_caller_pool on public.dialer_parallel_sessions(caller_pool_id) where caller_pool_id is not null;

alter table public.dialer_caller_pools enable row level security;
alter table public.dialer_pool_numbers enable row level security;
alter table public.dialer_pool_routes enable row level security;
revoke all on public.dialer_caller_pools,public.dialer_pool_numbers,public.dialer_pool_routes from public,anon,authenticated;
grant all on public.dialer_caller_pools,public.dialer_pool_numbers,public.dialer_pool_routes to service_role;
create policy service_only on public.dialer_caller_pools to service_role using(true) with check(true);
create policy service_only on public.dialer_pool_numbers to service_role using(true) with check(true);
create policy service_only on public.dialer_pool_routes to service_role using(true) with check(true);

create function public.dialer_pool_options(p_user uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('id',pool.id,'providerSid',pool.provider_sid,'count',count(n.phone))
 from public.profiles p join public.dialer_caller_pools pool on pool.division=p.division
 join public.dialer_pool_numbers n on n.pool_id=pool.id and n.state='active'
 where p.id=p_user and p.active and not p.archived and pool.enabled
 group by pool.id having count(n.phone)>0;
$$;

-- Preserve existing personal-account eligibility; explicitly add the agency's configured account.
create or replace function public.dialer_parallel_can_call(p_user uuid,p_account text)
returns boolean language sql stable security invoker set search_path='' as $$
 select public.dialer_parallel_allowed(p_user) and public.dialer_entitled(p_user,true) and (
 exists(select 1 from public.dialer_at_cost where user_id=p_user and enabled and provider_sid=p_account and provider_secret_cipher is not null)
 or not exists(select 1 from public.dialer_at_cost where user_id=p_user and enabled)
 or exists(select 1 from public.profiles p join public.dialer_caller_pools pool on pool.division=p.division
 where p.id=p_user and pool.enabled and pool.provider_sid=p_account));
$$;

create function public.dialer_power_prepare_pool(p_user uuid,p_session uuid,p_id uuid,p_account text,p_caller text,p_leads uuid[],p_phones text[],p_rates numeric[],p_mode text,p_pool uuid)
returns uuid language plpgsql security invoker set search_path='' as $$
declare pool public.dialer_caller_pools%rowtype; s public.dialer_parallel_sessions%rowtype; leg record; chosen text; previous text;
begin
 -- Same lock order as personal prepare. A pool lock serializes allocation across agents.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 select * into pool from public.dialer_caller_pools where id=p_pool for update;
 if not found or not pool.enabled or not exists(select 1 from public.profiles where id=p_user and active and not archived and division=pool.division)
 or not private.dialer_session_active(p_user,p_session) or not public.dialer_entitled(p_user,true) then raise exception 'Shared caller IDs are unavailable for this account.';end if;
 select * into s from public.dialer_parallel_sessions where id=p_id;
 if found and s.caller_pool_id is not null then
  if s.user_id<>p_user or s.session_id<>p_session or s.caller_pool_id<>p_pool or s.provider_sid<>pool.provider_sid or s.connect_mode is distinct from p_mode
   or (select array_agg(lead_id order by position) from public.dialer_parallel_legs where session_id=p_id) is distinct from p_leads
   or (select array_agg(phone order by position) from public.dialer_parallel_legs where session_id=p_id) is distinct from p_phones then raise exception 'This batch does not match its original request.';end if;
  return p_id;
 end if;
 perform public.dialer_power_prepare(p_user,p_session,p_id,p_account,p_caller,p_leads,p_phones,p_rates,p_mode);
 select * into s from public.dialer_parallel_sessions where id=p_id;
 if s.state<>'prepared' then raise exception 'This batch has already started.';end if;
 for leg in select * from public.dialer_parallel_legs where session_id=p_id order by position loop
  select caller_id into previous from public.dialer_pool_routes where user_id=p_user and phone=leg.phone order by last_used_at desc limit 1;
  select n.phone into chosen from public.dialer_pool_numbers n
  where n.pool_id=p_pool and n.state='active' and n.phone<>leg.phone
   and not exists(select 1 from public.dialer_pool_routes r where r.caller_id=n.phone and r.phone=leg.phone and r.user_id<>p_user)
  order by (n.phone is distinct from previous) desc,
   (substring(n.phone from 3 for 3)=substring(leg.phone from 3 for 3)) desc,
   n.last_used_at nulls first,n.slot limit 1;
  if chosen is null then raise exception 'No unambiguous shared callback number is available. Ask your administrator to review this lead.';end if;
  insert into public.dialer_pool_routes(caller_id,phone,user_id,lead_id) values(chosen,leg.phone,p_user,leg.lead_id)
   on conflict(caller_id,phone) do update set last_used_at=clock_timestamp(),lead_id=excluded.lead_id;
  update public.dialer_pool_numbers set last_used_at=clock_timestamp() where phone=chosen;
  update public.dialer_parallel_legs set caller_id=chosen where id=leg.id;
  update public.dialer_calls set caller_id=chosen where id=leg.id;
 end loop;
 update public.dialer_parallel_sessions set caller_pool_id=p_pool,provider_sid=pool.provider_sid,
 caller_id=(select caller_id from public.dialer_parallel_legs where session_id=p_id order by position limit 1) where id=p_id;
 return p_id;
end $$;

-- Resolve only a persisted number/recipient pair; never guess between agents.
-- Forward to a personal Twilio number so existing cross-account incoming tokens,
-- availability, voicemail and matching-lead permissions continue to apply.
create function public.dialer_pool_callback_route(p_account text,p_to text,p_from text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare pool public.dialer_caller_pools%rowtype; actor uuid; destination text;
begin
 select p.* into pool from public.dialer_caller_pools p join public.dialer_pool_numbers n on n.pool_id=p.id
 where n.phone=p_to and n.state in ('active','paused') and p.provider_sid=p_account;
 if not found then raise exception 'Unknown shared caller ID.';end if;
 select r.user_id into actor from public.dialer_pool_routes r join public.profiles p on p.id=r.user_id
 where r.caller_id=p_to and r.phone=p_from and p.active and not p.archived and p.division=pool.division
 and (r.lead_id is null or exists(select 1 from public.leads l where l.id=r.lead_id and l.assigned_to=r.user_id));
 if actor is null then actor:=pool.fallback_user;end if;
 select n.phone into destination from public.dialer_numbers n join public.profiles p on p.id=n.user_id
 where n.user_id=actor and n.livemode and n.state='active' and p.active and not p.archived
 and not exists(select 1 from public.dialer_pool_numbers pn where pn.phone=n.phone) order by n.slot limit 1;
 if destination is null then raise exception 'Callback destination requires administrator attention.';end if;
 return jsonb_build_object('phone',destination,'userId',actor);
end $$;
revoke all on function public.dialer_pool_options(uuid),public.dialer_power_prepare_pool(uuid,uuid,uuid,text,text,uuid[],text[],numeric[],text,uuid),public.dialer_pool_callback_route(text,text,text) from public,anon,authenticated;
grant execute on function public.dialer_pool_options(uuid),public.dialer_power_prepare_pool(uuid,uuid,uuid,text,text,uuid[],text[],numeric[],text,uuid),public.dialer_pool_callback_route(text,text,text) to service_role;
