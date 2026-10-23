-- Keep the lock iterator separate from SQL table aliases.
create or replace function private.book_crm_profile_delete(p_id uuid,p_expected_updated_at timestamptz,p_expected_policies jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles%rowtype; policy_row record; current_versions jsonb; expected_versions jsonb; snapshot jsonb; n integer;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_expected_policies is null or jsonb_typeof(p_expected_policies)<>'array' then raise exception 'Reopen the client before deleting it';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49413));
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
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'crm_client_deleted','crm_profile',p_id::text,jsonb_build_object('before',snapshot,'policy_count',n,'production_preserved',true));
 delete from private.book_crm_clients where profile_id=p_id;
 delete from private.book_crm_profiles where id=p_id;
 return jsonb_build_object('ok',true,'id',p_id,'deleted_policies',n);
end;$$;
