-- Scan the RLS-visible lead inventory once; reuse small daily/agent aggregates.
-- Keep invoker rights and all existing role/division checks.
CREATE OR REPLACE FUNCTION public.dashboard_overview(p_division text DEFAULT NULL::text, p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_div text; v_start timestamptz; result jsonb;
begin
 if not coalesce(public.is_admin(),false) then raise exception 'Admin only' using errcode='42501'; end if;
 if p_days is null or p_days not in (7,30,90) then raise exception 'Invalid dashboard period'; end if;
 v_div := coalesce(p_division,public.current_admin_division());
 if v_div is null or (v_div<>'all' and not exists(select 1 from public.divisions where id=v_div)) then raise exception 'Invalid division'; end if;
 if not coalesce(public.is_super_admin(),false) and not public.admin_can_access_division(v_div) then raise exception 'Division access denied' using errcode='42501'; end if;
 v_start := ((current_timestamp at time zone 'UTC')::date - (p_days-1))::timestamp at time zone 'UTC';
 with lead_rollup as materialized (
  select status,assigned_to,(created_at at time zone 'UTC')::date as day,count(*) n
  from public.leads where (v_div='all' or division=v_div)
  group by status,assigned_to,(created_at at time zone 'UTC')::date
 ), inventory as (
  select coalesce(sum(n),0) total_leads,coalesce(sum(n) filter(where status='unassigned'),0) unassigned,
   coalesce(sum(n) filter(where status='assigned'),0) assigned,coalesce(sum(n) filter(where status='closed'),0) closed
  from lead_rollup
 ), sales as materialized (
  select c.agent_id,count(*) closed_count,coalesce(sum(c.monthly_premium),0) monthly_premium,coalesce(sum(c.annual_premium),0) annual_premium
  from public.closed_business c join public.profiles p on p.id=c.agent_id
  where (v_div='all' or p.division=v_div) and c.created_at>=v_start group by c.agent_id
 ), workload as (
  select assigned_to,sum(n) assigned from lead_rollup where status='assigned' and assigned_to is not null group by assigned_to
 ), ranking as (
  select p.id,p.full_name,p.division,p.active,coalesce(p.archived,false) archived,coalesce(w.assigned,0) assigned,
   coalesce(s.closed_count,0) closed_count,coalesce(s.monthly_premium,0) monthly_premium
  from public.profiles p left join workload w on w.assigned_to=p.id left join sales s on s.agent_id=p.id
  where p.role='agent' and (v_div='all' or p.division=v_div) and (not coalesce(p.archived,false) or coalesce(s.closed_count,0)>0 or coalesce(w.assigned,0)>0)
 ), daily as (
  select day,sum(n) n from lead_rollup where day >= (v_start at time zone 'UTC')::date group by day
 ), series as (
  select (v_start at time zone 'UTC')::date+i as day,coalesce(d.n,0) count
  from generate_series(0,p_days-1) i left join daily d on d.day=(v_start at time zone 'UTC')::date+i
 )
 select jsonb_build_object('division',v_div,'days',p_days,'period_start',v_start,'inventory',(select to_jsonb(i) from inventory i),
 'monthly_premium',coalesce((select sum(monthly_premium) from sales),0),'annual_premium',coalesce((select sum(annual_premium) from sales),0),
 'closed_period',coalesce((select sum(closed_count) from sales),0),
 'active_agents',(select count(*) from public.profiles p where p.role='agent' and (v_div='all' or p.division=v_div) and p.active and not coalesce(p.archived,false)),
 'leaderboard',coalesce((select jsonb_agg(to_jsonb(r) order by r.closed_count desc,r.monthly_premium desc,r.assigned desc,r.id) from ranking r),'[]'::jsonb),
 'trend',(select jsonb_agg(to_jsonb(s) order by s.day) from series s)) into result;
 return result;
end $function$

