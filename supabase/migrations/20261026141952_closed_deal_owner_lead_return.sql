create or replace function private.remove_closed_deal(p_deal_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare v_deal public.closed_business%rowtype;v_div text;v_lead public.leads%rowtype;
begin
 perform public.require_portal_onboarding();
 if auth.uid() is null or not public.is_admin() then raise exception 'Admin access required';end if;
 select * into v_deal from public.closed_business where id=p_deal_id for update;
 if not found then return false;end if;
 if v_deal.lead_id is not null then select * into v_lead from public.leads where id=v_deal.lead_id for update;end if;
 select coalesce(v_lead.division,p.division) into v_div from public.profiles p where p.id=v_deal.agent_id;
 if not coalesce(v_div=any(private.my_admin_divisions()),false) and v_deal.agent_id is distinct from auth.uid() then raise exception 'Division access denied';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'closed_deal_removed','closed_business',v_deal.id::text,jsonb_build_object('division',v_div,'agent_id',v_deal.agent_id,'lead_id',v_deal.lead_id,'monthly_premium',v_deal.monthly_premium,'annual_premium',v_deal.annual_premium,'carrier',v_deal.carrier,'policy_type',v_deal.policy_type));
 delete from public.closed_business where id=v_deal.id;
 if v_lead.id is not null and v_lead.status='closed' then
  if exists(select 1 from public.profiles where id=v_lead.assigned_to and active and not coalesce(archived,false) and role in ('agent','admin') and (division=v_lead.division or private.admin_can_receive_lead(id,v_lead.division) or exists(select 1 from private.agent_portable_leads x where x.lead_id=v_lead.id and x.agent_id=public.profiles.id and x.origin_division=v_lead.division))) then
   update public.leads set status='assigned',updated_at=now() where id=v_lead.id;
  else
   update public.leads set status='unassigned',assigned_to=null,assigned_at=null,updated_at=now() where id=v_lead.id;
  end if;
 end if;
 return true;
end $$;
