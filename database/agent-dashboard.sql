begin;
create or replace function private.agent_dashboard(p_agent uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare who uuid:=coalesce(p_agent,auth.uid()); d date:=(now() at time zone 'America/New_York')::date; month_start date; week_start date; result jsonb;
begin
 if not private.verified_portal_session() then raise exception 'Two-step verification required' using errcode='42501';end if;
 if who<>auth.uid() and not exists(select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin and active and not archived) then raise exception 'You may view only your own dashboard' using errcode='42501';end if;
 if not exists(select 1 from public.profiles p join public.divisions a on a.id=p.division where p.id=who and p.role='agent' and p.active and not p.archived and not a.archived) then raise exception 'Active agent not found' using errcode='42501';end if;
 month_start:=date_trunc('month',d)::date; week_start:=date_trunc('week',d)::date;
 with personal as(select * from public.closed_business where agent_id=who)
 select jsonb_build_object('today',jsonb_build_object('count',count(*) filter(where application_date=d),'annual_premium',coalesce(sum(annual_premium) filter(where application_date=d),0),'monthly_premium',coalesce(sum(monthly_premium) filter(where application_date=d),0)),
 'week',jsonb_build_object('count',count(*) filter(where application_date between week_start and d),'annual_premium',coalesce(sum(annual_premium) filter(where application_date between week_start and d),0),'monthly_premium',coalesce(sum(monthly_premium) filter(where application_date between week_start and d),0)),
 'month',jsonb_build_object('count',count(*) filter(where application_date between month_start and d),'annual_premium',coalesce(sum(annual_premium) filter(where application_date between month_start and d),0),'monthly_premium',coalesce(sum(monthly_premium) filter(where application_date between month_start and d),0))) into result from personal;
 return result || jsonb_build_object('agent_id',who,'date',d,
 'assigned',(select count(*) from public.leads where assigned_to=who and status='assigned'),
 'followups',(select count(*) from public.leads where assigned_to=who and status='assigned' and agent_status in ('call_back','appointment_follow_up')),
 'pipeline',coalesce((select jsonb_object_agg(s,n) from(select coalesce(agent_status,'none') s,count(*) n from public.leads where assigned_to=who and status='assigned' group by 1)t),'{}'::jsonb),
 'priorities',coalesce((select jsonb_agg(to_jsonb(t)) from(select id,first_name,last_name,lead_type,agent_status,call_notes from public.leads where assigned_to=who and status='assigned' and agent_status in ('call_back','appointment_follow_up') order by case when agent_status='appointment_follow_up' then 0 else 1 end,updated_at desc,id limit 5)t),'[]'::jsonb),
 'recent',coalesce((select jsonb_agg(to_jsonb(t)) from(select c.id,c.carrier,c.monthly_premium,c.annual_premium,c.application_date,c.created_at,jsonb_build_object('first_name',l.first_name,'last_name',l.last_name,'csv_headers',l.csv_headers,'csv_values',l.csv_values) leads from public.closed_business c left join public.leads l on l.id=c.lead_id where c.agent_id=who order by c.created_at desc,c.id limit 6)t),'[]'::jsonb));
end $$;
revoke all on function private.agent_dashboard(uuid) from public,anon;
grant execute on function private.agent_dashboard(uuid) to authenticated;
create or replace function public.agent_dashboard(p_agent uuid default null) returns jsonb language sql security invoker set search_path='' as $$select private.agent_dashboard(p_agent)$$;
revoke all on function public.agent_dashboard(uuid) from public,anon;
grant execute on function public.agent_dashboard(uuid) to authenticated;
commit;