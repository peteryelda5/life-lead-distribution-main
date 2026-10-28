-- Requires the existing leaderboard API key registry. No sale records are modified.
create function private.submitted_deals_api_read(p_key_hash text,p_period text default 'month',p_month date default null,p_after uuid default null,p_limit integer default 200)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare credential private.leaderboard_api_keys%rowtype;
 localnow timestamp:=now() at time zone 'America/Detroit';
 startlocal timestamp;endlocal timestamp;startat timestamptz;endat timestamptz;
 rows_json jsonb; next_id uuid;
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
 if p_limit is null or p_limit<1 or p_limit>500 then return jsonb_build_object('status',400);end if;
 if credential.window_start>now()-interval '1 minute' and credential.window_count>=60 then return jsonb_build_object('status',429);end if;
 update private.leaderboard_api_keys set last_used_at=now(),
  window_start=case when window_start>now()-interval '1 minute' then window_start else now() end,
  window_count=case when window_start>now()-interval '1 minute' then window_count+1 else 1 end where key_hash=p_key_hash;
 startat:=startlocal at time zone 'America/Detroit';endat:=least(endlocal at time zone 'America/Detroit',now());
 -- Submission records only: never join CRM policies, carrier status or pipeline stages.
 -- Scope stays fixed on the server. The external agency label is deliberately constant.
 with page as materialized (
  select cb.id,cb.agent_id,p.full_name,cb.monthly_premium,cb.annual_premium,cb.created_at
  from public.closed_business cb join public.profiles p on p.id=cb.agent_id
  left join public.leads l on l.id=cb.lead_id
  where coalesce(l.division,p.division)=any(credential.allowed_divisions)
   and cb.created_at>=startat and cb.created_at<endat
   and (p_after is null or cb.id>p_after)
  order by cb.id limit p_limit+1
 ), numbered as (select *,row_number() over(order by id) rn from page)
 select coalesce(jsonb_agg(jsonb_build_object(
  'deal_id',id,'agent_id',agent_id,'agent_name',coalesce(full_name,''),
  'agency','Vivid Life Advisors','monthly_premium',monthly_premium,
  'annual_premium',annual_premium,'submitted_at',created_at) order by id) filter(where rn<=p_limit),'[]'::jsonb),
  case when count(*)>p_limit then (array_agg(id order by id))[p_limit] else null end
 into rows_json,next_id from numbered;
 return jsonb_build_object('status',200,'data',jsonb_build_object('as_of',now(),
  'period',jsonb_build_object('key',p_period,'start',startlocal::date,'end_exclusive',endlocal::date),
  'deals',rows_json,'next_after',next_id));
end $$;
revoke all on function private.submitted_deals_api_read(text,text,date,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function private.submitted_deals_api_read(text,text,date,uuid,integer) to service_role;
create function public.submitted_deals_api_read(p_key_hash text,p_period text default 'month',p_month date default null,p_after uuid default null,p_limit integer default 200)
returns jsonb language sql volatile security invoker set search_path='' as $$select private.submitted_deals_api_read(p_key_hash,p_period,p_month,p_after,p_limit)$$;
revoke all on function public.submitted_deals_api_read(text,text,date,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function public.submitted_deals_api_read(text,text,date,uuid,integer) to service_role;
