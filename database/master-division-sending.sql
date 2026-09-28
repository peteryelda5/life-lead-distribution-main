CREATE OR REPLACE FUNCTION public.enforce_lead_division()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  caller_role public.user_role;
  caller_super boolean;
  caller_div text;
  agent_div text;
begin
  if public.is_super_admin() and new.assigned_to is not null and (tg_op='INSERT' or new.assigned_to is distinct from old.assigned_to) then
    raise exception 'Master sends leads to divisions. Division admins assign agents.' using errcode='42501';
  end if;
  if tg_op='UPDATE' and new.division is distinct from old.division then
    if not public.is_super_admin() or old.division='legacy_life' or old.status<>'unassigned' or old.assigned_to is not null or new.status<>'unassigned' or new.assigned_to is not null then
      raise exception 'Only Master can send unassigned leads between divisions. Legacy leads stay in Legacy.' using errcode='42501';
    end if;
  end if;
  if auth.uid() is not null then
    select p.role,p.is_super_admin,p.division into caller_role,caller_super,caller_div
    from public.profiles p where p.id=auth.uid() and p.active=true;

    if caller_role='admin'::public.user_role then
      if coalesce(caller_super,false) then
        if new.division is null then new.division:=caller_div; end if;
        if tg_op='INSERT'
           and new.division not in ('owner','vivid_life') then
          raise exception 'Master can add or move leads only to Vivid Life or Master' using errcode='42501';
        end if;
        if tg_op='INSERT' and new.owner_admin_id is null then new.owner_admin_id:=auth.uid(); end if;
      else
        if caller_div is null then raise exception 'Admin division is not configured'; end if;
        if tg_op='UPDATE' and not public.admin_can_access_division(old.division) then
          raise exception 'You cannot manage leads in another division' using errcode='42501';
        end if;
        if not public.admin_can_access_division(new.division) then
          raise exception 'You cannot add or move leads to another division' using errcode='42501';
        end if;
        if tg_op='INSERT' then new.owner_admin_id:=auth.uid(); end if;
      end if;
    end if;
  end if;

  if new.division is null then new.division:='owner'; end if;
  if new.assigned_to is not null then
    select p.division into agent_div from public.profiles p where p.id=new.assigned_to and p.role='agent'::public.user_role;
    if agent_div is null or agent_div<>new.division then
      raise exception 'Lead and agent must belong to the same division';
    end if;
  end if;
  return new;
end;
$function$
;
create or replace function private.send_leads_to_division(p_lead_ids uuid[],p_source text,p_destination text)
returns integer language plpgsql security definer set search_path='' as $$
declare n integer; expected integer;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin and active and not coalesce(archived,false)) then raise exception 'Master only' using errcode='42501'; end if;
 if p_source is null or p_source='legacy_life' or p_destination is null or p_source=p_destination then raise exception 'Choose a different destination. Legacy leads stay in Legacy.';end if;
 if not exists(select 1 from public.divisions where id=p_destination) then raise exception 'Invalid destination';end if;
 expected:=cardinality(p_lead_ids);
 if expected is null or expected<1 or expected>1000 or array_position(p_lead_ids,null) is not null or (select count(distinct id) from unnest(p_lead_ids) id)<>expected then raise exception 'Select 1–1000 distinct leads';end if;
 perform id from public.leads where id=any(p_lead_ids) order by id for update;
 if (select count(*) from public.leads where id=any(p_lead_ids) and division=p_source and status='unassigned' and assigned_to is null)<>expected then raise exception 'Some leads changed. Refresh and select again.';end if;
 update public.leads set division=p_destination,assigned_at=null where id=any(p_lead_ids) and division=p_source and status='unassigned' and assigned_to is null;
 get diagnostics n=row_count;
 insert into public.audit_logs(actor_id,action,entity_type,details) values(auth.uid(),'leads_sent_to_division','lead',jsonb_build_object('source',p_source,'destination',p_destination,'count',n,'lead_ids',p_lead_ids));
 return n;
end $$;
create or replace function public.send_leads_to_division(p_lead_ids uuid[],p_source text,p_destination text)
returns integer language sql security invoker set search_path='' as $$select private.send_leads_to_division(p_lead_ids,p_source,p_destination)$$;
revoke all on function private.send_leads_to_division(uuid[],text,text),public.send_leads_to_division(uuid[],text,text) from public,anon;
grant execute on function private.send_leads_to_division(uuid[],text,text),public.send_leads_to_division(uuid[],text,text) to authenticated;

