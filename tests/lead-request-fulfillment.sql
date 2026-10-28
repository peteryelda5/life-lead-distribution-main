-- Integration test for the restored database only. All assignments and requests roll back.
begin;
-- Isolate delivery permissions from onboarding fixtures; restored by rollback.
create or replace function private.portal_onboarding_allowed() returns boolean language sql stable security definer set search_path='' as $test$ select true $test$;
do $$
declare master_id uuid; agent_id uuid; other_admin uuid; request_id uuid; cross_id uuid; shortage_id uuid;
  r jsonb; count_before bigint; receipt_count integer; agent_div text;
begin
  select id into master_id from public.profiles where role='admin' and is_super_admin and active and not coalesce(archived,false) limit 1;
  select id,division into agent_id,agent_div from public.profiles where role='agent' and division='vivid_life' and active and not coalesce(archived,false) limit 1;
  select id into other_admin from public.profiles where role='admin' and not is_super_admin and division not in ('owner','vivid_life') and active and not coalesce(archived,false) limit 1;
  if master_id is null or agent_id is null or other_admin is null then raise exception 'Missing test users'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',agent_id,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  insert into public.lead_requests(lead_type,quantity,note) values('AMAM3',4,'TX requested; rollback test') returning id into request_id;
  insert into public.lead_requests(lead_type,quantity) values('SL2',501) returning id into cross_id;
  insert into public.lead_requests(lead_type,quantity) values('__recovery_test_no_matching_batch__',3) returning id into shortage_id;
  begin
    perform public.lead_request_delivery_options(request_id);
    raise exception 'TEST ordinary agent accepted';
  exception when insufficient_privilege then null; end;
  begin
    update public.lead_requests set fulfilled_quantity=1 where id=request_id;
    raise exception 'TEST client could forge delivery count';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',other_admin,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  begin perform public.lead_request_delivery_options(request_id);raise exception 'TEST cross-agency inventory accepted';
  exception when insufficient_privilege then null; end;
  begin perform public.fulfill_lead_request(request_id,'vivid_life','AMAM3','{TX}',2,0);raise exception 'TEST cross-agency send accepted';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal1')::text,true);
  execute 'set local role authenticated';
  begin perform public.fulfill_lead_request(request_id,'vivid_life','AMAM3','{TX}',2,0);raise exception 'TEST AAL1 accepted';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  r:=public.lead_request_delivery_options(request_id);
  if (r->'request'->>'id')::uuid<>request_id or jsonb_array_length(r->'inventory')=0 then raise exception 'Options failed';end if;
  if exists(select 1 from jsonb_array_elements(r->'inventory') x where x->>'source'='legacy_life') then raise exception 'Legacy source leaked';end if;
  select count(*) into count_before from public.leads where assigned_to=agent_id;
  r:=public.fulfill_lead_request(request_id,'vivid_life','AMAM3',array[' tx '],2,0);
  if r->>'status'<>'pending' or (r->>'remaining')::integer<>2 then raise exception 'Partial result failed';end if;
  if not exists(select 1 from public.lead_requests where id=request_id and status='pending' and fulfilled_quantity=2) then raise exception 'Partial tracking failed';end if;
  begin perform public.fulfill_lead_request(request_id,'vivid_life','AMAM3','{TX}',2,0);raise exception 'TEST stale double send accepted';
  exception when others then if sqlerrm not like 'This request changed%' then raise;end if;end;
  if (select count(*) from public.leads where assigned_to=agent_id)<>count_before+2 then raise exception 'Duplicate assignment occurred';end if;
  r:=public.fulfill_lead_request(request_id,'vivid_life','AMAM3','{TX}',3,2);
  if (select fulfilled_quantity from public.lead_requests where id=request_id)<>5 or (select quantity from public.lead_requests where id=request_id)<>4 then raise exception 'Overdelivery must preserve original request and actual total';end if;
  if r->>'status'<>'completed' or (r->>'remaining')::integer<>0 then raise exception 'Completion failed';end if;
  begin perform public.fulfill_lead_request(request_id,'vivid_life','AMAM3','{TX}',1,4);raise exception 'TEST completed request accepted';
  exception when others then if sqlerrm not like 'This request changed%' then raise;end if;end;
  begin perform public.fulfill_lead_request(shortage_id,'vivid_life','__recovery_test_no_matching_batch__','{}',3,0);raise exception 'TEST shortage accepted';
  exception when others then if sqlerrm not like 'Only 0 matching leads%' then raise;end if;end;
  if not exists(select 1 from public.lead_requests where id=shortage_id and status='pending' and fulfilled_quantity=0) then raise exception 'Shortage changed request';end if;
  begin perform public.fulfill_lead_request(shortage_id,'legacy_life','OH PRO','{}',3,0);raise exception 'TEST Legacy transfer accepted';
  exception when insufficient_privilege then null;end;
  begin perform public.fulfill_lead_request(shortage_id,'vivid_life','AMAM3','{}',0,0);raise exception 'TEST zero accepted';
  exception when others then if sqlerrm not like 'Choose a positive%' then raise;end if;end;
  begin perform public.fulfill_lead_request(shortage_id,'vivid_life','AMAM3',array[null::text],1,0);raise exception 'TEST null state accepted';
  exception when others then if sqlerrm<>'Choose valid states.' then raise;end if;end;
  r:=public.fulfill_lead_request(cross_id,'owner','SL2','{TX}',501,0);
  if (r->>'sent')::integer<>501 or r->>'status'<>'completed' then raise exception 'Cross-page transfer failed';end if;
  if (select count(*) from public.leads where assigned_to=agent_id)<>count_before+506 then raise exception 'Assignment total wrong';end if;
  execute 'reset role';
  select count(*) into receipt_count from public.lead_delivery_receipts where transaction_id=txid_current()
    and sender_id=master_id and recipient_id=agent_id and source_division='owner' and destination_division='vivid_life' and lead_count=501;
  if receipt_count<>1 then raise exception 'Cross-agency receipt not combined: %',receipt_count;end if;
  if exists(select 1 from public.audit_logs a cross join lateral jsonb_array_elements_text(a.details->'lead_ids') x
    join public.leads l on l.id=x::uuid where a.action='lead_request_fulfilled' and a.details->>'request_id' in (request_id::text,cross_id::text)
    and (l.assigned_to<>agent_id or l.division<>'vivid_life' or l.status<>'assigned' or upper(btrim(l.state))<>'TX')) then raise exception 'Wrong recipient, state or agency';end if;
  update public.profiles set active=false where id=agent_id;
  execute 'set local role authenticated';
  begin perform public.fulfill_lead_request(shortage_id,'vivid_life','AMAM3','{TX}',1,0);raise exception 'TEST inactive recipient accepted';
  exception when others then if sqlerrm not like 'The agent is inactive%' then raise;end if;end;
  execute 'reset role';
  if has_function_privilege('anon','public.fulfill_lead_request(uuid,text,text,text[],integer,integer)','execute')
    or has_function_privilege('anon','public.lead_request_delivery_options(uuid)','execute') then raise exception 'Anonymous access enabled';end if;
end $$;
rollback;
select 'PASS: partial/full delivery, 501-lead transfer, receipts, state filters, duplicate protection, shortage rollback, MFA, permissions, Legacy boundary and inactive recipient' as result;
