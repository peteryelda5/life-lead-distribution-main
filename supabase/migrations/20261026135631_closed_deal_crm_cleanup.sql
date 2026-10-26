-- Explicit CRM-only deletion retains the existing version and permission checks.
create or replace function private.book_crm_profile_delete_option(p_id uuid,p_expected_updated_at timestamptz,p_expected_policies jsonb,p_return_to_leads boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles%rowtype; policy_row record; current_versions jsonb; expected_versions jsonb; snapshot jsonb; n integer; returned jsonb; prior private.book_crm_lead_returns;
begin
 perform public.require_portal_onboarding();
 if p_return_to_leads is null then raise exception 'Choose a deletion option';end if;
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_expected_policies is null or jsonb_typeof(p_expected_policies)<>'array' then raise exception 'Reopen the client before deleting it';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49413));
 select * into prior from private.book_crm_lead_returns where profile_id=p_id and completed;
 if found then
  if prior.actor_id<>auth.uid() or not private.book_crm_can_access(prior.agent_id,null) then raise exception 'Client not available to your account' using errcode='42501';end if;
  return jsonb_build_object('ok',true,'id',p_id,'returned_lead_id',prior.lead_id,'returned_agent_id',prior.agent_id,'replayed',true);
 end if;
 select * into person from private.book_crm_profiles where id=p_id;
 if not found or not private.book_crm_can_access(person.agent_id,null) then raise exception 'Client not available to your account' using errcode='42501';end if;
 -- Same profile-before-policy lock order used by Add policy. Lock rows before the
 -- profile row so legacy contact synchronization can finish without a lock cycle.
 for policy_row in select id from private.book_crm_clients where profile_id=p_id order by id loop
  perform pg_advisory_xact_lock(hashtextextended(policy_row.id::text,49412));
  perform 1 from private.book_crm_clients where id=policy_row.id for update;
 end loop;
 select * into person from private.book_crm_profiles where id=p_id for update;
 if exists(select 1 from private.book_crm_clients c where c.profile_id=p_id and not private.book_crm_can_access(c.agent_id,c.deal_id)) then raise exception 'Not all policies are available to your account' using errcode='42501';end if;
 perform 1 from public.closed_business d where d.id in (select deal_id from private.book_crm_clients where profile_id=p_id) order by d.id for update;
 select jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at,'deal_version',deal_version) order by id),count(*)
 into current_versions,n from private.book_crm_records where profile_id=p_id;
 select jsonb_agg(value order by value->>'id') into expected_versions from jsonb_array_elements(p_expected_policies);
 if n=0 or person.updated_at is distinct from p_expected_updated_at or current_versions is distinct from expected_versions then
  raise sqlstate 'PT409' using message='Client or policies changed. Reopen the client before deleting it.';
 end if;
 perform 1 from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_id order by t.id for update of t;
 select jsonb_build_object('profile',to_jsonb(person),
  'policies',(select jsonb_agg(to_jsonb(c) order by c.id) from private.book_crm_clients c where c.profile_id=p_id),
  'tasks',coalesce((select jsonb_agg(to_jsonb(t)) from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_id),'[]'::jsonb),
  'activity',coalesce((select jsonb_agg(to_jsonb(a)) from private.book_crm_activity a join private.book_crm_clients c on c.id=a.client_id where c.profile_id=p_id),'[]'::jsonb),
  'carrier_statuses',coalesce((select jsonb_agg(to_jsonb(s)) from private.book_crm_carrier_status s join private.book_crm_clients c on c.id=s.policy_id where c.profile_id=p_id),'[]'::jsonb)) into snapshot;
 if p_return_to_leads then returned:=private.book_crm_return_lead(p_id)||jsonb_build_object('returned_to_leads',true);
 else returned:=jsonb_build_object('returned_to_leads',false);end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'crm_client_deleted','crm_profile',p_id::text,jsonb_build_object('before',snapshot,'policy_count',n,'production_preserved',true,'return_to_leads',p_return_to_leads,'lead_return',returned));
 delete from private.book_crm_clients where profile_id=p_id;
 delete from private.book_crm_profiles where id=p_id;
 return jsonb_build_object('ok',true,'id',p_id,'deleted_policies',n)||returned;
end;$$;
revoke all on function private.book_crm_profile_delete_option(uuid,timestamptz,jsonb,boolean) from public,anon,authenticated;
grant execute on function private.book_crm_profile_delete_option(uuid,timestamptz,jsonb,boolean) to authenticated;
create function public.book_crm_profile_delete_option(p_id uuid,p_expected_updated_at timestamptz,p_expected_policies jsonb,p_return_to_leads boolean)
returns jsonb language sql security invoker set search_path='' as $$
 select private.book_crm_profile_delete_option(p_id,p_expected_updated_at,p_expected_policies,p_return_to_leads)
$$;
revoke all on function public.book_crm_profile_delete_option(uuid,timestamptz,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.book_crm_profile_delete_option(uuid,timestamptz,jsonb,boolean) to authenticated;

-- Existing cached clients keep the return-to-leads behavior.
create or replace function private.book_crm_profile_delete(p_id uuid,p_expected_updated_at timestamptz,p_expected_policies jsonb)
returns jsonb language sql security definer set search_path='' as $$
 select private.book_crm_profile_delete_option(p_id,p_expected_updated_at,p_expected_policies,true)
$$;

-- Capture the exact linked policy BEFORE the FK can clear deal_id. Sibling
-- policies stay intact. Task/contact history is retained in the deletion audit.
create function private.book_crm_closed_delete() returns trigger
language plpgsql security definer set search_path='' as $$
declare c private.book_crm_clients; person private.book_crm_profiles; snapshot jsonb;
begin
 select * into c from private.book_crm_clients where deal_id=old.id for update;
 if not found then return old;end if;
 select * into person from private.book_crm_profiles where id=c.profile_id for update;
 snapshot:=jsonb_build_object('policy',to_jsonb(c),'profile',to_jsonb(person),'deal',to_jsonb(old),
 'tasks',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from private.book_crm_tasks t where client_id=c.id),
 'activity',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from private.book_crm_activity a where client_id=c.id),
 'carrier_status',(select to_jsonb(s) from private.book_crm_carrier_status s where policy_id=c.id),
 'compensation',(select to_jsonb(s) from private.book_deal_comp s where deal_id=old.id));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'crm_policy_removed_with_closed_deal','crm_policy',c.id::text,jsonb_build_object('before',snapshot,'closed_deal_id',old.id));
 delete from private.book_crm_clients where id=c.id;
 delete from private.book_crm_profiles p where p.id=c.profile_id and not exists(select 1 from private.book_crm_clients x where x.profile_id=p.id);
 return old;
end $$;
revoke all on function private.book_crm_closed_delete() from public,anon,authenticated;
create trigger book_crm_closed_delete before delete on public.closed_business for each row execute function private.book_crm_closed_delete();
notify pgrst,'reload schema';

