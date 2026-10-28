-- Restricted external leaderboard API. No change to portal roles or existing RPCs.
create table private.leaderboard_api_keys (
 key_hash text primary key check (key_hash ~ '^[0-9a-f]{64}$'),
 label text not null,
 scope_name text not null,
 allowed_divisions text[] not null check (cardinality(allowed_divisions)>0 and array_position(allowed_divisions,null) is null),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '1 year',
 revoked_at timestamptz,
 last_used_at timestamptz,
 window_start timestamptz,
 window_count integer not null default 0 check (window_count>=0)
);
alter table private.leaderboard_api_keys enable row level security;
revoke all on private.leaderboard_api_keys from public,anon,authenticated,service_role;
grant select on private.leaderboard_api_keys to service_role;
grant update(last_used_at,window_start,window_count) on private.leaderboard_api_keys to service_role;
-- Only the existing trusted backend role can read the needed import columns.
grant select(month,division,entry_key,display_name,ap_adjustment) on private.leaderboard_monthly_import to service_role;

create function private.leaderboard_api_read(p_key_hash text,p_period text default 'month',p_month date default null)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare credential private.leaderboard_api_keys%rowtype;
 localnow timestamp:=now() at time zone 'America/Detroit';
 startlocal timestamp;endlocal timestamp;startat timestamptz;endat timestamptz;
 ranking jsonb;total_ap numeric;total_deals bigint;has_imports boolean;
begin
 -- Machine credential boundary, enforced again in addition to function grants.
 if current_user not in ('service_role','postgres') then raise insufficient_privilege;end if;
 if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('status',401);end if;
 select * into credential from private.leaderboard_api_keys where key_hash=p_key_hash for update;
 if not found or credential.revoked_at is not null or credential.expires_at<=now() then return jsonb_build_object('status',401);end if;
 if p_period is null or p_period not in ('today','week','month','previous') or (p_period<>'previous' and p_month is not null) then return jsonb_build_object('status',400);end if;
 if p_period='today' then startlocal:=date_trunc('day',localnow);endlocal:=startlocal+interval '1 day';
 elsif p_period='week' then startlocal:=date_trunc('week',localnow);endlocal:=startlocal+interval '1 week';
 else
  if p_period='previous' and (p_month is null or p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',localnow)::date) then return jsonb_build_object('status',400);end if;
  startlocal:=case when p_period='month' then date_trunc('month',localnow) else p_month::timestamp end;endlocal:=startlocal+interval '1 month';
 end if;
 if credential.window_start>now()-interval '1 minute' and credential.window_count>=60 then return jsonb_build_object('status',429);end if;
 update private.leaderboard_api_keys set last_used_at=now(),
  window_start=case when window_start>now()-interval '1 minute' then window_start else now() end,
  window_count=case when window_start>now()-interval '1 minute' then window_count+1 else 1 end where key_hash=p_key_hash;
 startat:=startlocal at time zone 'America/Detroit';endat:=least(endlocal at time zone 'America/Detroit',now());
 select exists(select 1 from private.leaderboard_monthly_import where p_period in('month','previous') and month=startlocal::date and division=any(credential.allowed_divisions)) into has_imports;
 -- Same date boundaries, attribution, imports, roster, and ordering as private.leaderboard_period.
 -- No customer details, policy details, notes, email, phone, or internal IDs leave this function.
 with sales as materialized (
  select cb.agent_id,p.full_name agent_name,cb.annual_premium
  from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id
  where coalesce(l.division,p.division)=any(credential.allowed_divisions) and cb.created_at>=startat and cb.created_at<endat
 ), actual as (
  select agent_id::text entry_key,max(agent_name) agent_name,sum(annual_premium) ap,count(*) deals from sales group by agent_id
 ), imports as (
  select entry_key,max(display_name) agent_name,sum(ap_adjustment) adjustment from private.leaderboard_monthly_import
  where has_imports and month=startlocal::date and division=any(credential.allowed_divisions) group by entry_key
 ), ranked as (
  select coalesce(a.entry_key,i.entry_key) entry_key,coalesce(a.agent_name,i.agent_name) agent_name,
   coalesce(a.ap,0)+coalesce(i.adjustment,0) annual_premium,coalesce(a.ap,0) recorded_annual_premium,coalesce(i.adjustment,0) imported_annual_premium_adjustment,
   case when i.entry_key is null then coalesce(a.deals,0) end deals from actual a full join imports i using(entry_key)
 ), roster as (
  select * from ranked union all
  select p.id::text,p.full_name,0::numeric,0::numeric,0::numeric,0::bigint from public.profiles p
  where p.role='agent' and p.active and not coalesce(p.archived,false) and p.division=any(credential.allowed_divisions)
   and not exists(select 1 from ranked r where r.entry_key=p.id::text)
 )
 select coalesce(jsonb_agg(jsonb_build_object('agent_name',r.agent_name,'annual_premium',r.annual_premium,
  'recorded_annual_premium',r.recorded_annual_premium,'imported_annual_premium_adjustment',r.imported_annual_premium_adjustment,'deals',r.deals)
  order by r.annual_premium desc,r.agent_name),'[]'::jsonb),coalesce(sum(r.annual_premium),0),case when has_imports then null else coalesce(sum(r.deals),0)::bigint end
 into ranking,total_ap,total_deals from roster r;
 return jsonb_build_object('status',200,'data',jsonb_build_object('scope',credential.scope_name,'as_of',now(),
  'period',jsonb_build_object('key',p_period,'start',startlocal::date,'end_exclusive',endlocal::date),
  'totals',jsonb_build_object('annual_premium',total_ap,'deals',total_deals),'rankings',ranking));
end $$;
revoke all on function private.leaderboard_api_read(text,text,date) from public,anon,authenticated,service_role;
grant execute on function private.leaderboard_api_read(text,text,date) to service_role;

create function public.leaderboard_api_read(p_key_hash text,p_period text default 'month',p_month date default null)
returns jsonb language sql volatile security invoker set search_path='' as $$select private.leaderboard_api_read(p_key_hash,p_period,p_month)$$;
revoke all on function public.leaderboard_api_read(text,text,date) from public,anon,authenticated,service_role;
grant execute on function public.leaderboard_api_read(text,text,date) to service_role;
