-- Install the new transaction before deploying its UI. Enable the legacy-route
-- guard in a separate migration only after the matching frontend is live.
create table private.deal_intake_requests (
 request_id uuid primary key, actor_id uuid not null references public.profiles(id),
 fingerprint text not null, deal_id uuid references public.closed_business(id) on delete set null,
 created_at timestamptz not null default now()
);
alter table private.deal_intake_requests enable row level security;
revoke all on private.deal_intake_requests from public,anon,authenticated;

create function private.submit_deal_with_client(p_request_id uuid,p_fields jsonb,p_lead_id uuid default null,p_agent_id uuid default null,p_division text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid(); owner_id uuid:=coalesce(p_agent_id,auth.uid()); lead public.leads;
 prior private.deal_intake_requests%rowtype; fields jsonb; fingerprint text;
 policy uuid:=gen_random_uuid(); deal uuid; stage text; premium numeric; app_date date;
 eff date; dob date; balance numeric; old_context text:=current_setting('lld.crm_client_id',true);
 result jsonb; key text; required text;
begin
 perform public.require_portal_onboarding();
 if not private.verified_portal_session() then raise exception 'Verified sign-in required' using errcode='42501';end if;
 if p_request_id is null or p_fields is null or jsonb_typeof(p_fields)<>'object' then raise exception 'Complete the client and policy form';end if;
 if exists(select 1 from jsonb_each(p_fields) x where x.key<>all(array['client_name','phone','alternate_phone','email','address_line1','address_line2','city','state','zip','date_of_birth','mortgage_balance','carrier','policy_type','monthly_payment','policy_number','application_date','effective_date','pipeline_stage','notes']) or jsonb_typeof(x.value) not in ('string','number','null')) then raise exception 'Invalid deal fields';end if;
 select coalesce(jsonb_object_agg(x.key,case when jsonb_typeof(x.value)='string' then to_jsonb(trim(x.value#>>'{}')) else x.value end),'{}') into fields from jsonb_each(p_fields) x;
 foreach required in array array['client_name','phone','carrier','policy_type','application_date','pipeline_stage'] loop
  if nullif(fields->>required,'') is null then raise exception 'Complete the client name, phone, carrier, product, application date and stage';end if;
 end loop;
 if private.book_crm_missing_name(fields->>'client_name') or length(fields->>'client_name')>200 or length(fields->>'phone')>50 or length(regexp_replace(fields->>'phone','[^0-9]','','g')) not between 7 and 18 then raise exception 'Enter the client name and a valid phone number';end if;
 if exists(select 1 from jsonb_each_text(fields) x where x.key in ('address_line1','address_line2','city','carrier','policy_type','policy_number') and length(x.value)>200) or length(fields->>'alternate_phone')>50 or length(fields->>'state')>50 or length(fields->>'zip')>20 or length(fields->>'email')>254 or length(fields->>'notes')>5000 then raise exception 'One or more client fields are too long';end if;
 if nullif(fields->>'email','') is not null and fields->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid client email';end if;
 premium:=nullif(fields->>'monthly_payment','')::numeric;
 if premium is null or premium<=0 or premium>100000 or premium::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a positive monthly premium';end if;
 app_date:=(fields->>'application_date')::date;eff:=nullif(fields->>'effective_date','')::date;dob:=nullif(fields->>'date_of_birth','')::date;balance:=nullif(fields->>'mortgage_balance','')::numeric;
 if app_date<date '2000-01-01' or app_date>(now() at time zone 'America/Detroit')::date then raise exception 'Enter a valid application date';end if;
 stage:=fields->>'pipeline_stage';
 if stage not in ('submitted','approved','in_force') then raise exception 'Choose Application submitted, Approved or In force';end if;
 if stage in ('approved','in_force') and eff is null then raise exception 'Enter the policy effective date';end if;
 if eff<date '2000-01-01' or (stage='in_force' and eff>(now() at time zone 'America/Detroit')::date) then raise exception 'Coverage starts in the future. Keep the policy Approved until its effective date.';end if;
 if dob<date '1900-01-01' or dob>(now() at time zone 'America/Detroit')::date or balance<0 or balance>999999999999.99 or balance::text in ('NaN','Infinity','-Infinity') then raise exception 'Check the additional client details';end if;
 if p_lead_id is not null then
  select * into lead from public.leads where id=p_lead_id and assigned_to=actor for update;
  if not found or owner_id<>actor then raise exception 'Lead is not assigned to you' using errcode='42501';end if;
 else
  if not coalesce(p_division=any(private.leaderboard_divisions()),false) or not exists(select 1 from jsonb_array_elements(private.chat_deal_agents(p_division)) a where a->>'id'=owner_id::text) then raise exception 'Choose an authorized active agent in this agency' using errcode='42501';end if;
 end if;
 fingerprint:=md5(jsonb_build_object('fields',fields,'lead',p_lead_id,'agent',owner_id,'division',p_division)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,741));
 select * into prior from private.deal_intake_requests where request_id=p_request_id;
 if found then
  if prior.actor_id<>actor or prior.fingerprint<>fingerprint or prior.deal_id is null then raise sqlstate 'PT409' using message='This submission was already handled. Open the saved client to make changes.';end if;
  select id into policy from private.book_crm_clients where deal_id=prior.deal_id;
  return jsonb_build_object('ok',true,'deal_id',prior.deal_id,'client_id',policy,'replayed',true);
 end if;
 if exists(select 1 from public.closed_business where chat_request_id=p_request_id) then raise sqlstate 'PT409' using message='This submission was already handled. Refresh the portal.';end if;
 if p_lead_id is not null and lead.status<>'assigned' then raise exception 'This lead is already closed or no longer available';end if;
 -- Precreate the complete policy so existing production/commission/notification
 -- triggers link to this exact client. Never merge unrelated people by name.
 insert into private.book_crm_clients(id,agent_id,client_name,phone,alternate_phone,email,address_line1,address_line2,city,state,zip,date_of_birth,mortgage_balance,carrier,policy_type,monthly_payment,policy_number,application_date,effective_date,pipeline_stage,status,notes)
 values(policy,owner_id,fields->>'client_name',fields->>'phone',coalesce(fields->>'alternate_phone',''),coalesce(fields->>'email',''),coalesce(fields->>'address_line1',''),coalesce(fields->>'address_line2',''),coalesce(fields->>'city',''),coalesce(fields->>'state',''),coalesce(fields->>'zip',''),dob,balance,fields->>'carrier',fields->>'policy_type',premium,coalesce(fields->>'policy_number',''),app_date,eff,stage,case stage when 'in_force' then 'active' else 'submitted' end,coalesce(fields->>'notes',''));
 perform set_config('lld.crm_client_id',policy::text,true);
 if p_lead_id is not null then
  deal:=public.close_lead(p_lead_id,fields->>'carrier',fields->>'policy_type',premium,app_date,fields->>'policy_number',fields->>'notes');
  update public.leads set first_name=split_part(fields->>'client_name',' ',1),last_name=ltrim(substr(fields->>'client_name',length(split_part(fields->>'client_name',' ',1))+1)),phone=fields->>'phone',email=coalesce(fields->>'email',''),state=coalesce(fields->>'state','') where id=p_lead_id;
 else
  deal:=private.chat_standalone_deal(p_division,owner_id,p_request_id,fields->>'carrier',fields->>'policy_type',premium,app_date,fields->>'policy_number',fields->>'notes');
 end if;
 perform set_config('lld.crm_client_id',coalesce(old_context,''),true);
 if not exists(select 1 from private.book_crm_clients where id=policy and deal_id=deal and production_recorded) then raise exception 'The CRM could not be updated. Your deal was not submitted; try again.';end if;
 insert into private.book_clients(deal_id,client_name,phone,email,updated_by) values(deal,fields->>'client_name',fields->>'phone',nullif(fields->>'email',''),actor);
 insert into private.book_crm_activity(client_id,actor_id,kind,body,metadata) values(policy,actor,'created','Deal submitted with complete client and policy details',jsonb_build_object('event','deal_intake','source',case when p_lead_id is null then 'manual' else 'lead' end));
 insert into private.deal_intake_requests(request_id,actor_id,fingerprint,deal_id) values(p_request_id,actor,fingerprint,deal);
 return jsonb_build_object('ok',true,'deal_id',deal,'client_id',policy,'replayed',false);
end;$$;
create function public.submit_deal_with_client(p_request_id uuid,p_fields jsonb,p_lead_id uuid default null,p_agent_id uuid default null,p_division text default null) returns jsonb
language sql security invoker set search_path='' as $$ select private.submit_deal_with_client(p_request_id,p_fields,p_lead_id,p_agent_id,p_division) $$;
revoke all on function private.submit_deal_with_client(uuid,jsonb,uuid,uuid,text),public.submit_deal_with_client(uuid,jsonb,uuid,uuid,text) from public,anon,authenticated;
grant execute on function private.submit_deal_with_client(uuid,jsonb,uuid,uuid,text),public.submit_deal_with_client(uuid,jsonb,uuid,uuid,text) to authenticated;

create function private.require_complete_deal_client() returns trigger
language plpgsql security definer set search_path='' as $$
declare c private.book_crm_clients%rowtype; policy uuid:=nullif(current_setting('lld.crm_client_id',true),'')::uuid;
begin
 select * into c from private.book_crm_clients where id=policy and agent_id=new.agent_id and deal_id is null and not production_recorded;
 if not found or private.book_crm_missing_name(c.client_name) or length(regexp_replace(coalesce(c.phone,''),'[^0-9]','','g')) not between 7 and 18 then
  raise exception 'Complete the client and policy details before submitting this deal. Refresh the portal to open the updated form.';
 end if;
 if nullif(trim(new.carrier),'') is null or nullif(trim(new.policy_type),'') is null or new.monthly_premium is null or new.monthly_premium<=0 or new.monthly_premium>100000 or new.application_date is null then raise exception 'Complete the carrier, product, premium and application date';end if;
 return new;
end;$$;
revoke all on function private.require_complete_deal_client() from public,anon,authenticated;
