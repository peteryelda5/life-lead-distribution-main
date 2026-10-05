create or replace function public.nova_agent_activity()
returns table(agent_id uuid, full_name text, assigned_leads bigint, closed_count bigint, annual_premium numeric)
language sql security definer set search_path = ''
as $function$
 with permitted as (
  select 1 where (select auth.jwt()->>'role')='service_role'
   or ((select public.is_super_admin()) and (select private.verified_portal_session()))
 ), agents as (
  select p.id,p.full_name from public.profiles p
  where p.active is true and not coalesce(p.archived,false)
   and p.role='agent' and p.division in ('owner','vivid_life')
   and exists(select 1 from permitted)
 ), lead_totals as (
  select l.assigned_to,count(*)::bigint as assigned_leads
  from public.leads l join agents a on a.id=l.assigned_to
  where l.status='assigned' and l.division in ('owner','vivid_life') group by l.assigned_to
 ), deal_totals as (
  select cb.agent_id,count(*)::bigint as closed_count,coalesce(sum(cb.annual_premium),0)::numeric as annual_premium
  from public.closed_business cb join agents a on a.id=cb.agent_id group by cb.agent_id
 )
 select a.id,a.full_name,coalesce(l.assigned_leads,0)::bigint,coalesce(d.closed_count,0)::bigint,coalesce(d.annual_premium,0)::numeric
 from agents a left join lead_totals l on l.assigned_to=a.id left join deal_totals d on d.agent_id=a.id
 order by coalesce(d.closed_count,0) desc,coalesce(l.assigned_leads,0) desc,a.full_name limit 12;
$function$;
revoke all on function public.nova_agent_activity() from public,anon;
grant execute on function public.nova_agent_activity() to authenticated,service_role;