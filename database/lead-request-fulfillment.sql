-- Fulfill requests using the existing agency/assignment rules. No leads move on install.
alter table public.lead_requests add column fulfilled_quantity integer not null default 0
  check (fulfilled_quantity >= 0 and fulfilled_quantity <= quantity);

create function private.lead_request_delivery_options(p_request_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r public.lead_requests; inventory jsonb;
begin
  if not private.verified_portal_session() or not public.is_admin() then
    raise exception 'An active admin with two-step verification is required.' using errcode='42501';
  end if;
  select * into r from public.lead_requests where id=p_request_id;
  if r.id is null or not private.can_manage_lead_request(r.agent_id,r.division) then
    raise exception 'This request is not available to you.' using errcode='42501';
  end if;
  if r.status<>'pending' then raise exception 'This request has already been handled. Refresh requests.'; end if;
  if not exists(select 1 from public.profiles where id=r.agent_id and role='agent' and active
    and not coalesce(archived,false) and division=r.division) then
    raise exception 'The agent is inactive or has changed agencies. Ask for a new request.';
  end if;
  with sources as materialized (
    select id,name from public.divisions d where
      (d.id=r.division and public.admin_can_access_division(d.id))
      or (d.id<>r.division and private.can_transfer_lead_pool(d.id,r.division))
  ), counts as (
    select s.id source,s.name source_name,l.lead_type,upper(btrim(coalesce(l.state,''))) state,count(*) lead_count
    from sources s join public.leads l on l.division=s.id
    where l.status='unassigned' and l.assigned_to is null
    group by s.id,s.name,l.lead_type,upper(btrim(coalesce(l.state,'')))
  ) select coalesce(jsonb_agg(to_jsonb(c) order by source,lead_type,state),'[]'::jsonb) into inventory from counts c;
  return jsonb_build_object('request',to_jsonb(r),'inventory',inventory);
end $$;
revoke all on function private.lead_request_delivery_options(uuid) from public,anon;
grant execute on function private.lead_request_delivery_options(uuid) to authenticated;
create function public.lead_request_delivery_options(p_request_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
  select private.lead_request_delivery_options(p_request_id)
$$;
revoke all on function public.lead_request_delivery_options(uuid) from public,anon;
grant execute on function public.lead_request_delivery_options(uuid) to authenticated;

create function private.fulfill_lead_request(
  p_request_id uuid,p_source text,p_lead_type text,p_states text[],p_quantity integer,p_expected_fulfilled integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.lead_requests; ids uuid[]; states text[]; n integer; delivered integer;
begin
  if not private.verified_portal_session() or not public.is_admin() then
    raise exception 'An active admin with two-step verification is required.' using errcode='42501';
  end if;
  perform set_config('lock_timeout','3s',true);
  select * into r from public.lead_requests where id=p_request_id for update;
  if r.id is null or not private.can_manage_lead_request(r.agent_id,r.division) then
    raise exception 'This request is not available to you.' using errcode='42501';
  end if;
  if r.status<>'pending' or p_expected_fulfilled is distinct from r.fulfilled_quantity then
    raise exception 'This request changed or was already handled. Refresh requests before sending again.';
  end if;
  if p_quantity is null or p_quantity<1 or p_quantity>1000 or p_quantity>r.quantity-r.fulfilled_quantity then
    raise exception 'Choose 1–1,000 leads, up to the quantity still requested.';
  end if;
  if p_source is null or not (
    (p_source=r.division and public.admin_can_access_division(p_source)) or
    (p_source<>r.division and private.can_transfer_lead_pool(p_source,r.division))
  ) then raise exception 'You cannot send leads from that agency.' using errcode='42501'; end if;
  perform id from public.profiles where id=r.agent_id and role='agent' and active
    and not coalesce(archived,false) and division=r.division for share;
  if not found then raise exception 'The agent is inactive or has changed agencies. Ask for a new request.'; end if;
  if cardinality(p_states)>100 or array_position(p_states,null) is not null then raise exception 'Choose valid states.'; end if;
  select coalesce(array_agg(distinct upper(btrim(x))),'{}'::text[]) into states from unnest(p_states) x;
  -- Lock available rows so two requests cannot receive the same lead. Never silently send fewer.
  select array_agg(id order by id) into ids from (
    select l.id from public.leads l
    where l.division=p_source and l.status='unassigned' and l.assigned_to is null
      and l.lead_type is not distinct from p_lead_type
      and (cardinality(states)=0 or upper(btrim(coalesce(l.state,'')))=any(states))
    order by l.id limit p_quantity for update skip locked
  ) selected;
  if coalesce(cardinality(ids),0)<>p_quantity then
    raise exception 'Only % matching leads are available right now. No leads were sent. Lower the quantity or choose another batch/state.',coalesce(cardinality(ids),0);
  end if;
  if p_source=r.division then n:=public.assign_leads_bulk(ids,r.agent_id);
  else n:=public.send_leads_to_recipient(ids,p_source,r.division,r.agent_id); end if;
  if n<>p_quantity then raise exception 'The available leads changed. No leads were sent. Refresh and try again.'; end if;
  delivered:=r.fulfilled_quantity+n;
  update public.lead_requests set fulfilled_quantity=delivered,
    status=case when delivered=quantity then 'completed' else 'pending' end where id=r.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'lead_request_fulfilled','lead_request',r.id::text,jsonb_build_object(
      'request_id',r.id,'agent_id',r.agent_id,'source',p_source,'destination',r.division,
      'lead_type',p_lead_type,'states',states,'count',n,'fulfilled_quantity',delivered,'lead_ids',ids));
  return jsonb_build_object('sent',n,'fulfilled_quantity',delivered,'remaining',r.quantity-delivered,
    'status',case when delivered=r.quantity then 'completed' else 'pending' end,'agent_name',r.agent_name);
end $$;
revoke all on function private.fulfill_lead_request(uuid,text,text,text[],integer,integer) from public,anon;
grant execute on function private.fulfill_lead_request(uuid,text,text,text[],integer,integer) to authenticated;
create function public.fulfill_lead_request(
  p_request_id uuid,p_source text,p_lead_type text,p_states text[],p_quantity integer,p_expected_fulfilled integer
) returns jsonb language sql security invoker set search_path='' as $$
  select private.fulfill_lead_request(p_request_id,p_source,p_lead_type,p_states,p_quantity,p_expected_fulfilled)
$$;
revoke all on function public.fulfill_lead_request(uuid,text,text,text[],integer,integer) from public,anon;
grant execute on function public.fulfill_lead_request(uuid,text,text,text[],integer,integer) to authenticated;
