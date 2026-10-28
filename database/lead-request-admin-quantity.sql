-- Preserve the original request; record the full amount actually delivered. No leads move on install.
alter table public.lead_requests drop constraint lead_requests_check;
alter table public.lead_requests add constraint lead_requests_fulfilled_nonnegative check(fulfilled_quantity>=0);

create or replace function private.fulfill_lead_request(
  p_request_id uuid,p_source text,p_lead_type text,p_states text[],p_quantity integer,p_expected_fulfilled integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.lead_requests; ids uuid[]; states text[]; n integer; delivered integer; chunk_start integer;
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
  if p_quantity is null or p_quantity<1 then
    raise exception 'Choose a positive whole number of available leads.';
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
  else
    n:=0;
    for chunk_start in 1..cardinality(ids) by 1000 loop
      n:=n+public.send_leads_to_recipient(ids[chunk_start:least(chunk_start+999,cardinality(ids))],p_source,r.division,r.agent_id);
    end loop;
  end if;
  if n<>p_quantity then raise exception 'The available leads changed. No leads were sent. Refresh and try again.'; end if;
  delivered:=r.fulfilled_quantity+n;
  update public.lead_requests set fulfilled_quantity=delivered,
    status=case when delivered>=quantity then 'completed' else 'pending' end where id=r.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'lead_request_fulfilled','lead_request',r.id::text,jsonb_build_object(
      'request_id',r.id,'agent_id',r.agent_id,'source',p_source,'destination',r.division,
      'lead_type',p_lead_type,'states',states,'count',n,'fulfilled_quantity',delivered,'lead_ids',ids));
  return jsonb_build_object('sent',n,'fulfilled_quantity',delivered,'remaining',greatest(0,r.quantity-delivered),
    'status',case when delivered>=r.quantity then 'completed' else 'pending' end,'agent_name',r.agent_name);
end $$;
revoke all on function private.fulfill_lead_request(uuid,text,text,text[],integer,integer) from public,anon;
grant execute on function private.fulfill_lead_request(uuid,text,text,text[],integer,integer) to authenticated;
