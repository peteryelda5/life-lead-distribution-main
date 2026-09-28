create or replace function private.sales_board_divisions() returns text[] language plpgsql stable security definer set search_path='' as $$
declare p public.profiles%rowtype;
begin
 select * into p from public.profiles where id=auth.uid() and active and not coalesce(archived,false);
 if not found or p.role not in ('admin','agent') then return array[]::text[];end if;
 if p.role='agent' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then return array[]::text[];end if;
 if p.division='legacy_life' and not p.is_super_admin then return array['legacy_life'];end if;
 return array(select id from public.divisions where id<>'legacy_life' order by created_at,id);
end $$;
revoke all on function private.sales_board_divisions() from public,anon;
grant execute on function private.sales_board_divisions() to authenticated;
CREATE OR REPLACE FUNCTION private.recorded_leaderboard_data(p_division text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare scopes text[]; chosen text[]; result jsonb;
 today_start timestamptz := date_trunc('day',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 week_start timestamptz := date_trunc('week',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 month_start timestamptz := date_trunc('month',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 year_start timestamptz := date_trunc('year',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
begin
 scopes:=private.sales_board_divisions();
 if cardinality(scopes)=0 then raise exception 'Active account and required verification needed' using errcode='42501'; end if;
 if p_division is null or p_division='all' then chosen:=scopes;
 elsif p_division=any(scopes) then chosen:=array[p_division];
 else raise exception 'Division access denied' using errcode='42501'; end if;
 with sales as materialized (
 select cb.id,cb.agent_id,coalesce(p.full_name,'Former agent') agent_name,coalesce(l.division,p.division) division,cb.carrier,cb.policy_type,cb.monthly_premium,cb.annual_premium,cb.created_at
 from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id
 where coalesce(l.division,p.division)=any(chosen) and cb.created_at>=least(year_start,week_start) and cb.created_at<=now()
 ), ranked as (
 select s.agent_id,max(s.agent_name) agent_name,count(*) deals,coalesce(sum(s.annual_premium),0) ap,coalesce(sum(s.monthly_premium),0) mp
 from sales s where s.created_at>=month_start group by s.agent_id
 ), roster as (
 select r.agent_id,r.agent_name,r.deals,r.ap,r.mp from ranked r
 union all select p.id,p.full_name,0::bigint,0::numeric,0::numeric from public.profiles p where p.role='agent' and p.active and not coalesce(p.archived,false) and p.division=any(chosen) and not exists(select 1 from ranked r where r.agent_id=p.id)
 ), feed as (select id,agent_name,carrier,policy_type,monthly_premium,annual_premium,created_at from sales where created_at>=today_start order by created_at desc,id desc limit 50)
 select jsonb_build_object(
 'scopes',scopes,'division',coalesce(p_division,'all'),'timezone','America/Detroit','as_of',now(),
 'totals', (select jsonb_build_object(
 'today_ap',coalesce(sum(annual_premium) filter(where created_at>=today_start),0),'today_deals',count(*) filter(where created_at>=today_start),
 'week_ap',coalesce(sum(annual_premium) filter(where created_at>=week_start),0),'week_deals',count(*) filter(where created_at>=week_start),
 'month_ap',coalesce(sum(annual_premium) filter(where created_at>=month_start),0),'month_mp',coalesce(sum(monthly_premium) filter(where created_at>=month_start),0),'month_deals',count(*) filter(where created_at>=month_start),
 'year_ap',coalesce(sum(annual_premium) filter(where created_at>=year_start),0),'year_deals',count(*) filter(where created_at>=year_start),
 'active_producers',count(distinct agent_id) filter(where created_at>=month_start)) from sales),
 'rankings',coalesce((select jsonb_agg(to_jsonb(r) order by r.ap desc,r.deals desc,r.agent_name,r.agent_id) from roster r),'[]'::jsonb),
 'today_feed',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc,f.id desc) from feed f),'[]'::jsonb)
 ) into result;
 return result;
end $function$
;
CREATE OR REPLACE FUNCTION private.live_leaderboard_data(p_division text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;chosen text[];m date:=(date_trunc('month',now() at time zone 'America/Detroit'))::date;adjustment numeric;year_adjustment numeric;ranking jsonb;has_month boolean;has_year boolean;
begin
 result:=private.recorded_leaderboard_data(p_division);
 chosen:=case when p_division is null or p_division='all' then private.sales_board_divisions() else array[p_division] end;
 select coalesce(sum(ap_adjustment),0),count(*)>0 into adjustment,has_month from private.leaderboard_monthly_import where month=m and division=any(chosen);
 select coalesce(sum(ap_adjustment),0),count(*)>0 into year_adjustment,has_year from private.leaderboard_monthly_import where month>=date_trunc('year',m)::date and month<=m and division=any(chosen);
 if has_year then
  result:=jsonb_set(result,'{totals,year_ap}',to_jsonb((result->'totals'->>'year_ap')::numeric+year_adjustment));
  result:=jsonb_set(result,'{totals,year_deals}','null'::jsonb);
 end if;
 if not has_month then return result;end if;
 with actual as (select r->>'agent_id' as entry_key,r from jsonb_array_elements(result->'rankings') r), imported as (
 select entry_key,max(display_name) display_name,sum(ap_adjustment) adjustment from private.leaderboard_monthly_import where month=m and division=any(chosen) group by entry_key
 ), merged as (
 select coalesce(a.entry_key,i.entry_key) agent_id,coalesce(a.r->>'agent_name',i.display_name) agent_name,
 coalesce((a.r->>'ap')::numeric,0)+coalesce(i.adjustment,0) ap,
 case when i.entry_key is null then (a.r->>'deals')::bigint end deals,
 case when i.entry_key is null then (a.r->>'mp')::numeric end mp,
 i.entry_key is not null imported
 from actual a full join imported i using(entry_key)
 ) select coalesce(jsonb_agg(to_jsonb(x) order by ap desc,agent_name),'[]'::jsonb) into ranking from merged x;
 result:=jsonb_set(result,'{rankings}',ranking);
 result:=jsonb_set(result,'{totals,month_ap}',to_jsonb((result->'totals'->>'month_ap')::numeric+adjustment));
 result:=jsonb_set(result,'{totals,month_deals}','null'::jsonb);
 result:=jsonb_set(result,'{totals,month_mp}','null'::jsonb);
 result:=jsonb_set(result,'{totals,active_producers}',to_jsonb((select count(*) from jsonb_array_elements(ranking) r where (r->>'ap')::numeric>0)));
 result:=result||jsonb_build_object('imported_month',m,'import_note','September includes imported AP totals. Historical deal counts and monthly premiums were not supplied. New recorded deals add automatically.');
 if m=date '2026-09-01' and array['owner','vivid_life']::text[]<@chosen then result:=result||jsonb_build_object('month_goal',100000);end if;
 return result;
end $function$
;
CREATE OR REPLACE FUNCTION private.leaderboard_period(p_division text DEFAULT NULL::text, p_period text DEFAULT 'month'::text, p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare scopes text[]:=private.sales_board_divisions(); chosen text[]; localnow timestamp:=now() at time zone 'America/Detroit'; startlocal timestamp; endlocal timestamp; startat timestamptz; endat timestamptz; result jsonb; ranking jsonb; feed jsonb; ap numeric; mp numeric; deals bigint; imported boolean:=false; adj numeric:=0; months jsonb;
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
 return result||jsonb_build_object('scope_names',(select jsonb_object_agg(id,name) from public.divisions where id=any(scopes)),'rankings',ranking,'today_feed',feed,'available_months',months,'period',jsonb_build_object('key',p_period,'start',startlocal::date,'end',endlocal::date,'label',case when p_period='today' then 'Today' when p_period='week' then 'This week' else to_char(startlocal,'FMMonth YYYY') end,'ap',ap,'mp',mp,'deals',deals,'active_producers',(select count(*) from jsonb_array_elements(ranking) r where (r->>'ap')::numeric>0),'imported',imported,'goal',case when startlocal::date=date '2026-09-01' and p_period in('month','previous') and array['owner','vivid_life']::text[]<@chosen then 100000 end));
end $function$
;
alter policy leaderboard_updates_read on public.leaderboard_updates using (division=any(private.sales_board_divisions()));
