create or replace function private.managed_agent_profiles(p_agent uuid default null,p_after uuid default null)
returns jsonb language plpgsql security definer set search_path='' set statement_timeout='8s' as $$
declare actor public.profiles; result jsonb;
begin
 if not private.verified_portal_session() then raise exception 'Verified session required' using errcode='42501';end if;
 perform public.require_portal_onboarding();
 select * into actor from public.profiles where id=auth.uid();
 if not coalesce(actor.active,false) or coalesce(actor.archived,false) or not (actor.role='admin' or (actor.role='agent' and coalesce(actor.is_team_leader,false))) then raise exception 'Manager access required' using errcode='42501';end if;
 with selected as materialized (
 select p.* from public.profiles p where p.role='agent' and not coalesce(p.archived,false)
 and (p_agent is null or p.id=p_agent) and (p_after is null or p.id>p_after)
 and ((actor.role='admin' and public.admin_can_manage_agent(p.id)) or (actor.role='agent' and p.team_leader_id=actor.id and p.division=actor.division and not coalesce(p.is_team_leader,false) and p.id<>actor.id))
 order by p.id limit 500
 ), rows as (
 select p.id,jsonb_build_object('id',p.id,'full_name',p.full_name,'email',p.email,'active',p.active,'archived',false,'division',p.division,'is_team_leader',p.is_team_leader,'team_leader_id',p.team_leader_id,
 'licensing',jsonb_build_object('isLicensed',c.is_licensed,'npn',c.npn,'states',coalesce(to_jsonb(c.licensed_states),'[]'::jsonb))) value
 from selected p left join public.portal_onboarding_checklists c on c.user_id=p.id
 ) select jsonb_build_object('rows',coalesce(jsonb_agg(value order by id),'[]'::jsonb),'nextCursor',case when count(*)=500 then (array_agg(id order by id desc))[1] else null end) into result from rows;
 if p_agent is not null and jsonb_array_length(result->'rows')=0 then raise exception 'Agent unavailable or outside your team' using errcode='42501';end if;
 return result;
end $$;
create or replace function public.managed_agent_profiles(p_agent uuid default null,p_after uuid default null)
returns jsonb language sql set search_path='' as $$select private.managed_agent_profiles(p_agent,p_after)$$;

create or replace function private.manage_direct_agent(p_agent uuid,p_action text,p_name text default null)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='3s' set statement_timeout='8s' as $$
declare actor public.profiles; target public.profiles;
begin
 if not private.verified_portal_session() then raise exception 'Verified session required' using errcode='42501';end if;
 perform public.require_portal_onboarding();
 select * into actor from public.profiles where id=auth.uid() for update;
 if not coalesce(actor.active,false) or coalesce(actor.archived,false) or actor.role<>'agent' or not coalesce(actor.is_team_leader,false) then raise exception 'Team leader access required' using errcode='42501';end if;
 select * into target from public.profiles where id=p_agent for update;
 if target.id is null or target.id=actor.id or target.role<>'agent' or coalesce(target.archived,false) or coalesce(target.is_team_leader,false) or target.team_leader_id is distinct from actor.id or target.division is distinct from actor.division then raise exception 'Agent unavailable or outside your team' using errcode='42501';end if;
 if p_action='rename' then
  if p_name is null or length(trim(p_name)) not between 1 and 120 then raise exception 'Enter a name between 1 and 120 characters';end if;
  update public.profiles set full_name=trim(p_name) where id=p_agent;
 elsif p_action='disable' then
  update public.profiles set active=false where id=p_agent;
  update auth.sessions set not_after=least(coalesce(not_after,now()),now()) where user_id=p_agent;
 else raise exception 'Unsupported action';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(actor.id,'team_agent_'||p_action,'profile',p_agent::text,jsonb_build_object('division',target.division,'records_preserved',true));
 return jsonb_build_object('id',p_agent,'action',p_action);
end $$;
create or replace function public.manage_direct_agent(p_agent uuid,p_action text,p_name text default null)
returns jsonb language sql set search_path='' as $$select private.manage_direct_agent(p_agent,p_action,p_name)$$;
revoke all on function private.managed_agent_profiles(uuid,uuid), public.managed_agent_profiles(uuid,uuid), private.manage_direct_agent(uuid,text,text), public.manage_direct_agent(uuid,text,text) from public,anon;
grant execute on function private.managed_agent_profiles(uuid,uuid), public.managed_agent_profiles(uuid,uuid), private.manage_direct_agent(uuid,text,text), public.manage_direct_agent(uuid,text,text) to authenticated;
