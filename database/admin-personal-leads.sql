-- Admins work personally assigned leads without a second login.
create or replace function private.admin_can_receive_lead(p_admin uuid,p_division text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p where p.id=p_admin and p.role='admin' and p.active and not coalesce(p.archived,false)
 and (p.is_super_admin or p.division=p_division or exists(select 1 from private.admin_division_access g where g.user_id=p.id and g.division=p_division)));
$$;
revoke all on function private.admin_can_receive_lead(uuid,text) from public,anon,authenticated;

create or replace function private.can_work_assigned_leads()
returns boolean language sql stable security definer set search_path='' as $$
 select private.verified_portal_session();
$$;
revoke all on function private.can_work_assigned_leads() from public,anon;
grant execute on function private.can_work_assigned_leads() to authenticated;

create or replace function private.admin_lead_recipients()
returns table(id uuid,full_name text,divisions text[]) language plpgsql stable security definer set search_path='' as $$
begin
 if not private.verified_portal_session() or not public.is_admin() then raise exception 'Verified admin required' using errcode='42501';end if;
 return query select p.id,p.full_name,array(select d.id from public.divisions d where public.admin_can_access_division(d.id) and private.admin_can_receive_lead(p.id,d.id))
 from public.profiles p where p.role='admin' and p.active and not coalesce(p.archived,false)
 and exists(select 1 from public.divisions d where public.admin_can_access_division(d.id) and private.admin_can_receive_lead(p.id,d.id))
 order by p.full_name;
end $$;
create or replace function public.admin_lead_recipients()
returns table(id uuid,full_name text,divisions text[]) language sql security invoker set search_path='' as $$select * from private.admin_lead_recipients()$$;
revoke all on function private.admin_lead_recipients(),public.admin_lead_recipients() from public,anon;
grant execute on function private.admin_lead_recipients(),public.admin_lead_recipients() to authenticated;

create or replace function private.assign_admin_leads(p_lead_ids uuid[],p_admin_id uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare n integer; expected integer;
begin
 if not private.verified_portal_session() or not public.is_admin() then raise exception 'Verified admin required' using errcode='42501';end if;
 if p_lead_ids is null or cardinality(p_lead_ids)=0 then return 0;end if;
 if cardinality(p_lead_ids)>1000 then raise exception 'Select up to 1,000 leads';end if;
 select count(distinct x) into expected from unnest(p_lead_ids) x;
 if expected<>cardinality(p_lead_ids) then raise exception 'Duplicate or invalid lead IDs';end if;
 update public.leads l set assigned_to=p_admin_id,status='assigned',assigned_at=now()
 where l.id=any(p_lead_ids) and l.status='unassigned' and l.assigned_to is null
 and public.admin_can_access_division(l.division) and private.admin_can_receive_lead(p_admin_id,l.division);
 get diagnostics n=row_count;
 if n<>expected then raise exception 'Some leads are unavailable or outside the sender or recipient agency access. Refresh and try again.' using errcode='42501';end if;
 insert into public.audit_logs(actor_id,action,entity_type,details) values(auth.uid(),'leads_assigned_to_admin','lead',jsonb_build_object('admin_id',p_admin_id,'count',n));
 return n;
end $$;
create or replace function public.assign_admin_leads(p_lead_ids uuid[],p_admin_id uuid)
returns integer language sql security invoker set search_path='' as $$select private.assign_admin_leads(p_lead_ids,p_admin_id)$$;
revoke all on function private.assign_admin_leads(uuid[],uuid),public.assign_admin_leads(uuid[],uuid) from public,anon;
grant execute on function private.assign_admin_leads(uuid[],uuid),public.assign_admin_leads(uuid[],uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.close_lead(p_lead_id uuid, p_carrier text, p_policy_type text, p_monthly_premium numeric, p_application_date date, p_policy_number text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_id uuid;
begin
  if not private.can_work_assigned_leads() then
    raise exception 'Account access is not active';
  end if;

  if coalesce(trim(p_carrier), '') = '' or coalesce(trim(p_policy_type), '') = '' then
    raise exception 'Carrier and policy type are required';
  end if;

  if p_monthly_premium is null or p_monthly_premium < 0 then
    raise exception 'Monthly premium must be zero or greater';
  end if;

  perform 1 from public.leads where id=p_lead_id and assigned_to=auth.uid() and status='assigned' for update;
  if not found then
    raise exception 'Lead is not assigned to you';
  end if;

  insert into public.closed_business(
    lead_id, agent_id, carrier, policy_type, monthly_premium,
    application_date, policy_number, notes
  )
  values(
    p_lead_id, auth.uid(), trim(p_carrier), trim(p_policy_type), p_monthly_premium,
    p_application_date, nullif(trim(p_policy_number), ''), nullif(trim(p_notes), '')
  )
  returning id into new_id;

  update public.leads
  set status = 'closed'
  where id = p_lead_id;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
  values(
    auth.uid(), 'lead_closed', 'lead', p_lead_id::text,
    jsonb_build_object('closed_business_id', new_id)
  );

  return new_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_lead_agent_status(p_lead_id uuid, p_agent_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not private.can_work_assigned_leads() then
    raise exception 'Account access is not active';
  end if;

  if p_agent_status not in ('none','dead_number','appointment_follow_up','not_interested','call_back') then
    raise exception 'Invalid lead status';
  end if;

  update public.leads
  set agent_status = p_agent_status,
      updated_at = now()
  where id = p_lead_id
    and assigned_to = auth.uid()
    and status = 'assigned';

  if not found then
    raise exception 'Lead is not assigned to you';
  end if;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
  values(
    auth.uid(),
    'agent_lead_status_changed',
    'lead',
    p_lead_id::text,
    jsonb_build_object('agent_status', p_agent_status)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_lead_call_notes(p_lead_id uuid, p_notes text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not private.can_work_assigned_leads() then
    raise exception 'Account access is not active';
  end if;

  if not exists (
    select 1 from public.leads
    where id = p_lead_id
      and assigned_to = auth.uid()
      and status = 'assigned'
  ) then
    raise exception 'Lead is not assigned to you';
  end if;

  update public.leads
  set call_notes = nullif(trim(coalesce(p_notes, '')), '')
  where id = p_lead_id;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
  values(auth.uid(), 'lead_call_notes_updated', 'lead', p_lead_id::text, jsonb_build_object('has_notes', nullif(trim(coalesce(p_notes, '')), '') is not null));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.my_lead_folders()
 RETURNS TABLE(lead_type text, lead_count bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select l.lead_type,count(*) from public.leads l where l.assigned_to=(select auth.uid()) and l.status='assigned' and (select private.can_work_assigned_leads()) and (select auth.jwt()->>'aal')='aal2' group by l.lead_type order by l.lead_type nulls last $function$
;

CREATE OR REPLACE FUNCTION public.enforce_lead_division()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare caller_role public.user_role; caller_super boolean; caller_div text; agent_div text;
begin
 if tg_op='UPDATE' and new.division is distinct from old.division then
  if not (
   (private.can_transfer_lead_pool(old.division,new.division) and old.division<>'legacy_life' and old.status='unassigned' and old.assigned_to is null and new.status='unassigned' and new.assigned_to is null)
   or (old.status='closed' and new.status='closed' and old.assigned_to is not null and new.assigned_to=old.assigned_to and public.admin_can_access_division(old.division) and public.admin_can_access_division(new.division) and exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='agent' and p.division=new.division and not coalesce(p.archived,false)))
  ) then raise exception 'Lead division change is not allowed outside an authorized pool or agent transfer.' using errcode='42501'; end if;
 end if;
 if auth.uid() is not null then
  select p.role,p.is_super_admin,p.division into caller_role,caller_super,caller_div from public.profiles p where p.id=auth.uid() and p.active=true;
  if caller_role='admin'::public.user_role then
   if coalesce(caller_super,false) then
    if new.division is null then new.division:=caller_div; end if;
    if tg_op='INSERT' and new.division not in ('owner','vivid_life') then raise exception 'Master can add or move leads only to Vivid Life or Master' using errcode='42501';end if;
    if tg_op='INSERT' and new.owner_admin_id is null then new.owner_admin_id:=auth.uid();end if;
   else
    if caller_div is null then raise exception 'Admin division is not configured';end if;
    if tg_op='UPDATE' and not public.admin_can_access_division(old.division) then raise exception 'You cannot manage leads in another division' using errcode='42501';end if;
    if not public.admin_can_access_division(new.division) then raise exception 'You cannot add or move leads to another division' using errcode='42501';end if;
    if tg_op='INSERT' then new.owner_admin_id:=auth.uid();end if;
   end if;
  end if;
 end if;
 if new.division is null then new.division:='owner';end if;
 if new.assigned_to is not null then
  if exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='admin') then
   if not private.admin_can_receive_lead(new.assigned_to,new.division) then
    raise exception 'Admin recipient cannot access this agency' using errcode='42501';
   end if;
  else
  select p.division into agent_div from public.profiles p where p.id=new.assigned_to and p.role='agent'::public.user_role;
  if agent_div is null or (agent_div<>new.division and not (
   tg_op='UPDATE' and new.status in ('assigned','closed') and new.division=old.division
   and exists(select 1 from private.agent_portable_leads x where x.lead_id=new.id and x.agent_id=new.assigned_to and x.origin_division=new.division)
  )) then raise exception 'Lead and agent must belong to the same division';end if;
  end if;
 end if;
 return new;
end $function$
;

-- Include admin-produced sales in existing authorized closed-business views.
create or replace function private.can_read_admin_sale(p_admin uuid,p_lead uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select private.verified_portal_session() and public.is_admin() and exists(
 select 1 from public.profiles p left join public.leads l on l.id=p_lead
 where p.id=p_admin and p.role='admin' and public.admin_can_access_division(coalesce(l.division,p.division)));
$$;
revoke all on function private.can_read_admin_sale(uuid,uuid) from public,anon;
grant execute on function private.can_read_admin_sale(uuid,uuid) to authenticated;
create policy "admins read authorized admin sales" on public.closed_business for select to authenticated
using(private.can_read_admin_sale(agent_id,lead_id));
