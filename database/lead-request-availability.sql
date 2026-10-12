-- One aggregate read for the visible request page. Uses the same source and
-- recipient checks as lead_request_delivery_options; no assignments or reservations.
create function private.lead_request_availability(p_request_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not private.verified_portal_session() or not public.is_admin() then
    raise exception 'An active admin with two-step verification is required.' using errcode='42501';
  end if;
  if coalesce(cardinality(p_request_ids),0)>500 then
    raise exception 'Check up to 500 requests at a time.';
  end if;
  with requests as materialized (
    select r.id,r.division,lower(btrim(r.lead_type)) batch_key,
      r.quantity-r.fulfilled_quantity remaining,
      exists(select 1 from public.profiles p where p.id=r.agent_id and p.role='agent'
        and p.active and not coalesce(p.archived,false) and p.division=r.division) can_deliver
    from public.lead_requests r
    where r.id=any(coalesce(p_request_ids,'{}'::uuid[])) and r.status='pending'
      and private.can_manage_lead_request(r.agent_id,r.division)
  ), destinations as (select distinct division from requests where can_deliver),
  sources as materialized (
    select r.division destination,d.id source,d.name source_name
    from destinations r cross join public.divisions d
    where (d.id=r.division and public.admin_can_access_division(d.id))
      or (d.id<>r.division and private.can_transfer_lead_pool(d.id,r.division))
  ), counts as materialized (
    select l.division source,lower(btrim(l.lead_type)) batch_key,count(*) lead_count
    from public.leads l
    where l.status='unassigned' and l.assigned_to is null
      and l.division in (select source from sources)
      and lower(btrim(l.lead_type)) in (select batch_key from requests where can_deliver)
    group by l.division,lower(btrim(l.lead_type))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'request_id',r.id,'remaining',r.remaining,'can_deliver',r.can_deliver,
    'available',coalesce(a.available,0),'shortage',greatest(0,r.remaining-coalesce(a.available,0)),
    'sources',coalesce(a.sources,'[]'::jsonb)) order by r.id),'[]'::jsonb)
  into result from requests r left join lateral (
    select sum(c.lead_count) available,
      jsonb_agg(jsonb_build_object('source',s.source,'source_name',s.source_name,'lead_count',c.lead_count)
        order by case when s.source=r.division then 0 when s.source='owner' then 1 else 2 end,s.source) sources
    from sources s join counts c on c.source=s.source and c.batch_key=r.batch_key
    where s.destination=r.division and r.can_deliver
  ) a on true;
  return result;
end $$;
revoke all on function private.lead_request_availability(uuid[]) from public,anon;
grant execute on function private.lead_request_availability(uuid[]) to authenticated;

create function public.lead_request_availability(p_request_ids uuid[])
returns jsonb language sql stable security invoker set search_path='' as $$
  select private.lead_request_availability(p_request_ids)
$$;
revoke all on function public.lead_request_availability(uuid[]) from public,anon;
grant execute on function public.lead_request_availability(uuid[]) to authenticated;
