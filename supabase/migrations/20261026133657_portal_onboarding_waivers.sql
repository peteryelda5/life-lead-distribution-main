-- Explicit owner-authorized exceptions; never fabricate completion or signatures.
create table private.portal_onboarding_waivers (
 user_id uuid primary key references public.profiles(id),
 reason text not null check(length(btrim(reason))>0),
 granted_by uuid not null references public.profiles(id),
 granted_at timestamptz not null default now(),
 revoked_at timestamptz
);
alter table private.portal_onboarding_waivers enable row level security;
revoke all on private.portal_onboarding_waivers from public,anon,authenticated;
grant select,insert,update on private.portal_onboarding_waivers to service_role;

create or replace function private.portal_onboarding_status(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 p public.profiles; c public.portal_onboarding_checklists;
 r public.portal_onboarding_resources; acknowledged boolean; signed boolean;
 steps boolean[]; complete boolean; enabled boolean; waived boolean;
begin
 select * into p from public.profiles where id=p_user;
 select * into c from public.portal_onboarding_checklists where user_id=p_user;
 select * into r from public.portal_onboarding_resources where user_id=p_user;
 select g.enabled into enabled from private.portal_onboarding_gate g where singleton;
 waived:=exists(select 1 from private.portal_onboarding_waivers where user_id=p_user and revoked_at is null);
 acknowledged:=exists(select 1 from public.portal_onboarding_receipts where user_id=p_user and completion_kind='acknowledged');
 signed:=exists(select 1 from public.portal_signwell_agreements where user_id=p_user and environment='live'
  and not superseded and status='completed' and document_id is not null and completed_at is not null)
  or exists(select 1 from public.portal_docusign_agreements where user_id=p_user and environment='live'
  and not superseded and status='completed' and envelope_id is not null and completed_at is not null);
 steps:=array[
  c.welcome_read_at is not null or acknowledged,
  (c.compliance_acknowledged_at is not null or acknowledged) and signed,
  coalesce(c.is_licensed or r.xcel,false),
  coalesce(c.is_licensed or r.study,false),
  coalesce(c.is_licensed or r.exam,false),
  c.is_licensed=false or (c.is_licensed=true and coalesce(c.npn ~ '^[0-9]{1,10}$',false) and cardinality(c.licensed_states)>0)
 ];
 steps[6]:=coalesce(steps[6],false);
 complete:=not(false=any(steps));
 return jsonb_build_object('required',p.role='agent' and coalesce(enabled,false) and not waived, 'waived',waived,
  'complete',complete,'allowed',coalesce(p.active and not p.archived and
   (p.role='admin' or (p.role='agent' and (not coalesce(enabled,false) or complete or waived))),false),
  'steps',to_jsonb(steps),'isLicensed',c.is_licensed,'agreementComplete',signed);
end $$;
revoke all on function private.portal_onboarding_status(uuid) from public,anon,authenticated;
grant execute on function private.portal_onboarding_status(uuid) to service_role;

notify pgrst,'reload schema';
