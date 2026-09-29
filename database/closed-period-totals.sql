create function public.closed_period_totals(p_division text default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare admin boolean; today date;
begin
 admin:=public.is_admin();
 if auth.uid() is null or (not admin and not public.is_active_agent()) then raise exception 'Account access denied' using errcode='42501';end if;
 if admin and (p_division is null or (p_division<>'all' and not public.admin_can_access_division(p_division))) then raise exception 'Division access denied' using errcode='42501';end if;
 today:=(now() at time zone 'America/Detroit')::date;
 return (with periods(key,label,start_date,end_date) as(values
 ('all','All time',null::date,null::date),('today','Today',today,today+1),
 ('week','This week',date_trunc('week',today::timestamp)::date,date_trunc('week',today::timestamp)::date+7),
 ('month','This month',date_trunc('month',today::timestamp)::date,(date_trunc('month',today::timestamp)+interval '1 month')::date)),
 sales as materialized (
 select c.monthly_premium,c.annual_premium,coalesce(c.application_date,(c.created_at at time zone 'America/Detroit')::date) sale_date
 from public.closed_business c join public.profiles a on a.id=c.agent_id
 where (admin and (p_division='all' or a.division=p_division)) or (not admin and c.agent_id=auth.uid())
 )
 select jsonb_object_agg(key,jsonb_build_object('label',label,'start_date',start_date,'end_date',end_date,
 'start_at',start_date::timestamp at time zone 'America/Detroit','end_at',end_date::timestamp at time zone 'America/Detroit',
 'count',n,'monthly_premium',mp,'annual_premium',ap)) from (
 select p.*,count(s.sale_date) n,coalesce(sum(s.monthly_premium),0) mp,coalesce(sum(s.annual_premium),0) ap
 from periods p left join sales s on p.key='all' or (s.sale_date>=p.start_date and s.sale_date<p.end_date)
 group by p.key,p.label,p.start_date,p.end_date)x);
end $$;
revoke all on function public.closed_period_totals(text) from public,anon;
grant execute on function public.closed_period_totals(text) to authenticated;
