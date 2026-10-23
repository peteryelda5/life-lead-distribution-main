-- Recover contact details only from the deal's exact linked lead or saved contact.
-- Never match different clients by a similar name, premium, phone or policy number.
create function private.book_crm_missing_name(p_name text) returns boolean
language sql immutable set search_path='' as $$
 select lower(trim(coalesce(p_name,''))) in ('','client not linked','client details needed')
$$;

create function private.book_crm_csv_value(p_headers jsonb,p_values jsonb,p_keys text[]) returns text
language sql immutable set search_path='' as $$
 select nullif(trim(p_values->>(h.n-1)::int),'')
 from jsonb_array_elements_text(case when jsonb_typeof(p_headers)='array' then p_headers else '[]'::jsonb end) with ordinality h(label,n)
 where jsonb_typeof(p_values)='array'
 and regexp_replace(lower(h.label),'[^a-z0-9]','','g')=any(p_keys)
 and jsonb_typeof(p_values->(h.n-1)::int) in ('string','number')
 and lower(trim(coalesce(p_values->>(h.n-1)::int,''))) not in ('','null','undefined','nan','n/a')
 order by array_position(p_keys,regexp_replace(lower(h.label),'[^a-z0-9]','','g')),h.n limit 1
$$;

create function private.book_crm_lead_contact(p_lead public.leads) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_strip_nulls(jsonb_build_object(
 'client_name',left(coalesce(nullif(trim(concat_ws(' ',p_lead.first_name,p_lead.last_name)),''),private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['fullname','clientname','insuredname','name']),nullif(trim(concat_ws(' ',private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['firstname','clientfirstname','insuredfirstname']),private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['lastname','clientlastname','insuredlastname']))),'')),200),
 'phone',left(coalesce(nullif(trim(p_lead.phone),''),private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['phone','phonenumber','cellphone','mobilephone'])),50),
 'email',left(coalesce(nullif(trim(p_lead.email),''),private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['email','emailaddress'])),254),
 'state',left(coalesce(nullif(trim(p_lead.state),''),private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['state'])),50),
 'address_line1',left(private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['address','streetaddress','addressline1']),200),
 'city',left(private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['city']),200),
 'zip',left(private.book_crm_csv_value(p_lead.csv_headers,p_lead.csv_values,array['zip','zipcode','postalcode']),20)))
$$;

create function private.book_crm_fill_missing_contact(p_policy uuid,p_contact jsonb,p_actor uuid default null,p_source text default 'linked_lead') returns boolean
language plpgsql security definer set search_path='' as $$
declare person_id uuid; person private.book_crm_profiles%rowtype; info jsonb; field text; policy_row record;
begin
 if private.book_crm_missing_name(p_contact->>'client_name') or length(trim(p_contact->>'client_name'))>200 then return false;end if;
 select profile_id into person_id from private.book_crm_clients where id=p_policy and private.book_crm_missing_name(client_name);
 if person_id is null then return false;end if;
 perform pg_advisory_xact_lock(hashtextextended(person_id::text,49413));
 for policy_row in select id from private.book_crm_clients where profile_id=person_id order by id loop
  perform pg_advisory_xact_lock(hashtextextended(policy_row.id::text,49412));
  perform 1 from private.book_crm_clients where id=policy_row.id for update;
 end loop;
 select * into person from private.book_crm_profiles where id=person_id for update;
 if not found or not private.book_crm_missing_name(person.details->>'client_name') or exists(select 1 from private.book_crm_clients where profile_id=person_id and not private.book_crm_missing_name(client_name)) then return false;end if;
 info:=person.details||jsonb_build_object('client_name',trim(p_contact->>'client_name'));
 foreach field in array array['phone','email','state','address_line1','city','zip'] loop
  if nullif(trim(info->>field),'') is null and nullif(trim(p_contact->>field),'') is not null then info:=info||jsonb_build_object(field,trim(p_contact->>field));end if;
 end loop;
 -- Set the shared profile first so the normal sync trigger can see an already
 -- synchronized contact. System backfills do not impersonate an agent.
 update private.book_crm_profiles set details=info,updated_at=clock_timestamp() where id=person_id;
 update private.book_crm_clients set client_name=info->>'client_name',phone=coalesce(info->>'phone',''),email=coalesce(info->>'email',''),state=coalesce(info->>'state',''),address_line1=coalesce(info->>'address_line1',''),city=coalesce(info->>'city',''),zip=coalesce(info->>'zip',''),updated_at=clock_timestamp() where profile_id=person_id;
 if p_actor is not null then
  insert into private.book_clients(deal_id,client_name,phone,email,updated_by)
   select deal_id,client_name,nullif(phone,''),nullif(email,''),p_actor from private.book_crm_clients where profile_id=person_id and deal_id is not null
   on conflict(deal_id) do update set client_name=excluded.client_name,phone=excluded.phone,email=excluded.email,updated_by=excluded.updated_by;
  insert into private.book_crm_activity(client_id,actor_id,kind,body,metadata) values(p_policy,p_actor,'updated','Missing client details completed',jsonb_build_object('event','client_contact_recovered','source',p_source));
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(p_actor,'crm_client_contact_recovered','crm_profile',person_id::text,jsonb_build_object('source',p_source,'before',person.details,'after',info));
 return true;
end;$$;

create or replace function private.book_crm_closed_insert() returns trigger
language plpgsql security definer set search_path='' as $$
declare client_id uuid:=nullif(current_setting('lld.crm_client_id',true),'')::uuid; contact jsonb; saved private.book_clients%rowtype;
begin
 if client_id is not null then
  update private.book_crm_clients set deal_id=new.id,production_recorded=true where id=client_id and agent_id=new.agent_id;
  if found then return new;end if;
 end if;
 select private.book_crm_lead_contact(l) into contact from public.leads l where l.id=new.lead_id;
 select * into saved from private.book_clients where deal_id=new.id;
 if not private.book_crm_missing_name(saved.client_name) then contact:=coalesce(contact,'{}')||jsonb_strip_nulls(jsonb_build_object('client_name',saved.client_name,'phone',nullif(trim(saved.phone),''),'email',nullif(trim(saved.email),'')));end if;
 insert into private.book_crm_clients(agent_id,client_name,phone,email,state,address_line1,city,zip,carrier,policy_type,monthly_payment,policy_number,application_date,status,notes,deal_id,production_recorded)
 values(new.agent_id,coalesce(nullif(contact->>'client_name',''),'Client not linked'),coalesce(contact->>'phone',''),coalesce(contact->>'email',''),coalesce(contact->>'state',''),coalesce(contact->>'address_line1',''),coalesce(contact->>'city',''),coalesce(contact->>'zip',''),new.carrier,new.policy_type,new.monthly_premium,coalesce(new.policy_number,''),coalesce(new.application_date,current_date),'issued',coalesce(new.notes,''),new.id,true);
 return new;
end;$$;

create function private.book_crm_lead_contact_changed() returns trigger
language plpgsql security definer set search_path='' as $$
declare policy_row record; contact jsonb:=private.book_crm_lead_contact(new);
begin
 if private.book_crm_missing_name(contact->>'client_name') then return new;end if;
 for policy_row in select c.id from private.book_crm_clients c join public.closed_business d on d.id=c.deal_id where d.lead_id=new.id and private.book_crm_missing_name(c.client_name) order by c.profile_id,c.id loop
  perform private.book_crm_fill_missing_contact(policy_row.id,contact,auth.uid(),'linked_lead_update');
 end loop;
 return new;
end;$$;
create trigger book_crm_lead_contact_changed after update of first_name,last_name,phone,email,state,csv_headers,csv_values on public.leads for each row
 when(old.first_name is distinct from new.first_name or old.last_name is distinct from new.last_name or old.phone is distinct from new.phone or old.email is distinct from new.email or old.state is distinct from new.state or old.csv_headers is distinct from new.csv_headers or old.csv_values is distinct from new.csv_values)
 execute function private.book_crm_lead_contact_changed();

create function private.chat_standalone_deal_with_client(p_division text,p_agent_id uuid,p_request_id uuid,p_carrier text,p_policy_type text,p_monthly_premium numeric,p_application_date date,p_client_name text,p_client_phone text default null,p_client_email text default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare deal uuid; existing uuid; policy uuid; current_contact jsonb;
begin
 if not private.verified_portal_session() then raise exception 'Verified sign-in required' using errcode='42501';end if;
 if private.book_crm_missing_name(p_client_name) or length(trim(p_client_name))>200 or coalesce(length(p_client_phone),0)>50 or coalesce(length(p_client_email),0)>254 then raise exception 'Enter the client name and valid contact details';end if;
 if p_request_id is null then raise exception 'Request ID required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,741));
 select id into existing from public.closed_business where chat_request_id=p_request_id and agent_id=p_agent_id;
 -- Existing agency/agent authorization and production-once behavior remain authoritative.
 deal:=private.chat_standalone_deal(p_division,p_agent_id,p_request_id,p_carrier,p_policy_type,p_monthly_premium,p_application_date,null,null);
 select id,private.book_crm_contact_fields(to_jsonb(c)) into policy,current_contact from private.book_crm_clients c where deal_id=deal;
 if existing is not null then
  if policy is null or current_contact->>'client_name' is distinct from trim(p_client_name) or coalesce(current_contact->>'phone','')<>trim(coalesce(p_client_phone,'')) or coalesce(current_contact->>'email','')<>trim(coalesce(p_client_email,'')) then raise sqlstate 'PT409' using message='This deal was already saved. Open its client in the CRM to edit details.';end if;
  return deal;
 end if;
 if policy is null or not private.book_crm_fill_missing_contact(policy,jsonb_build_object('client_name',trim(p_client_name),'phone',trim(coalesce(p_client_phone,'')),'email',trim(coalesce(p_client_email,''))),auth.uid(),'chat_deal') then raise exception 'Client details could not be saved. Retry the deal.';end if;
 return deal;
end;$$;
create function public.chat_standalone_deal_with_client(p_division text,p_agent_id uuid,p_request_id uuid,p_carrier text,p_policy_type text,p_monthly_premium numeric,p_application_date date,p_client_name text,p_client_phone text default null,p_client_email text default null) returns uuid
language sql set search_path='' as $$select private.chat_standalone_deal_with_client(p_division,p_agent_id,p_request_id,p_carrier,p_policy_type,p_monthly_premium,p_application_date,p_client_name,p_client_phone,p_client_email)$$;

revoke all on function private.book_crm_missing_name(text),private.book_crm_csv_value(jsonb,jsonb,text[]),private.book_crm_lead_contact(public.leads),private.book_crm_fill_missing_contact(uuid,jsonb,uuid,text),private.book_crm_lead_contact_changed() from public,anon,authenticated;
revoke all on function private.chat_standalone_deal_with_client(text,uuid,uuid,text,text,numeric,date,text,text,text),public.chat_standalone_deal_with_client(text,uuid,uuid,text,text,numeric,date,text,text,text) from public,anon,authenticated;
grant execute on function private.chat_standalone_deal_with_client(text,uuid,uuid,text,text,numeric,date,text,text,text),public.chat_standalone_deal_with_client(text,uuid,uuid,text,text,numeric,date,text,text,text) to authenticated;

-- Repair only missing names with an exact recorded source. Preserve known contacts.
do $$declare item record; contact jsonb;begin
 for item in select c.id,c.deal_id from private.book_crm_clients c where private.book_crm_missing_name(c.client_name) order by c.profile_id,c.id loop
  select private.book_crm_lead_contact(l) into contact from public.closed_business d join public.leads l on l.id=d.lead_id where d.id=item.deal_id;
  select coalesce(contact,'{}')||jsonb_strip_nulls(jsonb_build_object('client_name',b.client_name,'phone',nullif(trim(b.phone),''),'email',nullif(trim(b.email),''))) into contact from private.book_clients b where b.deal_id=item.deal_id and not private.book_crm_missing_name(b.client_name)
   union all select contact where not exists(select 1 from private.book_clients b where b.deal_id=item.deal_id and not private.book_crm_missing_name(b.client_name));
  perform private.book_crm_fill_missing_contact(item.id,contact,null,'existing_deal_contact');
 end loop;
end;$$;

CREATE OR REPLACE FUNCTION private.book_client(p_deal uuid, p_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare crm_policy uuid; person_id uuid;
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if not exists(select 1 from public.closed_business c where c.id=p_deal and (c.agent_id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(c.agent_id) or private.can_read_admin_sale(c.agent_id,c.lead_id))) then raise exception 'Deal not available to your account' using errcode='42501';end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>50 or coalesce(length(p_email),0)>254 then raise exception 'Valid client name and contact details required';end if;
 select id,profile_id into crm_policy,person_id from private.book_crm_clients where deal_id=p_deal;
 if person_id is not null then perform pg_advisory_xact_lock(hashtextextended(person_id::text,49413));end if;
 insert into private.book_clients values(p_deal,trim(p_name),nullif(trim(p_phone),''),nullif(trim(p_email),''),auth.uid()) on conflict(deal_id) do update set client_name=excluded.client_name,phone=excluded.phone,email=excluded.email,updated_by=auth.uid();
 if crm_policy is not null then perform private.book_crm_fill_missing_contact(crm_policy,jsonb_build_object('client_name',trim(p_name),'phone',nullif(trim(p_phone),''),'email',nullif(trim(p_email),'')),auth.uid(),'saved_deal_contact');end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'book_client_updated','closed_business',p_deal::text,'{}');
 return jsonb_build_object('ok',true);
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_profile_save(p_id uuid, p_fields jsonb, p_expected_updated_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare person private.book_crm_profiles%rowtype; shared private.book_crm_clients%rowtype; merged jsonb; first_policy uuid;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_fields is null or jsonb_typeof(p_fields)<>'object' or p_fields is distinct from private.book_crm_contact_fields(p_fields) then raise exception 'Invalid contact fields';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49413));
 select * into person from private.book_crm_profiles where id=p_id for update;
 if not found or not private.book_crm_can_access(person.agent_id,null) then raise exception 'Client not available to your account' using errcode='42501';end if;
 if person.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Client contact details changed. Reopen the client and try again.';end if;
 merged:=person.details||p_fields;
 merged:=merged||jsonb_build_object('date_of_birth',nullif(merged->>'date_of_birth','')::date,'mortgage_balance',nullif(merged->>'mortgage_balance','')::numeric);
 shared:=jsonb_populate_record(null::private.book_crm_clients,merged);
 if private.book_crm_missing_name(shared.client_name) or coalesce(length(trim(shared.client_name)),0) not between 1 and 200 then raise exception 'Client name is required (up to 200 characters)';end if;
 if exists(select 1 from jsonb_each_text(merged) f where (f.key in ('address_line1','address_line2','city') and length(f.value)>200) or (f.key in ('phone','alternate_phone','state') and length(f.value)>50) or (f.key='email' and length(f.value)>254) or (f.key='zip' and length(f.value)>20)) then raise exception 'One or more contact fields are too long';end if;
 if shared.date_of_birth>current_date or shared.date_of_birth<date '1900-01-01' then raise exception 'Enter a valid date of birth';end if;
 if shared.mortgage_balance<0 or shared.mortgage_balance>999999999999.99 then raise exception 'Enter a valid mortgage balance';end if;
 -- Synchronization trigger mirrors these shared fields, never policy values, to siblings.
 select id into first_policy from private.book_crm_clients where profile_id=p_id order by id limit 1;
 update private.book_crm_clients set client_name=trim(shared.client_name),address_line1=coalesce(shared.address_line1,''),address_line2=coalesce(shared.address_line2,''),city=coalesce(shared.city,''),state=coalesce(shared.state,''),zip=coalesce(shared.zip,''),phone=coalesce(shared.phone,''),email=coalesce(shared.email,''),alternate_phone=coalesce(shared.alternate_phone,''),date_of_birth=shared.date_of_birth,mortgage_balance=shared.mortgage_balance,updated_at=clock_timestamp() where id=first_policy;
 insert into private.book_crm_activity(client_id,actor_id,kind,body) values(first_policy,auth.uid(),'updated','Shared client contact details updated');
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'crm_profile_saved','crm_profile',p_id::text,jsonb_build_object('before',person.details,'after',merged));
 return jsonb_build_object('ok',true,'id',p_id);
end;$function$;

notify pgrst,'reload schema';
