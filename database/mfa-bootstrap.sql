-- Available before MFA solely to render the caller's enrollment screen.
create or replace function public.account_bootstrap()
returns jsonb language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'role',p.role,
 'active',p.active and not coalesce(p.archived,false),'is_super_admin',p.is_super_admin,
 'created_by_admin_id',p.created_by_admin_id,'division',p.division,
 'is_team_leader',p.is_team_leader,'team_leader_id',p.team_leader_id)
 from public.profiles p where p.id = auth.uid()
$$;
revoke all on function public.account_bootstrap() from public, anon;
grant execute on function public.account_bootstrap() to authenticated;

create or replace function private.verified_portal_session()
returns boolean language sql stable security definer set search_path = '' as $$
 select coalesce(auth.jwt()->>'aal' = 'aal2',false) and exists (
 select 1 from public.profiles p where p.id=auth.uid() and p.active
 and not coalesce(p.archived,false) and p.role in ('admin','agent'))
$$;
revoke all on function private.verified_portal_session() from public,anon;
grant execute on function private.verified_portal_session() to authenticated;

-- Edge functions call this with the caller's JWT before using service credentials.
create or replace function public.require_portal_mfa()
returns boolean language plpgsql stable security invoker set search_path = '' as $$
begin
 if not private.verified_portal_session() then
   raise sqlstate 'PT403' using message='Two-step verification required. Sign in and verify your authenticator code.';
 end if;
 return true;
end $$;
revoke all on function public.require_portal_mfa() from public,anon;
grant execute on function public.require_portal_mfa() to authenticated;
