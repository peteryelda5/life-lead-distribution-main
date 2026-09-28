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
