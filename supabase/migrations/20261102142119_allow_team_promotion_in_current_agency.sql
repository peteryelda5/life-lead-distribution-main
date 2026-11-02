-- Permit promoting a team leader within their existing agency, including empty teams.
CREATE OR REPLACE FUNCTION private.promote_team_leader_with_agency(p_leader uuid, p_expected_division text, p_expected_members uuid[], p_division text DEFAULT NULL::text, p_agency_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare leader public.profiles; members uuid[]; expected uuid[]; people uuid[]; destination text; agency_name text;
 before_profiles jsonb; old_grants jsonb; old_requests jsonb; moved_requests integer; kept_open bigint; kept_closed bigint;
begin
 perform public.require_portal_onboarding();
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin and active and not archived) then
  raise exception 'Master Admin only' using errcode='42501';
 end if;
 if p_expected_members is null or array_position(p_expected_members,null) is not null then raise exception 'Review the team before promoting.';end if;
 if (nullif(btrim(p_division),'') is null) = (nullif(btrim(p_agency_name),'') is null) then raise exception 'Choose an existing agency or enter a new agency name.';end if;
 -- Rare owner operation: serialize roster/assignment writes so no agent is left
 -- behind and no assignment can appear between the portable grant and role change.
 perform set_config('lock_timeout','3s',true);
 lock table public.leads,public.closed_business,public.profiles,public.lead_requests in share row exclusive mode;
 -- Recheck the caller after acquiring locks; a concurrent disable must fail closed.
 perform public.require_portal_onboarding();
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin and active and not archived) then
  raise exception 'Master Admin only' using errcode='42501';
 end if;
 select * into leader from public.profiles where id=p_leader and role='agent' and is_team_leader and active and not archived for update;
 if not found then raise exception 'This leader changed or was already promoted. Refresh Management.';end if;
 if leader.division is distinct from p_expected_division then raise exception 'The leader agency changed. Review the team again.';end if;
 select coalesce(array_agg(id order by id),'{}') into members from public.profiles where team_leader_id=p_leader;
 select coalesce(array_agg(x order by x),'{}') into expected from unnest(p_expected_members) x;
 if members is distinct from expected then raise exception 'The team changed. Review the team again before promoting.';end if;
 if exists(select 1 from public.profiles where id=any(members) and (role<>'agent' or division is distinct from leader.division or is_team_leader)) then
  raise exception 'Team membership needs correction before this team can move.';
 end if;
 people:=array_prepend(p_leader,members);
 if nullif(btrim(p_division),'') is not null then
  select id,name into destination,agency_name from public.divisions where id=p_division and not archived and id<>'owner' for share;
  if not found then raise exception 'Choose an active agency. Owner / Master cannot be selected.';end if;
 else
  destination:=(private.create_division(p_agency_name,null)->>'id');
  select name into agency_name from public.divisions where id=destination;
 end if;
 -- Reject unrecognized cross-agency assignments rather than widening access.
 if exists(select 1 from public.leads l join public.profiles p on p.id=l.assigned_to
  where p.id=any(people) and l.status in ('assigned','closed') and l.division<>p.division
  and not exists(select 1 from private.agent_portable_leads g where g.lead_id=l.id and g.agent_id=p.id and g.origin_division=l.division)) then
  raise exception 'An assignment has an unrecognized source agency. Resolve it before moving this team.';
 end if;
 select jsonb_agg(to_jsonb(p) order by p.id) into before_profiles from public.profiles p where p.id=any(people);
 old_grants:=jsonb_build_object('admin',coalesce((select jsonb_agg(division) from private.admin_division_access where user_id=p_leader),'[]'),
  'extra_lead_read',coalesce((select jsonb_agg(division) from private.extra_lead_read_access where user_id=p_leader),'[]'));
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'division',division,'recipient_id',recipient_id,'recipient_name',recipient_name)),'[]') into old_requests
 from public.lead_requests where agent_id=any(members) and status='pending';
 insert into private.agent_portable_leads(lead_id,agent_id,origin_division)
 select id,assigned_to,division from public.leads where assigned_to=any(people) and status in ('assigned','closed') and division<>destination
 on conflict(lead_id) do update set agent_id=excluded.agent_id,origin_division=excluded.origin_division;
 delete from private.agent_portable_leads g using public.leads l where g.lead_id=l.id and l.assigned_to=any(people) and l.division=destination;
 -- Detach all members first to satisfy the existing team-membership invariant.
 -- Active/archived flags are deliberately preserved, including disabled members.
 update public.profiles set team_leader_id=null,division=destination,created_by_admin_id=p_leader where id=any(members);
 delete from private.admin_division_access where user_id=p_leader;
 delete from private.extra_lead_read_access where user_id=p_leader;
 update public.profiles set role='admin',is_team_leader=false,team_leader_id=null,is_super_admin=false,
  division=destination,created_by_admin_id=auth.uid() where id=p_leader;
 -- Pending team requests follow their new admin; completed requests retain history.
 update public.lead_requests set division=destination,recipient_id=p_leader,recipient_name=leader.full_name
 where agent_id=any(members) and status='pending';
 get diagnostics moved_requests=row_count;
 select count(*) into kept_open from public.leads where assigned_to=any(people) and status='assigned';
 select count(*) into kept_closed from public.closed_business where agent_id=any(people);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'team_leader_promoted_with_agency','profile',p_leader::text,jsonb_build_object(
  'from_division',leader.division,'to_division',destination,'team_member_ids',to_jsonb(members),
  'before_profiles',before_profiles,'previous_grants',old_grants,'previous_pending_requests',old_requests,
  'open_leads_kept',kept_open,'closed_deals_kept',kept_closed,'pending_requests_moved',moved_requests));
 return jsonb_build_object('leader_id',p_leader,'division',destination,'agency_name',agency_name,
  'members_moved',cardinality(members),'open_leads_kept',kept_open,'closed_deals_kept',kept_closed,'pending_requests_moved',moved_requests);
end $function$
;
CREATE OR REPLACE FUNCTION private.team_admin_promotion_preview(p_leader uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare leader public.profiles; members uuid[];
begin
 perform public.require_portal_onboarding();
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin and active and not archived) then
  raise exception 'Master Admin only' using errcode='42501';
 end if;
 select * into leader from public.profiles where id=p_leader and role='agent' and is_team_leader and active and not archived;
 if not found then raise exception 'Choose an active team leader. Refresh Management and try again.';end if;
 if exists(select 1 from public.profiles where team_leader_id=p_leader and (role<>'agent' or division is distinct from leader.division or is_team_leader)) then
  raise exception 'Team membership needs correction before this team can move.';
 end if;
 select coalesce(array_agg(id order by id),'{}') into members from public.profiles where team_leader_id=p_leader;
 return jsonb_build_object(
  'leader',jsonb_build_object('id',leader.id,'name',leader.full_name,'division',leader.division),
  'members',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name,'active',p.active,'archived',p.archived) order by p.full_name,p.id) from public.profiles p where p.id=any(members)),'[]'),
  'agencies',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name) order by d.name) from public.divisions d where not d.archived and d.id<>'owner'),'[]'),
  'open_leads',(select count(*) from public.leads where assigned_to=any(array_prepend(p_leader,members)) and status='assigned'),
  'closed_deals',(select count(*) from public.closed_business where agent_id=any(array_prepend(p_leader,members))));
end $function$
;
notify pgrst,'reload schema';

