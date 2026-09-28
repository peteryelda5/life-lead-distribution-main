create or replace function private.leaderboard_period(p_division text default null,p_period text default 'month',p_month date default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare scopes text[]:=private.leaderboard_divisions(); chosen text[]; localnow timestamp:=now() at time zone 'America/Detroit'; startlocal timestamp; endlocal timestamp; startat timestamptz; endat timestamptz; result jsonb; ranking jsonb; feed jsonb; ap numeric; mp numeric; deals bigint; imported boolean:=false; adj numeric:=0; months jsonb;
begin
 if cardinality(scopes)=0 then raise exception 'Active verified account required' using errcode='42501';end if;
 if p_division is null or p_division='all' then chosen:=scopes;elsif p_division=any(scopes) then chosen:=array[p_division];else raise exception 'Division access denied' using errcode='42501';end if;
 if p_period='today' then startlocal:=date_trunc('day',localnow);endlocal:=startlocal+interval '1 day';
 elsif p_period='week' then startlocal:=date_trunc('week',localnow);endlocal:=startlocal+interval '1 week';
 elsif p_period in ('month','previous') then
  if p_period='previous' and (p_month is null or p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',localnow)::date) then raise exception 'Choose a previous month';end if;
  startlocal:=case when p_period='month' then date_trunc('month',localnow) else p_month::timestamp end;endlocal:=startlocal+interval '1 month';
 else raise exception 'Invalid leaderboard period';end if;
 startat:=startlocal at time zone 'America/Detroit';endat:=least(endlocal at time zone 'America/Detroit',now());
 if p_period in ('month','previous') then select coalesce(sum(ap_adjustment),0),count(*)>0 into adj,imported from private.leaderboard_monthly_import where month=startlocal::date and division=any(chosen);end if;
 with sales as materialized (
 select cb.id,cb.agent_id,p.full_name agent_name,cb.carrier,cb.policy_type,cb.monthly_premium,cb.annual_premium,cb.created_at
 from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id where coalesce(l.division,p.division)=any(chosen) and cb.created_at>=startat and cb.created_at<endat
 ), actual as (select agent_id::text entry_key,max(agent_name) agent_name,sum(annual_premium) ap,sum(monthly_premium) mp,count(*) deals from sales group by agent_id),
 imports as(select entry_key,max(display_name) agent_name,sum(ap_adjustment) adjustment from private.leaderboard_monthly_import where imported and month=startlocal::date and division=any(chosen) group by entry_key),
 ranked as(select coalesce(a.entry_key,i.entry_key) agent_id,coalesce(a.agent_name,i.agent_name) agent_name,coalesce(a.ap,0)+coalesce(i.adjustment,0) ap,case when i.entry_key is null then coalesce(a.mp,0) end mp,case when i.entry_key is null then coalesce(a.deals,0) end deals from actual a full join imports i using(entry_key)),
 roster as(select * from ranked union all select p.id::text,p.full_name,0::numeric,0::numeric,0::bigint from public.profiles p where p.role='agent' and p.active and not coalesce(p.archived,false) and p.division=any(chosen) and not exists(select 1 from ranked r where r.agent_id=p.id::text))
 select (select coalesce(jsonb_agg(to_jsonb(r) order by r.ap desc,r.agent_name),'[]') from roster r),
 (select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at desc,f.id desc),'[]') from(select id,agent_name,carrier,policy_type,monthly_premium,annual_premium,created_at from sales order by created_at desc,id desc limit 50)f),
 coalesce(sum(annual_premium),0)+adj,case when imported then null else coalesce(sum(monthly_premium),0) end,case when imported then null else count(*) end
 into ranking,feed,ap,mp,deals from sales;
 select coalesce(jsonb_agg(m order by m desc),'[]') into months from (select distinct date_trunc('month',cb.created_at at time zone 'America/Detroit')::date m from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id where coalesce(l.division,p.division)=any(chosen)
 union select month from private.leaderboard_monthly_import where division=any(chosen)) x where m<date_trunc('month',localnow)::date;
 result:=private.live_leaderboard_data(p_division);
 return result||jsonb_build_object('rankings',ranking,'today_feed',feed,'available_months',months,'period',jsonb_build_object('key',p_period,'start',startlocal::date,'end',endlocal::date,'label',case when p_period='today' then 'Today' when p_period='week' then 'This week' else to_char(startlocal,'FMMonth YYYY') end,'ap',ap,'mp',mp,'deals',deals,'active_producers',(select count(*) from jsonb_array_elements(ranking) r where (r->>'ap')::numeric>0),'imported',imported,'goal',case when startlocal::date=date '2026-09-01' and p_period in('month','previous') and array['owner','vivid_life']::text[]<@chosen then 100000 end));
end $$;
create or replace function public.leaderboard_period(p_division text default null,p_period text default 'month',p_month date default null) returns jsonb language sql security invoker set search_path='' as $$select private.leaderboard_period(p_division,p_period,p_month);$$;
revoke all on function private.leaderboard_period(text,text,date),public.leaderboard_period(text,text,date) from public,anon;
grant execute on function private.leaderboard_period(text,text,date),public.leaderboard_period(text,text,date) to authenticated;
notify pgrst,'reload schema';
