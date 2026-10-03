-- Preserve agency, accounts, leads and closed sales; hide the agency from active workspaces.
begin;
alter table public.divisions add column if not exists archived boolean not null default false;
update public.divisions set archived=true where id='legacy_life';
update public.profiles set archived=true,active=false where division='legacy_life' and not is_super_admin;
CREATE OR REPLACE FUNCTION private.book_crm_can_access(p_agent uuid, p_deal uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select private.verified_portal_session() and exists(select 1 from public.profiles target join public.divisions agency on agency.id=target.division where target.id=p_agent and not agency.archived) and (p_agent=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(p_agent) or exists(select 1 from public.closed_business d where d.id=p_deal and private.can_read_admin_sale(d.agent_id,d.lead_id))); $function$

CREATE OR REPLACE FUNCTION private.book_grid(p_action text DEFAULT 'list'::text, p_agent uuid DEFAULT NULL::uuid, p_carrier text DEFAULT NULL::text, p_policy_type text DEFAULT NULL::text, p_comp numeric DEFAULT NULL::numeric, p_advance numeric DEFAULT NULL::numeric, p_effective date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_action in ('save','reset-pin') then
 if not public.is_super_admin() then raise exception 'Only Master can change compensation or reset PINs' using errcode='42501';end if;
 if not exists(select 1 from public.profiles where id=p_agent and active and not coalesce(archived,false)) then raise exception 'Choose an active agent or admin';end if;
 if p_action='reset-pin' then delete from private.book_unlocks where user_id=p_agent;delete from private.book_pins where user_id=p_agent;return jsonb_build_object('ok',true);end if;
 if coalesce(length(trim(p_carrier)),0) not between 1 and 100 or coalesce(length(trim(p_policy_type)),0) not between 1 and 100 or p_comp is null or p_comp not between 0 and 200 or p_advance is null or p_advance not between 0 and 100 or p_effective is null then raise exception 'Carrier, product, effective date and valid percentages required';end if;
 insert into private.book_comp_grid(agent_id,carrier,policy_type,comp_percent,advance_percent,effective_date,updated_by) values(p_agent,lower(trim(p_carrier)),lower(trim(p_policy_type)),p_comp,p_advance,p_effective,auth.uid()) on conflict(agent_id,carrier,policy_type,effective_date) do update set comp_percent=excluded.comp_percent,advance_percent=excluded.advance_percent,updated_by=auth.uid(),updated_at=now();
 perform private.book_capture(p_agent);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'book_comp_grid_saved','profile',p_agent::text,jsonb_build_object('carrier',trim(p_carrier),'policy_type',trim(p_policy_type),'comp_percent',p_comp,'advance_percent',p_advance,'effective_date',p_effective));
 elsif p_action<>'list' then raise exception 'Unknown action';end if;
 return jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(g)||jsonb_build_object('agent_name',p.full_name) order by p.full_name,g.carrier,g.policy_type,g.effective_date desc) from private.book_comp_grid g join public.profiles p on p.id=g.agent_id where g.agent_id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(g.agent_id)),'[]'::jsonb),'agents',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'division',p.division) order by p.full_name) from public.profiles p where p.active and not coalesce(p.archived,false) and (p.id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(p.id))),'[]'::jsonb));
end;$function$

CREATE OR REPLACE FUNCTION private.division_admin_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and is_super_admin and role='admin' and active and not coalesce(archived,false)) then raise exception 'Master Admin only' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'is_system',d.is_system,'admins',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name,'active',p.active) order by p.full_name),'[]') from public.profiles p where p.role='admin' and not p.is_super_admin and not coalesce(p.archived,false) and (p.division=d.id or exists(select 1 from private.admin_division_access a where a.user_id=p.id and a.division=d.id)))) order by d.created_at,d.name),'[]') from public.divisions d where not d.archived);
end $function$

CREATE OR REPLACE FUNCTION private.my_admin_divisions()
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce((select case when p.is_super_admin then array(select d.id from public.divisions d where not d.archived order by d.created_at,d.id) else array(select distinct d from (select p.division d union select g.division from private.admin_division_access g where g.user_id=p.id) scopes where d is not null and exists(select 1 from public.divisions registry where registry.id=d and not registry.archived) order by d) end from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)),array[]::text[])
$function$

commit;
