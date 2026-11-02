-- Super Master self-service: one existing account per transaction, with stale
-- role/agency checks and a 3s lock bound. No lead/client/deal content is rewritten.
create function private.account_agent_move_preview(p_user uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.profiles; onboarding jsonb;
begin
 perform public.require_portal_onboarding();
 if not public.is_super_admin() then raise exception 'Super Master only' using errcode='42501';end if;
 select * into target from public.profiles where id=p_user and role in ('admin','agent') and not archived;
 if not found or target.is_super_admin or p_user=auth.uid() then raise exception 'Choose an agent or another admin account' using errcode='42501';end if;
 onboarding:=private.portal_onboarding_status(p_user);
 return jsonb_build_object('id',target.id,'name',target.full_name,'role',target.role,'division',target.division,'active',target.active,
 'is_team_leader',target.is_team_leader,'is_master_admin',exists(select 1 from private.master_admin_accounts where user_id=p_user),
 'members',(select count(*) from public.profiles where team_leader_id=p_user),
 'open_leads',(select count(*) from public.leads where assigned_to=p_user and status='assigned'),
 'all_leads',(select count(*) from public.leads where assigned_to=p_user),
 'deals',(select count(*) from public.closed_business where agent_id=p_user),
 'onboarding_needed',coalesce((select enabled from private.portal_onboarding_gate where singleton),false)
 and not coalesce((onboarding->>'complete')::boolean,false) and not coalesce((onboarding->>'waived')::boolean,false),
 'agencies',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name) order by name),'[]') from public.divisions where not archived and id<>'owner'));
end $$;

create function private.move_account_as_agent(p_user uuid,p_division text,p_expected_role text,p_expected_division text)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare target public.profiles; manager uuid; manager_name text; agency_name text; result jsonb; pending_count integer; role_changed boolean;
begin
 perform public.require_portal_onboarding();
 if not public.is_super_admin() then raise exception 'Super Master only' using errcode='42501';end if;
 if p_expected_role is null or p_expected_division is null then raise exception 'Preview this account before moving it';end if;
 select name into agency_name from public.divisions where id=p_division and id<>'owner' and not archived;
 if not found then raise exception 'Choose an active destination agency';end if;
 -- Follow the existing transfer lock order; new assignments cannot race the move.
 lock table public.leads,public.closed_business in share row exclusive mode;
 select * into target from public.profiles where id=p_user and role in ('admin','agent') and not archived for update;
 if not found or target.is_super_admin or p_user=auth.uid() then raise exception 'Choose an agent or another admin account' using errcode='42501';end if;
 if target.role::text is distinct from p_expected_role or target.division is distinct from p_expected_division then raise exception 'This account changed. Close this dialog and review it again.';end if;
 if exists(select 1 from public.profiles where team_leader_id=p_user) then raise exception 'Reassign this leader’s team members in Team settings before making them a regular agent';end if;
 if exists(select 1 from public.leads where assigned_to=p_user and status not in ('assigned','closed')) then raise exception 'An assignment needs review before this account can move';end if;
 role_changed:=target.role='admin';
 -- Portable permissions preserve personal work in its original source agency.
 insert into private.agent_portable_leads(lead_id,agent_id,origin_division)
 select id,p_user,division from public.leads where assigned_to=p_user and status in ('assigned','closed') and division<>p_division
 on conflict(lead_id) do update set agent_id=excluded.agent_id,origin_division=excluded.origin_division;
 delete from private.agent_portable_leads x using public.leads l where x.lead_id=l.id and l.assigned_to=p_user and l.division=p_division;
 delete from private.master_admin_accounts where user_id=p_user;
 delete from private.admin_division_access where user_id=p_user;
 delete from private.extra_lead_read_access where user_id=p_user;
 update public.profiles set role='agent',is_team_leader=false,team_leader_id=null where id=p_user;
 perform private.transfer_agent_division(p_user,p_division,target.division);
 select p.id,p.full_name into manager,manager_name from public.profiles p
 where p.role='admin' and p.active and not p.archived and p.division=p_division
 order by p.is_super_admin desc,p.created_at,p.id limit 1;
 if manager is null then select id,full_name into manager,manager_name from public.profiles where id=auth.uid();end if;
 update public.profiles set created_by_admin_id=manager where id=p_user;
 update public.lead_requests set division=p_division,recipient_id=manager,recipient_name=manager_name,updated_at=now()
 where agent_id=p_user and status='pending';get diagnostics pending_count=row_count;
 -- Reauthenticate former admins so old admin views cannot remain in use.
 if role_changed then update auth.sessions set not_after=least(coalesce(not_after,now()),now()) where user_id=p_user;end if;
 result:=jsonb_build_object('id',p_user,'division',p_division,'agency_name',agency_name,'role','agent','active',target.active,
 'open_leads_kept',(select count(*) from public.leads where assigned_to=p_user and status='assigned'),
 'all_leads_kept',(select count(*) from public.leads where assigned_to=p_user),
 'deals_kept',(select count(*) from public.closed_business where agent_id=p_user),'pending_requests_moved',pending_count,
 'onboarding',private.portal_onboarding_status(p_user),'sign_in_again',role_changed);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'account_moved_as_regular_agent','profile',p_user::text,result||jsonb_build_object('previous_role',target.role,'previous_division',target.division,'records_preserved',true));
 return result;
end $$;
create function public.account_agent_move_preview(p_user uuid)
returns jsonb language sql security invoker set search_path='' as $$select private.account_agent_move_preview(p_user)$$;
create function public.move_account_as_agent(p_user uuid,p_division text,p_expected_role text,p_expected_division text)
returns jsonb language sql security invoker set search_path='' as $$select private.move_account_as_agent(p_user,p_division,p_expected_role,p_expected_division)$$;
revoke all on function private.account_agent_move_preview(uuid),public.account_agent_move_preview(uuid),
 private.move_account_as_agent(uuid,text,text,text),public.move_account_as_agent(uuid,text,text,text) from public,anon;
grant execute on function private.account_agent_move_preview(uuid),public.account_agent_move_preview(uuid),
 private.move_account_as_agent(uuid,text,text,text),public.move_account_as_agent(uuid,text,text,text) to authenticated;
notify pgrst,'reload schema';
