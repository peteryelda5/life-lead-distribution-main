CREATE OR REPLACE FUNCTION public.save_portal_onboarding_checklist(p_npn text, p_states text[], p_welcome boolean, p_compliance boolean, p_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare who uuid:=auth.uid(); existing public.portal_onboarding_checklists%rowtype;
begin
 if not private.verified_portal_session() then raise exception 'Complete two-step verification';end if;
 if p_npn is not null and trim(p_npn)<>'' and trim(p_npn)!~'^[0-9]{1,10}$' then raise exception 'NPN must contain 1 to 10 digits';end if;
 if p_states is null then raise exception 'Choose valid licensed states';end if;
 select * into existing from public.portal_onboarding_checklists where user_id=who for update;
 if coalesce(p_compliance,false) and existing.compliance_acknowledged_at is null and (length(trim(coalesce(p_name,'')))<2 or length(p_name)>200 or (not coalesce(p_welcome,false) and existing.welcome_read_at is null)) then raise exception 'Read the welcome letter and enter your name to acknowledge compliance';end if;
 insert into public.portal_onboarding_checklists(user_id,npn,licensed_states,welcome_read_at,compliance_acknowledged_at,acknowledged_name,document_version)
 values(who,nullif(trim(p_npn),''),array(select distinct unnest(p_states) order by 1),case when p_welcome then now() end,case when p_compliance then now() end,case when p_compliance then trim(p_name) end,case when p_compliance then '2026-10-01-v1' end)
 on conflict(user_id) do update set npn=coalesce(excluded.npn,portal_onboarding_checklists.npn),licensed_states=case when cardinality(excluded.licensed_states)>0 then excluded.licensed_states else portal_onboarding_checklists.licensed_states end,welcome_read_at=coalesce(portal_onboarding_checklists.welcome_read_at,excluded.welcome_read_at),compliance_acknowledged_at=coalesce(portal_onboarding_checklists.compliance_acknowledged_at,excluded.compliance_acknowledged_at),acknowledged_name=coalesce(portal_onboarding_checklists.acknowledged_name,excluded.acknowledged_name),document_version=coalesce(portal_onboarding_checklists.document_version,excluded.document_version),updated_at=now();
end $function$
