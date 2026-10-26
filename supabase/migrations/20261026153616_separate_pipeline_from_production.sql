-- Keep explicit deal submission separate from CRM workflow stages.
CREATE OR REPLACE FUNCTION private.book_crm_save(p_id uuid, p_fields jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_expected_deal jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c private.book_crm_clients%rowtype; owner_id uuid; d public.closed_business%rowtype; price numeric; app_date date; policy_status text; before_row jsonb;
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_fields is null or jsonb_typeof(p_fields)<>'object' or exists(select 1 from jsonb_object_keys(p_fields) k where k<>all(array['agent_id','client_name','address_line1','address_line2','city','state','zip','phone','email','carrier','policy_type','monthly_payment','policy_number','application_date','status','notes'])) then raise exception 'Invalid client fields';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49412));
 select * into c from private.book_crm_clients where id=p_id for update;
 if found then
 if not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Client not available to your account' using errcode='42501';end if;
 if c.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Client changed. Reopen the client and try again.';end if;
 owner_id:=c.agent_id;before_row:=to_jsonb(c);
 else
 if p_expected_updated_at is not null then raise exception 'Client no longer available';end if;
 owner_id:=coalesce(nullif(p_fields->>'agent_id','')::uuid,auth.uid());
 if not private.book_crm_can_access(owner_id) or not exists(select 1 from public.profiles where id=owner_id and active and not coalesce(archived,false) and role in ('admin','agent')) then raise exception 'Choose an authorized active agent' using errcode='42501';end if;
 end if;
 if coalesce(length(trim(p_fields->>'client_name')),0) not between 1 and 200 then raise exception 'Client name is required (up to 200 characters)';end if;
 if exists(select 1 from jsonb_each_text(p_fields)kv where kv.key in ('address_line1','address_line2','city','carrier','policy_type','policy_number') and length(kv.value)>200) or coalesce(length(p_fields->>'phone'),0)>50 or coalesce(length(p_fields->>'email'),0)>254 or coalesce(length(p_fields->>'notes'),0)>5000 or coalesce(length(p_fields->>'state'),0)>50 or coalesce(length(p_fields->>'zip'),0)>20 then raise exception 'One or more client fields are too long';end if;
 price:=coalesce(nullif(p_fields->>'monthly_payment','')::numeric,0);app_date:=coalesce(nullif(p_fields->>'application_date','')::date,current_date);policy_status:=coalesce(p_fields->>'status','draft');
 if price<0 or price>100000 or policy_status<>all(array['draft','submitted','active','issued','lapsed','cancelled','chargeback']) then raise exception 'Valid monthly payment and policy status required';end if;
 if policy_status in ('active','issued') and (price<=0 or coalesce(length(trim(p_fields->>'carrier')),0)=0 or coalesce(length(trim(p_fields->>'policy_type')),0)=0) then raise exception 'Active / Issued needs carrier, policy type and a positive monthly payment';end if;
 if c.deal_id is not null then
 select * into d from public.closed_business where id=c.deal_id for update;
 if p_expected_deal is distinct from jsonb_build_object('carrier',d.carrier,'policy_type',d.policy_type,'monthly_premium',d.monthly_premium,'application_date',d.application_date,'policy_number',d.policy_number,'notes',d.notes) then raise sqlstate 'PT409' using message='Linked deal changed. Reopen the client and try again.';end if;
 -- A recorded deal still needs complete policy details, even if policy status later changes.
 if price<=0 or coalesce(length(trim(p_fields->>'carrier')),0)=0 or coalesce(length(trim(p_fields->>'policy_type')),0)=0 then raise exception 'Recorded policy needs carrier, policy type and monthly payment';end if;
 end if;
 insert into private.book_crm_clients(id,agent_id,client_name,address_line1,address_line2,city,state,zip,phone,email,carrier,policy_type,monthly_payment,policy_number,application_date,status,notes)
 values(p_id,owner_id,trim(p_fields->>'client_name'),coalesce(p_fields->>'address_line1',''),coalesce(p_fields->>'address_line2',''),coalesce(p_fields->>'city',''),coalesce(p_fields->>'state',''),coalesce(p_fields->>'zip',''),coalesce(p_fields->>'phone',''),coalesce(p_fields->>'email',''),trim(coalesce(p_fields->>'carrier','')),trim(coalesce(p_fields->>'policy_type','')),price,coalesce(p_fields->>'policy_number',''),app_date,policy_status,coalesce(p_fields->>'notes',''))
 on conflict(id) do update set client_name=excluded.client_name,address_line1=excluded.address_line1,address_line2=excluded.address_line2,city=excluded.city,state=excluded.state,zip=excluded.zip,phone=excluded.phone,email=excluded.email,carrier=excluded.carrier,policy_type=excluded.policy_type,monthly_payment=excluded.monthly_payment,policy_number=excluded.policy_number,application_date=excluded.application_date,status=excluded.status,notes=excluded.notes,updated_at=now();
 if c.deal_id is not null then
 update public.closed_business set carrier=trim(p_fields->>'carrier'),policy_type=trim(p_fields->>'policy_type'),monthly_premium=price,application_date=app_date,policy_number=nullif(trim(p_fields->>'policy_number'),''),notes=nullif(trim(p_fields->>'notes'),'') where id=c.deal_id and (carrier,policy_type,monthly_premium,application_date,policy_number,notes) is distinct from (trim(p_fields->>'carrier'),trim(p_fields->>'policy_type'),price,app_date,nullif(trim(p_fields->>'policy_number'),''),nullif(trim(p_fields->>'notes'),''));
 end if;
 select * into c from private.book_crm_clients where id=p_id;
 if c.deal_id is not null then
 insert into private.book_clients(deal_id,client_name,phone,email,updated_by) values(c.deal_id,c.client_name,nullif(c.phone,''),nullif(c.email,''),auth.uid()) on conflict(deal_id) do update set client_name=excluded.client_name,phone=excluded.phone,email=excluded.email,updated_by=auth.uid();
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'crm_client_saved','crm_client',p_id::text,jsonb_build_object('before',before_row,'after',to_jsonb(c)));
 return jsonb_build_object('ok',true,'id',p_id,'deal_id',c.deal_id);
end;$function$
;
CREATE OR REPLACE FUNCTION private.book_crm_save_v2(p_id uuid, p_fields jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_expected_deal jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c private.book_crm_clients%rowtype; merged jsonb; core jsonb; result jsonb; stage text; old_stage text; eff date; dob date; bal numeric; policy_status text; is_new boolean;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_fields is null or jsonb_typeof(p_fields)<>'object' or exists(select 1 from jsonb_object_keys(p_fields) k where k<>all(array['agent_id','client_name','address_line1','address_line2','city','state','zip','phone','email','carrier','policy_type','monthly_payment','policy_number','application_date','notes','effective_date','alternate_phone','date_of_birth','mortgage_balance','pipeline_stage'])) then raise exception 'Invalid client fields';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49412));
 select * into c from private.book_crm_clients where id=p_id for update;
 is_new:=not found;
 if not is_new then
 if not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Client not available to your account' using errcode='42501';end if;
 if c.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Client changed. Reopen the client and try again.';end if;
 if p_fields ? 'agent_id' and p_fields->>'agent_id' is distinct from c.agent_id::text then raise exception 'Client owner cannot be changed here';end if;
 end if;
 -- Use current linked policy values when a quick stage change only sends pipeline_stage.
 select coalesce(to_jsonb(r),'{}') into merged from private.book_crm_records r where r.id=p_id;
 merged:=coalesce(merged,'{}')||p_fields;
 old_stage:=case when is_new then null else private.book_crm_stage(c.pipeline_stage,c.status) end;
 stage:=coalesce(merged->>'pipeline_stage','new');
 if stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled','chargeback']) then raise exception 'Choose a valid pipeline stage';end if;
 eff:=nullif(merged->>'effective_date','')::date;dob:=nullif(merged->>'date_of_birth','')::date;bal:=nullif(merged->>'mortgage_balance','')::numeric;
 if (stage='in_force' or (is_new and stage in ('submitted','approved'))) and eff is null then raise exception 'Enter the policy effective date';end if;
 if stage='in_force' and eff>current_date then raise exception 'Coverage starts in the future. Keep this policy Approved until its effective date.';end if;
 if dob>current_date or dob<date '1900-01-01' then raise exception 'Enter a valid date of birth';end if;
 if bal<0 or bal>999999999999.99 or coalesce(length(merged->>'alternate_phone'),0)>50 then raise exception 'Invalid additional client information';end if;
 if is_new and (coalesce(length(trim(merged->>'phone')),0)=0 or coalesce(length(trim(merged->>'carrier')),0)=0 or coalesce(length(trim(merged->>'policy_type')),0)=0 or coalesce(nullif(merged->>'monthly_payment','')::numeric,0)<=0) then raise exception 'Client phone, carrier, policy type and a positive monthly premium are required';end if;
 -- Pipeline progress never reports or reverses production.
 policy_status:=coalesce(c.status,'draft');
 select coalesce(jsonb_object_agg(key,value),'{}') into core from jsonb_each(merged) where key=any(array['agent_id','client_name','address_line1','address_line2','city','state','zip','phone','email','carrier','policy_type','monthly_payment','policy_number','application_date','notes']);
 result:=private.book_crm_save(p_id,core||jsonb_build_object('status',policy_status),p_expected_updated_at,p_expected_deal);
 update private.book_crm_clients set pipeline_stage=stage,effective_date=eff,alternate_phone=coalesce(merged->>'alternate_phone',''),date_of_birth=dob,mortgage_balance=bal,updated_at=clock_timestamp() where id=p_id;
 insert into private.book_crm_activity(client_id,actor_id,kind,body) values(p_id,auth.uid(),case when is_new then 'created' when old_stage is distinct from stage then 'stage' else 'updated' end,
 case when is_new then 'Client added to '||private.book_crm_stage_label(stage) when old_stage is distinct from stage then private.book_crm_stage_label(old_stage)||' → '||private.book_crm_stage_label(stage) else 'Client details updated' end);
 return result;
end;$function$
;
notify pgrst,'reload schema';
