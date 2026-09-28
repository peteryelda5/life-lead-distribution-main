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
  if tg_op='UPDATE' and new.division is distinct from old.division then
    if not (
 (public.is_super_admin() and old.division<>'legacy_life' and old.status='unassigned' and old.assigned_to is null and new.status='unassigned' and new.assigned_to is null)
 or (old.status='closed' and new.status='closed' and old.assigned_to is not null and new.assigned_to=old.assigned_to
 and public.admin_can_access_division(old.division) and public.admin_can_access_division(new.division)
 and exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='agent' and p.division=new.division and not coalesce(p.archived,false)))
 ) then
      raise exception 'Lead division change is not allowed outside an authorized pool or agent transfer.' using errcode='42501';
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
CREATE OR REPLACE FUNCTION private.transfer_agent_division(p_agent_id uuid, p_division text, p_expected_division text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_division text; reclaimed integer; moved_closed integer; moved_deals integer;
begin
 if auth.uid() is null or not public.admin_can_manage_agent(p_agent_id) or not public.admin_can_access_division(p_division) then
  raise exception 'You cannot manage the source or destination division' using errcode='42501';
 end if;
 if p_division is null or not exists(select 1 from public.divisions where id=p_division) then raise exception 'Invalid division'; end if;
 perform set_config('lock_timeout','3s',true);
 -- Serialize against assignments and closings so none can cross the transfer.
 lock table public.leads,public.closed_business in share row exclusive mode;
 select division into old_division from public.profiles where id=p_agent_id and role='agent' and not coalesce(archived,false) for update;
 if not found then raise exception 'Active or disabled agent not found; restore archived agents first'; end if;
 if old_division is distinct from p_expected_division then raise exception 'The agent division changed. Refresh and try again.'; end if;
 if old_division=p_division then return jsonb_build_object('division',p_division,'reclaimed',0); end if;
 if exists(select 1 from public.closed_business cb join public.leads l on l.id=cb.lead_id where cb.agent_id=p_agent_id and (l.assigned_to is distinct from p_agent_id or l.status<>'closed' or l.division<>old_division)) then raise exception 'A closed deal has inconsistent lead ownership. Resolve it before transferring.';end if;
 if exists(select 1 from public.leads where assigned_to=p_agent_id and division<>old_division) then raise exception 'Lead divisions must match the agent before transferring';end if;
 if exists(select 1 from private.leaderboard_monthly_import where agent_id=p_agent_id and not public.admin_can_access_division(division)) then raise exception 'Historical sales exist in an inaccessible division' using errcode='42501';end if;
 update public.leads set assigned_to=null,status='unassigned',assigned_at=null,updated_at=now() where assigned_to=p_agent_id and status='assigned';
 get diagnostics reclaimed=row_count;
 if exists(select 1 from public.leads where assigned_to=p_agent_id and status<>'closed') then raise exception 'Other lead assignments must be resolved before moving this agent'; end if;
 update public.profiles set division=p_division,team_leader_id=null where id=p_agent_id;
 update public.leads set division=p_division where assigned_to=p_agent_id and status='closed' and division=old_division;
 get diagnostics moved_closed=row_count;
 -- Existing deal rows and dates stay intact; update refreshes their chat announcements.
 update public.closed_business set agent_id=p_agent_id where agent_id=p_agent_id;
 get diagnostics moved_deals=row_count;
 update private.leaderboard_monthly_import set division=p_division where agent_id=p_agent_id and division<>p_division;

 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'agent_division_changed','profile',p_agent_id::text,jsonb_build_object('from_division',old_division,'to_division',p_division,'reclaimed',reclaimed,'closed_leads_moved',moved_closed,'deals_moved',moved_deals));
 return jsonb_build_object('division',p_division,'reclaimed',reclaimed,'closed_leads_moved',moved_closed,'deals_moved',moved_deals);
end $function$
;
