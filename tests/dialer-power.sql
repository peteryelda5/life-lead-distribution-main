-- Synthetic users, sessions, leads and billing rows; everything rolls back.
do $$
declare u uuid:=gen_random_uuid(); other_user uuid:=gen_random_uuid(); auth_session uuid:=gen_random_uuid(); batch uuid:=gen_random_uuid(); new_batch uuid;
 lead_ids uuid[]:='{}'; leg_ids uuid[]; l uuid; n integer; result jsonb; rejected boolean; overflow_notes text;
 phones text[]:=array['+12025550194','+12025550195','+12025550196']; caller text:='+12025550198'; account text:='AC'||repeat('a',32); agent text:='CA'||replace(gen_random_uuid()::text,'-','');
 call_one text:='CA'||replace(gen_random_uuid()::text,'-','');call_two text:='CA'||replace(gen_random_uuid()::text,'-','');
begin
 begin
  perform set_config('request.jwt.claims','{}',true);
  insert into auth.users(id,email) values(u,u||'@example.invalid'),(other_user,other_user||'@example.invalid');
  insert into public.profiles(id,email,full_name,role,active,division) values(u,u||'@example.invalid','Power Fixture','agent',true,'vivid_life'),(other_user,other_user||'@example.invalid','Other Fixture','admin',true,'vivid_life') on conflict(id) do update set role=excluded.role,active=true,archived=false,division=excluded.division;
  insert into auth.sessions(id,user_id,aal,created_at) values(auth_session,u,'aal2',now());
  insert into public.dialer_accounts(user_id,livemode,customer_id,subscription_id,subscription_status,paid_invoice,period_start,period_end,verified_at)
  values(u,true,'cus_fixture'||replace(u::text,'-',''),'sub_fixture'||replace(u::text,'-',''),'active',true,now()-interval '1 day',now()+interval '29 days',now());
  insert into public.dialer_periods(user_id,livemode,starts_at,ends_at,subscription_id,customer_id) select user_id,livemode,period_start,period_end,subscription_id,customer_id from public.dialer_accounts where user_id=u;
  insert into public.dialer_numbers(user_id,livemode,slot,phone,state) values(u,true,1,caller,'active');
  for n in 1..3 loop
   insert into public.leads(first_name,phone,division,status,assigned_to,call_notes,lead_type,agent_status) values('Power lead '||n,phones[n],'vivid_life','assigned',u,'Preserve original notes','Followup Fixture',case when n=2 then 'appointment_follow_up' else 'none' end) returning id into l;lead_ids:=array_append(lead_ids,l);
  end loop;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);set local role service_role;
  if not public.dialer_parallel_allowed(u) or not public.dialer_parallel_allowed(other_user) then raise exception 'Active agents/admins cannot see Power Dialer';end if;
  perform public.dialer_power_prepare(u,auth_session,batch,account,caller,lead_ids,phones,array[.014,.014,.014],'fast');
  perform public.dialer_power_prepare(u,auth_session,batch,account,caller,lead_ids,phones,array[.014,.014,.014],'fast');
  if (select count(*) from public.dialer_calls where user_id=u and call_kind='power')<>3 then raise exception 'Prepare duplicated usage rows';end if;
  rejected:=false;begin perform public.dialer_power_prepare(u,auth_session,batch,account,caller,lead_ids,phones,array[.014,.014,.014],'human');exception when others then rejected:=true;end;if not rejected then raise exception 'Idempotency mismatch accepted';end if;
  rejected:=false;begin perform public.dialer_power_prepare(other_user,auth_session,gen_random_uuid(),account,caller,lead_ids,phones,array[.014,.014,.014],'fast');exception when others then rejected:=true;end;if not rejected then raise exception 'Foreign session accepted';end if;
  rejected:=false;begin perform public.dialer_create_call_with_incoming_guard(u,true,auth_session,gen_random_uuid(),1,lead_ids[1],null);exception when others then rejected:=true;end;if not rejected then raise exception 'Concurrent single call allowed';end if;
  select array_agg(id order by position) into leg_ids from public.dialer_parallel_legs where session_id=batch;
  rejected:=false;begin perform public.dialer_consume_call(leg_ids[1],call_one);exception when others then rejected:=true;end;if not rejected then raise exception 'Single token consumed Power call';end if;
  perform public.dialer_parallel_event(batch,'agent',null,agent);
  perform public.dialer_parallel_event(batch,'ready',null,agent,'CF'||repeat('a',32));
  result:=public.dialer_parallel_event(batch,'launch');if result->>'result'<>'launch' then raise exception 'Headset launch failed';end if;
  result:=public.dialer_parallel_event(batch,'launch');if result->>'result'='launch' then raise exception 'Duplicate launch';end if;
  foreach l in array leg_ids loop perform public.dialer_parallel_event(batch,'claim',l);end loop;
  perform public.dialer_parallel_event(batch,'bind',leg_ids[1],call_one);
  result:=public.dialer_parallel_event(batch,'answer',leg_ids[1],call_one,'answered');if result->>'result'<>'winner' then raise exception 'First pickup did not connect';end if;
  result:=public.dialer_parallel_event(batch,'answer',leg_ids[2],call_two,'answered');if result->>'result'<>'overflow' then raise exception 'Second pickup stole connection';end if;
  select call_notes into overflow_notes from public.leads where id=lead_ids[2];
  if overflow_notes not like E'Preserve original notes\n\n[Power Dialer — % ET] Call answered while you were connected to another lead. This call was not connected to you. Follow-up needed.' then raise exception 'Missing overflow note or prior notes overwritten';end if;
  if not exists(select 1 from public.dialer_parallel_legs where id=leg_ids[2] and followup_noted_at is not null) then raise exception 'Note receipt missing';end if;
  perform public.dialer_parallel_event(batch,'answer',leg_ids[2],call_two,'answered');
  if (select call_notes from public.leads where id=lead_ids[2]) is distinct from overflow_notes then raise exception 'Duplicate provider event duplicated note';end if;
  update public.leads set call_notes=call_notes||E'\nAgent added another note.' where id=lead_ids[2];
  overflow_notes:=overflow_notes||E'\nAgent added another note.';
  perform public.dialer_parallel_event(batch,'answer',leg_ids[2],call_two,'answered');
  if (select call_notes from public.leads where id=lead_ids[2]) is distinct from overflow_notes then raise exception 'Repeat callback overwrote later edits';end if;
  if not exists(select 1 from public.leads where id=lead_ids[2] and agent_status='appointment_follow_up' and lead_type='Followup Fixture' and assigned_to=u) then raise exception 'Overflow changed lead status, folder or owner';end if;
  -- A reassignment racing a late overflow cannot write notes into another agent's lead.
  update public.leads set assigned_to=other_user where id=lead_ids[3];
  update public.dialer_parallel_legs set outcome='second_answer' where id=leg_ids[3];
  if (select call_notes from public.leads where id=lead_ids[3])<>'Preserve original notes' or (select followup_noted_at from public.dialer_parallel_legs where id=leg_ids[3]) is not null then raise exception 'Reassigned lead received overflow note';end if;
  update public.dialer_parallel_legs set outcome=null where id=leg_ids[3];
  update public.leads set assigned_to=u where id=lead_ids[3];
  perform public.dialer_parallel_event(batch,'reject',leg_ids[3],null,null,21211);
  perform public.dialer_parallel_event(batch,'status',leg_ids[1],call_one,'completed',65);
  perform public.dialer_parallel_event(batch,'status',leg_ids[1],call_one,'completed',65);
  perform public.dialer_parallel_event(batch,'status',leg_ids[1],call_one,'ringing',0);
  perform public.dialer_parallel_event(batch,'status',leg_ids[2],call_two,'completed',10);
  if (select sum(used_minutes) from public.dialer_calls where user_id=u)<>3 then raise exception 'Usage rounding or callback idempotency failed';end if;
  if exists(select 1 from public.dialer_calls where user_id=u and not finished) then raise exception 'Terminal leg left calling locked';end if;
  if not exists(select 1 from public.dialer_parallel_legs where id=leg_ids[3] and error_code=21211 and terminal) then raise exception 'Rejected number not recorded';end if;
  perform public.dialer_parallel_event(batch,'stop');perform public.dialer_parallel_event(batch,'complete');
  for n in 1..11 loop
   new_batch:=gen_random_uuid();perform public.dialer_power_prepare(u,auth_session,new_batch,account,caller,lead_ids,phones,array[.014,.014,.014],'fast');perform public.dialer_parallel_event(new_batch,'stop');perform public.dialer_parallel_event(new_batch,'complete');
  end loop;
  new_batch:=gen_random_uuid();perform public.dialer_power_prepare(u,auth_session,new_batch,account,caller,lead_ids,phones,array[.014,.014,.014],'fast');
  select array_agg(id order by position) into leg_ids from public.dialer_parallel_legs where session_id=new_batch;
  update public.leads set assigned_to=other_user where id=lead_ids[1];
  perform public.dialer_parallel_event(new_batch,'agent',null,'CA'||replace(gen_random_uuid()::text,'-',''));
  select agent_sid into agent from public.dialer_parallel_sessions where id=new_batch;
  perform public.dialer_parallel_event(new_batch,'ready',null,agent,'CF'||repeat('b',32));perform public.dialer_parallel_event(new_batch,'launch');
  result:=public.dialer_parallel_event(new_batch,'claim',leg_ids[1]);if result->>'result'<>'stopped' then raise exception 'Reassigned lead was called';end if;
  if not exists(select 1 from public.dialer_calls where id=leg_ids[1] and finished and used_minutes=0) then raise exception 'Skipped lead usage not closed';end if;
  perform public.dialer_parallel_event(new_batch,'stop');perform public.dialer_parallel_event(new_batch,'complete');
  update public.dialer_accounts set paid_invoice=false where user_id=u;
  rejected:=false;begin perform public.dialer_power_prepare(u,auth_session,gen_random_uuid(),account,caller,lead_ids,phones,array[.014,.014,.014],'fast');exception when others then rejected:=true;end;if not rejected then raise exception 'Unpaid account called';end if;
  if exists(select 1 from public.leads where id=any(lead_ids) and call_notes is distinct from case when id=lead_ids[2] then overflow_notes else 'Preserve original notes' end) then raise exception 'Dialing changed unrelated notes';end if;
  reset role;set local role authenticated;
  rejected:=false;begin perform 1 from public.dialer_parallel_sessions;exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Private sessions exposed';end if;
  rejected:=false;begin perform public.dialer_power_prepare(u,auth_session,gen_random_uuid(),account,caller,lead_ids,phones,array[.014,.014,.014],'fast');exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Client bypassed orchestration';end if;
  reset role;raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id in(u,other_user)) or exists(select 1 from public.dialer_parallel_sessions where user_id=u) then raise exception 'Fixtures persisted';end if;
end $$;
select 'PASS: all active roles, paid access, session/lead/caller isolation, idempotent batches, single winner, durable overflow notes without duplicates, preserved agent edits/status/folder, per-line usage, invalid number isolation, no test cap, reassignment protection, private permissions, full fixture rollback.' as result;
