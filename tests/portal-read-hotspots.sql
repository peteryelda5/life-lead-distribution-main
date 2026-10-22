-- Run each rollback-only section separately in the SQL tool.
-- Full client/agent authorization regression: tests/portal-read-performance.sql.

-- 1. Initial/live aggregate parity (no data changes).
begin;
set local statement_timeout='20s';
with expected as materialized (
 select coalesce(division,'') division,coalesce(status::text,'') status,coalesce(assigned_to,'00000000-0000-0000-0000-000000000000'::uuid) assigned_key,coalesce((created_at at time zone 'UTC')::date,date '0001-01-01') created_day,count(*) lead_count
 from public.leads group by 1,2,3,4
), differences as (
 select e.lead_count expected,a.lead_count actual from expected e full join private.dashboard_lead_totals a using(division,status,assigned_key,created_day)
 where coalesce(e.lead_count,0)<>coalesce(a.lead_count,0)
)
select (select count(*) from differences) as mismatched_groups,(select sum(lead_count) from expected) as live_total,(select sum(lead_count) from private.dashboard_lead_totals) as summary_total;
rollback;

-- 2. Exercise exact statement triggers with isolated temporary lead fixtures.
begin;
create temp table speed_leads(id uuid default gen_random_uuid(),division text,status public.lead_status,assigned_to uuid,created_at timestamptz default now(),call_notes text);
create trigger speed_insert after insert on speed_leads referencing new table as new_rows for each statement execute function private.dashboard_lead_totals_sync();
create trigger speed_update after update on speed_leads referencing old table as old_rows new table as new_rows for each statement execute function private.dashboard_lead_totals_sync();
create trigger speed_delete after delete on speed_leads referencing old table as old_rows for each statement execute function private.dashboard_lead_totals_sync();
select set_config('vivid.before',(select sum(lead_count)::text from private.dashboard_lead_totals),true);
insert into speed_leads(division,status) values('__fixture__','unassigned'),('__fixture__','unassigned');
update speed_leads set status='assigned',assigned_to='8139e230-055d-4247-8133-684ed817b4fa',division='__fixture2__',created_at=now()-interval '1 day';
select set_config('vivid.updated',jsonb_build_object('total_delta',(select sum(lead_count)-current_setting('vivid.before')::bigint from private.dashboard_lead_totals),'new_group_count',(select sum(lead_count) from private.dashboard_lead_totals where division='__fixture2__' and status='assigned' and assigned_key='8139e230-055d-4247-8133-684ed817b4fa' and created_day=(now() at time zone 'UTC')::date-1))::text,true);
update speed_leads set call_notes='Note only';
delete from speed_leads;
select current_setting('vivid.updated')::jsonb as update_result,(select sum(lead_count)-current_setting('vivid.before')::bigint from private.dashboard_lead_totals) as final_delta,exists(select 1 from private.dashboard_lead_totals where lead_count<0) as negative_counts;
rollback;
-- 3. Compare the complete old/new Master dashboard result under authenticated RLS.
begin;
set local statement_timeout='25s';
create temp table dashboard_check_marker(x integer);
CREATE OR REPLACE FUNCTION pg_temp.dashboard_baseline(p_division text DEFAULT NULL::text, p_days integer DEFAULT 30)
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
;
select set_config('request.jwt.claims','{"sub":"8139e230-055d-4247-8133-684ed817b4fa","role":"authenticated","aal":"aal2"}',true);
set local role authenticated;
do $test$ declare prior jsonb; result jsonb; t timestamptz; a numeric; b numeric;
begin
 t:=clock_timestamp();prior:=pg_temp.dashboard_baseline('all',30);a:=round(extract(epoch from clock_timestamp()-t)*1000,2);
 t:=clock_timestamp();result:=public.dashboard_overview('all',30);b:=round(extract(epoch from clock_timestamp()-t)*1000,2);
 if result<>prior then raise exception 'Dashboard result changed';end if;
 perform set_config('vivid.speed_parity',jsonb_build_object('same_result',true,'before_ms',a,'after_ms',b)::text,true);
end;$test$;
select current_setting('vivid.speed_parity')::jsonb as result;
rollback;
