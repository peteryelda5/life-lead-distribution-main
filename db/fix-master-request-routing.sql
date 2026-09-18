create or replace function private.lead_request_route() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.profiles; r public.profiles;
begin
 select * into a from public.profiles where id=auth.uid() and role='agent' and active and not coalesce(archived,false);
 if a.id is null or not public.is_active_agent() then raise exception 'Active agent with MFA required'; end if;
 select * into r from public.profiles where id=a.team_leader_id and id<>a.id and role='agent' and is_team_leader and active and not coalesce(archived,false) and division=a.division;
 if r.id is null then
 select * into r from public.profiles where role='admin' and active and not coalesce(archived,false) and (division=a.division or (a.division='owner' and is_super_admin)) order by (id=a.created_by_admin_id) desc nulls last,is_super_admin desc,created_at,id limit 1;
 end if;
 if r.id is null then raise exception 'No active team leader or division admin is available. Contact your Master Admin.'; end if;
 return jsonb_build_object('agent_id',a.id,'agent_name',a.full_name,'division',a.division,'recipient_id',r.id,'recipient_name',r.full_name,'recipient_role',case when r.is_super_admin then 'Master Admin' when r.role='admin' then 'Division admin' else 'Team leader' end);
end $$;

