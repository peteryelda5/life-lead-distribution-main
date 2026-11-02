-- Disabling changes access only unless the administrator explicitly reclaims
-- open personal leads. Never delete credentials, clients, deals or team links.
create or replace function private.account_disable_target(p_user uuid)
returns public.profiles language plpgsql security definer set search_path='' as $$
declare target public.profiles;
begin
 perform public.require_portal_onboarding();
 if not public.is_admin() then raise exception 'Admin access required' using errcode='42501';end if;
 select * into target from public.profiles where id=p_user for update;
 if not found or coalesce(target.archived,false) then raise exception 'Active account record not found';end if;
 if p_user=auth.uid() or coalesce(target.is_super_admin,false) then raise exception 'You cannot disable your own account or a Master Admin' using errcode='42501';end if;
 if (target.role='agent' and not public.admin_can_manage_agent(p_user))
  or (target.role='admin' and not public.is_super_admin())
  or target.role not in ('admin','agent') then
  raise exception 'You cannot manage this account' using errcode='42501';
 end if;
 return target;
end $$;
revoke all on function private.account_disable_target(uuid) from public,anon,authenticated;

create or replace function private.account_disable_preview(p_user uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.profiles; open_count bigint; can_reclaim boolean;
begin
 target:=private.account_disable_target(p_user);
 select count(*),coalesce(bool_and(public.admin_can_access_division(l.division)),true)
 into open_count,can_reclaim from public.leads l
 where l.assigned_to=p_user and l.status='assigned'
 and not exists(select 1 from public.closed_business d where d.lead_id=l.id);
 return jsonb_build_object('id',target.id,'name',target.full_name,'role',target.role,
  'division',target.division,'active',target.active,'open_leads',open_count,
  'closed_deals',(select count(*) from public.closed_business where agent_id=p_user),
  'can_reclaim',can_reclaim);
end $$;

create or replace function private.disable_portal_account(p_user uuid,p_reclaim_open_leads boolean default false,p_expected_role text default null,p_expected_division text default null)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare target public.profiles; reclaimed bigint:=0; result jsonb;
begin
 -- Authenticate before locking. Lead writers use leads before profiles too.
 perform public.require_portal_onboarding();
 if not public.is_admin() then raise exception 'Admin access required' using errcode='42501';end if;
 if coalesce(p_reclaim_open_leads,false) then lock table public.leads in share row exclusive mode;end if;
 target:=private.account_disable_target(p_user);
 if not target.active then raise exception 'This account is already disabled. Refresh the account list.';end if;
 if (p_expected_role is not null and target.role::text is distinct from p_expected_role)
 or (p_expected_division is not null and target.division is distinct from p_expected_division) then
  raise exception 'This account changed. Close this dialog and review it again.';
 end if;
 if coalesce(p_reclaim_open_leads,false) then
  if exists(select 1 from public.leads l where l.assigned_to=p_user and l.status='assigned'
   and not exists(select 1 from public.closed_business d where d.lead_id=l.id)
   and not public.admin_can_access_division(l.division)) then
   raise exception 'A Master Admin must return leads from another agency. You can still disable and keep everything.' using errcode='42501';
  end if;
  update public.leads l set assigned_to=null,status='unassigned',assigned_at=null,updated_at=now()
  where l.assigned_to=p_user and l.status='assigned'
  and not exists(select 1 from public.closed_business d where d.lead_id=l.id);
  get diagnostics reclaimed=row_count;
 end if;
 update public.profiles set active=false where id=p_user;
 -- Old sessions remain expired after re-enabling; a fresh sign-in is required.
 update auth.sessions set not_after=least(coalesce(not_after,now()),now()) where user_id=p_user;
 result:=jsonb_build_object('id',p_user,'active',false,'reclaimed_leads',reclaimed,
  'mode',case when coalesce(p_reclaim_open_leads,false) then 'return_open_leads' else 'keep_everything' end);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),case when target.role='admin' then 'scoped_admin_disabled' else 'agent_disabled' end,
 'profile',p_user::text,result||jsonb_build_object('division',target.division,'role',target.role,'records_preserved',true));
 return result;
end $$;

create or replace function public.account_disable_preview(p_user uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.account_disable_preview(p_user) $$;
create or replace function public.disable_portal_account(p_user uuid,p_reclaim_open_leads boolean default false,p_expected_role text default null,p_expected_division text default null)
returns jsonb language sql security invoker set search_path='' as $$ select private.disable_portal_account(p_user,p_reclaim_open_leads,p_expected_role,p_expected_division) $$;
revoke all on function private.account_disable_preview(uuid),public.account_disable_preview(uuid),
 private.disable_portal_account(uuid,boolean,text,text),public.disable_portal_account(uuid,boolean,text,text) from public,anon;
grant execute on function private.account_disable_preview(uuid),public.account_disable_preview(uuid),
 private.disable_portal_account(uuid,boolean,text,text),public.disable_portal_account(uuid,boolean,text,text) to authenticated;

-- Older browser tabs must also default to keeping records and assignments.
create or replace function public.disable_agent(target_agent uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=target_agent and role='agent') then raise exception 'Agent not found';end if;
 perform private.disable_portal_account(target_agent,false,'agent',null);
end $$;
create or replace function public.set_scoped_admin_access(p_admin_id uuid,p_active boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform public.require_portal_onboarding();
 if not public.is_super_admin() then raise exception 'Super admin only' using errcode='42501';end if;
 if p_admin_id=auth.uid() then raise exception 'You cannot disable your own super admin account';end if;
 if not exists(select 1 from public.profiles where id=p_admin_id and role='admin' and not is_super_admin and not archived) then raise exception 'Scoped admin not found';end if;
 if not coalesce(p_active,false) then
  perform private.disable_portal_account(p_admin_id,false,'admin',null);
 else
  update public.profiles set active=true where id=p_admin_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'scoped_admin_enabled','profile',p_admin_id::text,jsonb_build_object('active',true));
 end if;
end $$;
revoke all on function public.disable_agent(uuid),public.set_scoped_admin_access(uuid,boolean) from public,anon;
grant execute on function public.disable_agent(uuid),public.set_scoped_admin_access(uuid,boolean) to authenticated;
notify pgrst,'reload schema';
