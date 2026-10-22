-- Reject confirmations based on stale linked-deal identity, including external deal edits.
drop function public.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz);
drop function private.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz);
create function private.book_crm_carrier_status_save(p_policy uuid,p_status text,p_source text,p_confirmed_on date,p_reference text,p_notes text,p_expected_updated_at timestamptz,p_expected_deal jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.book_crm_clients%rowtype; r jsonb; prior jsonb; saved jsonb; stamp timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_policy is null or p_status is null or p_status<>all(array['unverified','pending','underwriting','approved','issued','in_force','lapsed','cancelled','declined']) then raise exception 'Choose a valid carrier status';end if;
 if coalesce(length(trim(p_reference)),0) not between 1 and 500 or coalesce(length(p_notes),0)>2000 then raise exception 'Enter a carrier reference or reset reason (up to 500 characters); notes allow 2000 characters';end if;
 if p_status<>'unverified' and (p_source is null or p_source<>all(array['carrier_portal','carrier_email','carrier_statement','carrier_phone']) or p_confirmed_on is null or p_confirmed_on>current_date or p_confirmed_on<date '1900-01-01') then raise exception 'Choose a carrier source and a confirmation date that is not in the future';end if;
 if p_status='unverified' then p_source:=null;p_confirmed_on:=null;end if;
 perform pg_advisory_xact_lock(hashtextextended(p_policy::text,49412));
 select * into c from private.book_crm_clients where id=p_policy for update;
 if not found or not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Policy not available to your account' using errcode='42501';end if;
 if c.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Policy changed. Reopen the policy before recording carrier status.';end if;
 select to_jsonb(v) into r from private.book_crm_records v where v.id=p_policy;
 if nullif(r->'deal_version','null'::jsonb) is distinct from nullif(p_expected_deal,'null'::jsonb) then raise sqlstate 'PT409' using message='Linked deal changed. Reopen the policy before recording carrier status.';end if;
 if p_status<>'unverified' and (coalesce(trim(r->>'carrier'),'')='' or coalesce(trim(r->>'policy_type'),'')='') then raise exception 'Record the carrier and policy type first';end if;
 select to_jsonb(s) into prior from private.book_crm_carrier_status s where policy_id=p_policy;
 insert into private.book_crm_carrier_status(policy_id,status,source,confirmed_on,reference,notes,carrier,policy_type,policy_number,recorded_by,recorded_at)
 values(p_policy,p_status,p_source,p_confirmed_on,trim(p_reference),trim(coalesce(p_notes,'')),coalesce(r->>'carrier',''),coalesce(r->>'policy_type',''),coalesce(r->>'policy_number',''),auth.uid(),stamp)
 on conflict(policy_id) do update set status=excluded.status,source=excluded.source,confirmed_on=excluded.confirmed_on,reference=excluded.reference,notes=excluded.notes,carrier=excluded.carrier,policy_type=excluded.policy_type,policy_number=excluded.policy_number,recorded_by=excluded.recorded_by,recorded_at=excluded.recorded_at;
 -- Only the concurrency version changes. Pipeline, production, premium and deal are untouched.
 update private.book_crm_clients set updated_at=stamp where id=p_policy;
 select to_jsonb(s) into saved from private.book_crm_carrier_status s where policy_id=p_policy;
 insert into private.book_crm_activity(client_id,actor_id,kind,body,metadata)
 values(p_policy,auth.uid(),'updated',case when p_status='unverified' then 'Carrier status reset to Unverified. Reason: '||trim(p_reference)
 else 'Carrier status recorded: '||initcap(replace(p_status,'_',' '))||' · '||initcap(replace(p_source,'_',' '))||' · confirmed '||p_confirmed_on::text||'. Reference: '||trim(p_reference) end,
 jsonb_build_object('event','carrier_status','before',prior,'after',saved));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'crm_carrier_status_saved','crm_policy',p_policy::text,jsonb_build_object('before',prior,'after',saved));
 return jsonb_build_object('ok',true,'id',p_policy,'updated_at',stamp);
end;$$;
create function public.book_crm_carrier_status_save(p_policy uuid,p_status text,p_source text,p_confirmed_on date,p_reference text,p_notes text,p_expected_updated_at timestamptz,p_expected_deal jsonb default null) returns jsonb
language sql security invoker set search_path='' as $$select private.book_crm_carrier_status_save(p_policy,p_status,p_source,p_confirmed_on,p_reference,p_notes,p_expected_updated_at,p_expected_deal)$$;
revoke all on function private.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz,jsonb),public.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function private.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz,jsonb),public.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz,jsonb) to authenticated;


notify pgrst,'reload schema';
