-- Apply only to the restored recovery-test database.
-- Read-only recovery access with the same active-session, MFA, owner and Master boundaries.
create or replace function private.recovery_verified_session()
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(auth.jwt()->>'aal'='aal2',false)
 and exists(select 1 from auth.sessions s join public.profiles p on p.id=s.user_id
  where s.id::text=auth.jwt()->>'session_id' and p.id=auth.uid()
  and p.active and not coalesce(p.archived,false) and p.role in ('admin','agent'));
$$;
revoke all on function private.recovery_verified_session() from public,anon;
grant execute on function private.recovery_verified_session() to authenticated;

create or replace function public.recovery_onboarding_snapshot(p_all boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare who uuid:=auth.uid(); master boolean; result jsonb;
begin
 if not private.recovery_verified_session() then raise exception 'Sign in and complete two-step verification' using errcode='42501'; end if;
 select p.id='8139e230-055d-4247-8133-684ed817b4fa'::uuid and p.is_super_admin into master from public.profiles p where p.id=who;
 if p_all and not coalesce(master,false) then raise exception 'Only the Master account can view team onboarding' using errcode='42501'; end if;
 select jsonb_build_object(
  'user_id',who,
  'profiles',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'email',p.email,'division',p.division,'role',p.role) order by p.full_name,p.id),'[]') from public.profiles p where p.active and not coalesce(p.archived,false) and p.role in ('agent','admin') and (p.id=who or p_all)),
  'checks',(select coalesce(jsonb_agg(jsonb_build_object('user_id',c.user_id,'npn',c.npn,'licensed_states',c.licensed_states,'welcome_read_at',c.welcome_read_at,'compliance_acknowledged_at',c.compliance_acknowledged_at)),'[]') from public.portal_onboarding_checklists c where c.user_id=who or p_all),
  'receipts',(select coalesce(jsonb_agg(jsonb_build_object('user_id',r.user_id,'completion_kind',r.completion_kind)),'[]') from public.portal_onboarding_receipts r where r.completion_kind='acknowledged' and (r.user_id=who or p_all)),
  'resources',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from public.portal_onboarding_resources r where r.user_id=who or p_all),
  'agreements',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'user_id',a.user_id,'environment',a.environment,'status',a.status,'waiting_on',a.waiting_on,'document_id',a.document_id,'pdf_path',a.pdf_path,'signer_email',a.signer_email,'signer_name',a.signer_name,'superseded',a.superseded,'created_at',a.created_at) order by a.created_at desc),'[]') from public.portal_signwell_agreements a where a.user_id=who or p_all),
  'legacy',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'user_id',a.user_id,'environment',a.environment,'status',a.status,'envelope_id',a.envelope_id,'pdf_path',a.pdf_path,'certificate_path',a.certificate_path,'signer_name',a.signer_name,'superseded',a.superseded,'created_at',a.created_at) order by a.created_at desc),'[]') from public.portal_docusign_agreements a where a.user_id=who or p_all),
  'agencies',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.name)),'[]') from public.divisions d where p_all or exists(select 1 from public.profiles p where p.id=who and p.division=d.id))
 ) into result;
 return result;
end $$;
revoke all on function public.recovery_onboarding_snapshot(boolean) from public,anon;
grant execute on function public.recovery_onboarding_snapshot(boolean) to authenticated;

create or replace function private.recovery_can_read_agreement(p_path text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.recovery_verified_session() and exists(
  select 1 from (
   select user_id,pdf_path, null::text as certificate_path from public.portal_signwell_agreements where status='completed'
   union all select user_id,pdf_path,certificate_path from public.portal_docusign_agreements where status='completed'
  ) a where (p_path=a.pdf_path or p_path=a.certificate_path)
  and (a.user_id=auth.uid() or exists(select 1 from public.profiles p where p.id=auth.uid() and p.id='8139e230-055d-4247-8133-684ed817b4fa'::uuid and p.is_super_admin))
 );
$$;
revoke all on function private.recovery_can_read_agreement(text) from public,anon;
grant execute on function private.recovery_can_read_agreement(text) to authenticated;
create policy recovery_completed_agreement_read on storage.objects for select to authenticated
using(bucket_id='onboarding-agreements' and private.recovery_can_read_agreement(name));
