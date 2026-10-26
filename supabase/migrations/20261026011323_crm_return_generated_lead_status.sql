-- is_dead_number is derived from agent_status. Preserve it through that status, never insert the generated column.
create or replace function private.book_crm_return_lead(p_profile uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles; owner_profile public.profiles; origin public.leads;
 contact jsonb; headers jsonb; cells jsonb; item record; label text; key text; normalized text;
 seen text[]:='{}'; i integer; lead_id uuid:=gen_random_uuid(); agency text; reused boolean:=false;
 client_name text; notes text; result jsonb;
begin
 select * into person from private.book_crm_profiles where id=p_profile;
 if not found or not private.book_is_unlocked() or not private.book_crm_can_access(person.agent_id,null) then
  raise exception 'Client not available to your account' using errcode='42501';
 end if;
 select * into owner_profile from public.profiles where id=person.agent_id;
 if not owner_profile.active or owner_profile.archived or not exists(select 1 from public.divisions where id=owner_profile.division and not archived) then
  raise exception 'Reactivate or transfer this client''s agent before returning the client to leads.';
 end if;
 -- Prefer a still-open exact linked lead; never match unrelated people by phone/name.
 select l.* into origin from public.leads l join public.closed_business d on d.lead_id=l.id
 join private.book_crm_clients c on c.deal_id=d.id
 where c.profile_id=p_profile and l.assigned_to=person.agent_id
 order by (l.status='assigned') desc,l.created_at,l.id limit 1 for update of l;
 agency:=coalesce(origin.division,owner_profile.division);
 if origin.id is not null and origin.status='assigned' then lead_id:=origin.id;reused:=true;end if;
 contact:=coalesce(private.book_crm_lead_contact(origin),'{}');
 for item in select * from jsonb_each(coalesce(person.details,'{}')) loop
  if item.value<>'null'::jsonb and nullif(trim(item.value#>>'{}'),'') is not null then contact:=jsonb_set(contact,array[item.key],item.value);end if;
 end loop;
 client_name:=coalesce(nullif(contact->>'client_name',''),'Client from CRM');
 contact:=contact||jsonb_build_object('client_name',client_name,'first_name',split_part(client_name,' ',1),
 'last_name',ltrim(substr(client_name,length(split_part(client_name,' ',1))+1)));
 headers:=coalesce(origin.csv_headers,'[]');cells:=coalesce(origin.csv_values,'[]');
 if jsonb_typeof(headers)<>'array' then headers:='[]';end if;
 if jsonb_typeof(cells)<>'array' then cells:='[]';end if;
 while jsonb_array_length(cells)<jsonb_array_length(headers) loop cells:=cells||jsonb_build_array('');end loop;
 for i in 0..jsonb_array_length(headers)-1 loop
  normalized:=regexp_replace(lower(headers->>i),'[^a-z0-9]','','g');
  key:=case
   when normalized in ('firstname','first','givenname') then 'first_name'
   when normalized in ('lastname','last','surname','familyname') then 'last_name'
   when normalized in ('name','fullname','clientname','insuredname') then 'client_name'
   when normalized in ('phone','phonenumber','mobile','mobilephone','cell','cellphone','telephone') then 'phone'
   when normalized in ('email','emailaddress') then 'email'
   when normalized in ('state','st','statecode') then 'state'
   when normalized in ('address','addressline1','street','streetaddress') then 'address_line1'
   when normalized in ('city','town') then 'city'
   when normalized in ('zip','zipcode','postalcode') then 'zip'
   when normalized in ('alternatephone','secondaryphone') then 'alternate_phone'
   when normalized in ('dob','dateofbirth','birthdate') then 'date_of_birth'
   when normalized='mortgagebalance' then 'mortgage_balance' end;
  if key is not null then
   seen:=array_append(seen,key);
   if key='client_name' then seen:=seen||array['first_name','last_name'];end if;
   if nullif(contact->>key,'') is not null then cells:=jsonb_set(cells,array[i::text],to_jsonb(contact->>key));end if;
  end if;
 end loop;
 for item in select * from (values ('first_name','First Name'),('last_name','Last Name'),('phone','Phone'),
 ('email','Email'),('state','State'),('address_line1','Address'),('address_line2','Address Line 2'),('city','City'),
 ('zip','Zip'),('alternate_phone','Alternate Phone'),('date_of_birth','Date of Birth'),('mortgage_balance','Mortgage Balance')) v(k,l) loop
  if not item.k=any(seen) and nullif(contact->>item.k,'') is not null then
   headers:=headers||jsonb_build_array(item.l);cells:=cells||jsonb_build_array(contact->>item.k);
  end if;
 end loop;
 select concat_ws(E'\n\n',nullif(origin.call_notes,''),'Returned from CRM on '||(now() at time zone 'America/Detroit')::date||'. Previous production history retained.',
  (select string_agg(concat_ws(' — ',c.carrier,c.policy_type,nullif(c.policy_number,''),nullif(c.notes,'')),E'\n' order by c.created_at,c.id) from private.book_crm_clients c where c.profile_id=p_profile),
  (select string_agg(a.body,E'\n' order by a.created_at,a.id) from private.book_crm_activity a join private.book_crm_clients c on c.id=a.client_id where c.profile_id=p_profile and a.kind='note'),
  (select string_agg('Open task: '||t.title||' (due '||t.due_at::date||')',E'\n' order by t.due_at,t.id) from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_profile and t.completed_at is null)) into notes;
 insert into private.book_crm_lead_returns(profile_id,lead_id,source_lead_id,agent_id,division,actor_id)
 values(p_profile,lead_id,origin.id,person.agent_id,agency,auth.uid());
 if reused then
  update public.leads set first_name=contact->>'first_name',last_name=contact->>'last_name',
   phone=contact->>'phone',email=contact->>'email',state=contact->>'state',csv_headers=headers,csv_values=cells,call_notes=notes
  where id=lead_id;
 else
  insert into public.leads(id,first_name,last_name,phone,email,state,source,notes,status,assigned_to,assigned_at,
   lead_type,csv_filename,csv_headers,csv_values,agent_status,call_notes,owner_admin_id,division,uploaded_by)
  values(lead_id,contact->>'first_name',contact->>'last_name',contact->>'phone',contact->>'email',contact->>'state',
   coalesce(origin.source,'CRM return'),origin.notes,'assigned',person.agent_id,now(),
   case when origin.id is not null then origin.lead_type else 'Returned from CRM' end,origin.csv_filename,headers,cells,
   case when origin.is_dead_number then 'dead_number' else 'call_back' end,notes,
   coalesce(origin.owner_admin_id,owner_profile.created_by_admin_id,case when owner_profile.role='admin' then owner_profile.id end),
   agency,coalesce(origin.uploaded_by,person.agent_id));
  if agency<>owner_profile.division and owner_profile.role='agent' then
   insert into private.agent_portable_leads(lead_id,agent_id,origin_division) values(lead_id,person.agent_id,agency);
  end if;
 end if;
 update private.book_crm_lead_returns set completed=true where profile_id=p_profile;
 return jsonb_build_object('returned_lead_id',lead_id,'returned_agent_id',person.agent_id,'reused_lead',reused,
  'returned_folder',case when origin.id is not null then origin.lead_type else 'Returned from CRM' end);
end;$$;
