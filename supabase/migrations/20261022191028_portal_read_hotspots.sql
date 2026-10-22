-- Keep accurate lead totals with small transactionally maintained aggregates.
-- No client fields, authorization changes, cached counts or elevated dashboard rights.
set local lock_timeout='3s';
create table private.dashboard_lead_totals (
 division text not null,status text not null,assigned_key uuid not null,created_day date not null,
 lead_count bigint not null,primary key(division,status,assigned_key,created_day)
);
alter table private.dashboard_lead_totals enable row level security;
revoke all on private.dashboard_lead_totals from public,anon,authenticated;

create function private.dashboard_lead_totals_sync() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='TRUNCATE' then
  delete from private.dashboard_lead_totals;
 elsif TG_OP='INSERT' then
  insert into private.dashboard_lead_totals as totals
  select coalesce(division,''),coalesce(status::text,''),coalesce(assigned_to,'00000000-0000-0000-0000-000000000000'::uuid),coalesce((created_at at time zone 'UTC')::date,date '0001-01-01'),count(*)
  from new_rows group by 1,2,3,4 order by 1,2,3,4
  on conflict(division,status,assigned_key,created_day) do update set lead_count=totals.lead_count+excluded.lead_count;
 elsif TG_OP='DELETE' then
  insert into private.dashboard_lead_totals as totals
  select coalesce(division,''),coalesce(status::text,''),coalesce(assigned_to,'00000000-0000-0000-0000-000000000000'::uuid),coalesce((created_at at time zone 'UTC')::date,date '0001-01-01'),-count(*)
  from old_rows group by 1,2,3,4 order by 1,2,3,4
  on conflict(division,status,assigned_key,created_day) do update set lead_count=totals.lead_count+excluded.lead_count;
 else
  insert into private.dashboard_lead_totals as totals
  select coalesce(division,''),coalesce(status,''),coalesce(assigned_to,'00000000-0000-0000-0000-000000000000'::uuid),coalesce(day,date '0001-01-01'),sum(delta)::bigint
  from (select division,status::text,assigned_to,(created_at at time zone 'UTC')::date as day,1 as delta from new_rows
        union all select division,status::text,assigned_to,(created_at at time zone 'UTC')::date,-1 from old_rows) changes
  group by 1,2,3,4 having sum(delta)<>0 order by 1,2,3,4
  on conflict(division,status,assigned_key,created_day) do update set lead_count=totals.lead_count+excluded.lead_count;
 end if;
 return null;
end;$$;
revoke all on function private.dashboard_lead_totals_sync() from public,anon,authenticated;
-- Installing triggers locks writes until this transaction's backfill commits, avoiding a gap.
create trigger dashboard_leads_insert after insert on public.leads referencing new table as new_rows for each statement execute function private.dashboard_lead_totals_sync();
create trigger dashboard_leads_update after update on public.leads referencing old table as old_rows new table as new_rows for each statement execute function private.dashboard_lead_totals_sync();
create trigger dashboard_leads_delete after delete on public.leads referencing old table as old_rows for each statement execute function private.dashboard_lead_totals_sync();
create trigger dashboard_leads_truncate after truncate on public.leads for each statement execute function private.dashboard_lead_totals_sync();
insert into private.dashboard_lead_totals
select coalesce(division,''),coalesce(status::text,''),coalesce(assigned_to,'00000000-0000-0000-0000-000000000000'::uuid),coalesce((created_at at time zone 'UTC')::date,date '0001-01-01'),count(*)
from public.leads group by 1,2,3,4;

create function private.dashboard_lead_rollup(p_division text)
returns table(status text,assigned_to uuid,day date,n bigint)
language plpgsql stable security definer set search_path='' as $$
declare master boolean; scopes text[];
begin
 if not coalesce(public.is_admin(),false) then raise exception 'Admin only' using errcode='42501';end if;
 -- Match the original restrictive lead RLS behavior: unverified callers see no totals.
 if not private.verified_portal_session() then return;end if;
 master:=coalesce(public.is_super_admin(),false);scopes:=private.my_admin_divisions();
 if p_division is null or (not master and not coalesce(p_division=any(scopes),false)) then raise exception 'Division access denied' using errcode='42501';end if;
 return query select t.status,nullif(t.assigned_key,'00000000-0000-0000-0000-000000000000'::uuid),nullif(t.created_day,date '0001-01-01'),t.lead_count
 from private.dashboard_lead_totals t
 where t.lead_count>0 and (p_division='all' or t.division=p_division)
 and (master or t.division=any(scopes));
end;$$;
revoke all on function private.dashboard_lead_rollup(text) from public,anon,authenticated;
grant execute on function private.dashboard_lead_rollup(text) to authenticated;

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
  select status,assigned_to,day,sum(n) n
  from private.dashboard_lead_rollup(v_div)
  group by status,assigned_to,day
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
-- Normalize phone numbers once per changed lead, rather than for every callback refresh.
create index leads_callback_match_idx on public.leads (assigned_to,private.dialer_callback_phone(phone,csv_headers,csv_values),id) where status='assigned';
CREATE OR REPLACE FUNCTION public.dialer_priority_list(p_user uuid, p_live boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
 perform private.dialer_priority_sync(p_user,p_live);
 with eligible as (
  select t.* from public.dialer_priority_tasks t where t.user_id=p_user and t.livemode=p_live and t.resolved_at is null
  and (t.source='incoming' or exists(select 1 from public.leads l where l.id=t.lead_id and l.assigned_to=p_user and l.status='assigned'))
 ), page as (select * from eligible order by (due_at<=now()) desc,due_at,id limit 50)
 select jsonb_build_object('total',(select count(*) from eligible),'due',(select count(*) from eligible where due_at<=now()),'tasks',coalesce((select jsonb_agg(to_jsonb(x) order by x.due_at,x.id) from (
  select p.id,p.source,p.source_id,p.phone,p.reason,p.note,p.due_at,p.created_at,
   coalesce((select jsonb_agg(to_jsonb(l)) from (
    select l.id,l.first_name,l.last_name,l.phone,l.email,l.state,l.lead_type,l.agent_status,l.call_notes,l.csv_headers,l.csv_values
    from public.leads l where l.assigned_to=p_user and l.status='assigned' and (
     (p.source<>'incoming' and l.id=p.lead_id) or (p.source='incoming' and private.dialer_callback_phone(l.phone,l.csv_headers,l.csv_values)=p.phone))
    order by l.id limit 20) l),'[]'::jsonb) matches
  from page p) x),'[]'::jsonb)) into result;
 return result;
end $function$
;
notify pgrst,'reload schema';
