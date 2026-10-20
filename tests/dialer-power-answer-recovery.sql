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
  -- Two human answers produce one winner and one durable follow-up without a keypress.
  perform public.dialer_power_prepare(u,auth_session,batch,account,caller,lead_ids,phones,array[.014,.014,.014],'human');
  select array_agg(id order by position) into leg_ids from public.dialer_parallel_legs where session_id=batch;
  perform public.dialer_parallel_event(batch,'agent',null,agent);
  perform public.dialer_parallel_event(batch,'ready',null,agent,'CF'||repeat('a',32));perform public.dialer_parallel_event(batch,'launch');
  foreach l in array leg_ids loop perform public.dialer_parallel_event(batch,'claim',l);end loop;
  result:=public.dialer_parallel_event(batch,'answer',leg_ids[2],call_two,'human',2400);if result->>'result'<>'winner' then raise exception 'Human did not connect automatically';end if;
  result:=public.dialer_parallel_event(batch,'answer',leg_ids[1],call_one,'human',2700);if result->>'result'<>'overflow' then raise exception 'Second person lost';end if;
  if not exists(select 1 from public.dialer_parallel_legs where id=leg_ids[1] and answer='human' and confirmed_at is null and outcome='second_answer' and followup_noted_at is not null) then raise exception 'Second answer evidence/note missing';end if;
  select call_notes into overflow_notes from public.leads where id=lead_ids[1];
  if overflow_notes not like '%Call answered while you were connected to another lead.%' then raise exception 'Second answer note missing';end if;
  perform public.dialer_parallel_event(batch,'answer',leg_ids[1],call_one,'human',2700);
  perform public.dialer_parallel_event(batch,'status',leg_ids[1],call_one,'completed',12);
  perform public.dialer_parallel_event(batch,'answer',leg_ids[1],call_one,'human',2700);
  if (select call_notes from public.leads where id=lead_ids[1])<>overflow_notes or (select outcome from public.dialer_parallel_legs where id=leg_ids[1])<>'second_answer' then raise exception 'Replay duplicated note or erased answer';end if;
  perform public.dialer_parallel_event(batch,'status',leg_ids[2],call_two,'completed',20);
  for l in select id from public.dialer_parallel_legs where session_id=batch and not terminal loop perform public.dialer_parallel_event(batch,'status',l,coalesce((select provider_sid from public.dialer_parallel_legs where id=l),'CA'||replace(gen_random_uuid()::text,'-','')),'canceled',0);end loop;
  perform public.dialer_parallel_event(batch,'stop');perform public.dialer_parallel_event(batch,'complete');
  result:=public.dialer_parallel_event(batch,'confirm',leg_ids[1],call_one,'1');if result->>'result'<>'hangup' then raise exception 'Retired keypress reconnected a stopped batch';end if;
  -- Reproduce terminal status arriving before AMD. Capture the pickup without inventing a human.
  new_batch:=gen_random_uuid();perform public.dialer_power_prepare(u,auth_session,new_batch,account,caller,lead_ids,phones,array[.014,.014,.014],'human');
  select array_agg(id order by position) into leg_ids from public.dialer_parallel_legs where session_id=new_batch;
  agent:='CA'||replace(gen_random_uuid()::text,'-','');call_one:='CA'||replace(gen_random_uuid()::text,'-','');call_two:='CA'||replace(gen_random_uuid()::text,'-','');
  perform public.dialer_parallel_event(new_batch,'agent',null,agent);perform public.dialer_parallel_event(new_batch,'ready',null,agent,'CF'||repeat('b',32));perform public.dialer_parallel_event(new_batch,'launch');
  foreach l in array leg_ids loop perform public.dialer_parallel_event(new_batch,'claim',l);end loop;
  perform public.dialer_parallel_event(new_batch,'status',leg_ids[1],call_one,'completed',2);
  if not exists(select 1 from public.dialer_parallel_legs where id=leg_ids[1] and outcome='answer_unconfirmed' and pickup_at is not null and followup_noted_at is not null) then raise exception 'Short pickup returned as uncalled or lost note';end if;
  select call_notes into overflow_notes from public.leads where id=lead_ids[1];
  if overflow_notes not like '%a live person was not confirmed%' then raise exception 'Unconfirmed pickup falsely claimed a person';end if;
  perform public.dialer_parallel_event(new_batch,'status',leg_ids[1],call_one,'completed',2);
  perform public.dialer_parallel_event(new_batch,'status',leg_ids[1],call_one,'in-progress',0);
  result:=public.dialer_parallel_event(new_batch,'answer',leg_ids[1],call_one,'human',3300);
  if result->>'result'<>'hangup' or (select winner_id from public.dialer_parallel_sessions where id=new_batch) is not null then raise exception 'Late answer resurrected a completed phone call';end if;
  if (select outcome from public.dialer_parallel_legs where id=leg_ids[1])<>'answered_not_connected' or (select call_notes from public.leads where id=lead_ids[1])<>overflow_notes then raise exception 'Late classification lost/duplicated note';end if;
  -- A genuinely unanswered cancellation has no pickup or follow-up note.
  perform public.dialer_parallel_event(new_batch,'status',leg_ids[2],call_two,'canceled',0);
  if exists(select 1 from public.dialer_parallel_legs where id=leg_ids[2] and (pickup_at is not null or followup_noted_at is not null or outcome is not null)) then raise exception 'Unanswered cancellation mislabeled';end if;
  -- Signed answer evidence may arrive after a cancellation callback; still never reopen it.
  result:=public.dialer_parallel_event(new_batch,'answer',leg_ids[2],call_two,'human',2900);
  if result->>'result'<>'hangup' or (select outcome from public.dialer_parallel_legs where id=leg_ids[2])<>'answered_not_connected' then raise exception 'Late answer evidence discarded';end if;
  for l in select id from public.dialer_parallel_legs where session_id=new_batch and not terminal loop perform public.dialer_parallel_event(new_batch,'status',l,coalesce((select provider_sid from public.dialer_parallel_legs where id=l),'CA'||replace(gen_random_uuid()::text,'-','')),'canceled',0);end loop;
  perform public.dialer_parallel_event(new_batch,'stop');perform public.dialer_parallel_event(new_batch,'complete');
  -- Machine and unclear answers hang up without a prompt; unclear pickups receive an honest follow-up.
  new_batch:=gen_random_uuid();perform public.dialer_power_prepare(u,auth_session,new_batch,account,caller,lead_ids,phones,array[.014,.014,.014],'human');
  select array_agg(id order by position) into leg_ids from public.dialer_parallel_legs where session_id=new_batch;
  agent:='CA'||replace(gen_random_uuid()::text,'-','');call_one:='CA'||replace(gen_random_uuid()::text,'-','');call_two:='CA'||replace(gen_random_uuid()::text,'-','');
  perform public.dialer_parallel_event(new_batch,'agent',null,agent);perform public.dialer_parallel_event(new_batch,'ready',null,agent,'CF'||repeat('c',32));perform public.dialer_parallel_event(new_batch,'launch');
  foreach l in array leg_ids loop perform public.dialer_parallel_event(new_batch,'claim',l);end loop;
  result:=public.dialer_parallel_event(new_batch,'answer',leg_ids[1],call_one,'unknown',10000);
  if result->>'result'<>'hangup' or not exists(select 1 from public.dialer_parallel_legs where id=leg_ids[1] and outcome='answer_unconfirmed' and followup_noted_at is not null and confirm_requested_at is null) then raise exception 'Unclear pickup prompted or lost follow-up';end if;
  result:=public.dialer_parallel_event(new_batch,'answer',leg_ids[2],call_two,'machine',2500);
  if result->>'result'<>'hangup' or not exists(select 1 from public.dialer_parallel_legs where id=leg_ids[2] and outcome='machine' and confirm_requested_at is null) then raise exception 'Machine prompted or connected';end if;
  result:=public.dialer_parallel_event(new_batch,'confirm',leg_ids[2],call_two,'1');if result->>'result'<>'hangup' then raise exception 'Retired keypress still enabled';end if;
  if (select winner_id from public.dialer_parallel_sessions where id=new_batch) is not null or (select state from public.dialer_parallel_sessions where id=new_batch)<>'dialing' then raise exception 'Machine or unknown stopped other lines';end if;
  if exists(select 1 from public.dialer_parallel_legs where session_id=new_batch and (confirmed_at is not null or confirm_requested_at is not null)) then raise exception 'Confirmation still requested';end if;
  -- Notes remain scoped even when assignment changes before a late result.
  update public.leads set assigned_to=other_user where id=lead_ids[3];
  select call_notes into overflow_notes from public.leads where id=lead_ids[3];
  perform public.dialer_parallel_event(new_batch,'status',leg_ids[3],'CA'||replace(gen_random_uuid()::text,'-',''),'completed',2);
  if (select call_notes from public.leads where id=lead_ids[3])<>overflow_notes then raise exception 'Follow-up wrote to reassigned lead';end if;
  if not exists(select 1 from public.leads where id=lead_ids[2] and agent_status='appointment_follow_up' and lead_type='Followup Fixture') then raise exception 'Agent outcome/folder changed';end if;
  reset role;raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id in(u,other_user)) or exists(select 1 from public.dialer_parallel_sessions where user_id=u) then raise exception 'Fixtures persisted';end if;
end $$;
select 'PASS: no recipient prompt or keypress, automatic human connection, one winner, second-answer note once, replay/out-of-order safety, unknown pickups never uncalled, late classifications never reconnect, genuine unanswered cancellation, reassignment isolation and fixture rollback.' as result;
